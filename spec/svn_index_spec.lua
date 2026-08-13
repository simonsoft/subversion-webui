-- Loads the mod_lua output filter directly (it is not a require-able
-- module, just a script defining a global output_filter function) and
-- drives it through the same coroutine/bucket streaming protocol Apache's
-- mod_lua uses in production: a global `bucket` holds the current input
-- chunk, and each coroutine.yield hands back the next piece of output.
local function spec_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source:match("(.*/)") or "./"
end

local ROOT = spec_dir() .. "../"

dofile(ROOT .. "mod-lua/svn-index.lua")

-- Mocks mod_lua's own built-in r:regex() (used by SVN_INDEX_HIDE_DIR --
-- see output_filter), which production code relies on directly with no
-- extra Lua library of its own. Confirmed against mod_lua's C source
-- (lua_ap_regex in modules/lua/lua_request.c): returns a truthy captures
-- table on match, `false` on no match, or `false, err` when the pattern
-- itself fails to compile -- never raises a Lua error either way. This
-- mock reproduces that exact three-way contract, backed by lrexlib's
-- PCRE2 binding purely so the test suite can exercise real PCRE matching
-- (e.g. alternation) without a real Apache request object -- a test-only
-- dependency; see the "Running tests" section of the README.
local rex_ok, rex = pcall(require, "rex_pcre2")

local function mock_regex(_, source, pattern)
    if not rex_ok then
        error("spec harness requires lrexlib-pcre2 to mock r:regex() -- see README's \"Running tests\" section")
    end

    local compile_ok, compiled = pcall(rex.new, pattern)

    if not compile_ok then
        return false, tostring(compiled)
    end

    if not compiled:find(source) then
        return false
    end

    return { [0] = source }
end

-- unparsed_uri defaults to mirroring `uri` -- correct for every existing
-- fixture, which only ever uses plain ASCII paths where the encoded
-- (r.unparsed_uri) and decoded (r.uri) forms are identical anyway. Pass it
-- explicitly to test percent-encoding-sensitive behavior (see the
-- "request_href" note in output_filter for why the real filter reads
-- r.unparsed_uri, not r.uri).
local function make_request(uri, subprocess_env, headers_in, unparsed_uri)
    local raw_target = unparsed_uri or uri or "/svn/demo1/"

    local r = {
        method = "GET",
        uri = uri or "/svn/demo1/",
        unparsed_uri = raw_target,
        -- Derived from the same request-target real Apache would, rather
        -- than a separate explicit parameter -- r.args and r.unparsed_uri
        -- are never inconsistent with each other in production.
        args = raw_target:match("%?(.*)$"),
        content_type = "text/xml; charset=utf-8",
        subprocess_env = subprocess_env or {},
        headers_in = headers_in or {},
        headers_out = {
            ["Content-Length"] = "1234",
            ["ETag"] = '"abc"'
        },
        logs = {}
    }

    local function logger(level)
        return function(self, msg)
            table.insert(self.logs, { level = level, msg = msg })
        end
    end

    r.info = logger("info")
    r.debug = logger("debug")
    r.warn = logger("warn")
    r.err = logger("err")
    r.regex = mock_regex

    return r
end

-- Feeds `chunks` to output_filter(r) one at a time via the global `bucket`,
-- mirroring mod_lua's runtime: `bucket` is still nil on the very first
-- resume, and only gets set to the next chunk *after* the script yields
-- (that first yield is the handshake that tells the runtime to fetch
-- input) -- pre-populating it before the first resume would hide a script
-- that forgets to yield before ever touching `bucket`.
local function run_filter(chunks, uri, subprocess_env, headers_in, unparsed_uri)
    local r = make_request(uri, subprocess_env, headers_in, unparsed_uri)
    local co = coroutine.create(function()
        return output_filter(r)
    end)

    -- Written via _G explicitly: busted sandboxes each spec file's own
    -- global writes into a private table (reads fall through to the real
    -- _G, but writes don't), so a bare `bucket = ...` here would never
    -- reach the real global that the dofile'd output_filter closure reads.
    _G.bucket = nil

    local i = 0
    local pieces = {}

    while true do
        local ok, yielded = coroutine.resume(co)

        if not ok then
            error("output_filter raised an error: " .. tostring(yielded))
        end

        if coroutine.status(co) == "dead" then
            break
        end

        pieces[#pieces + 1] = yielded

        i = i + 1
        _G.bucket = chunks[i]
    end

    _G.bucket = nil

    return table.concat(pieces), r
end

describe("svn-index output_filter", function()
    it("renders the preamble, streamed entries and footer across multiple buckets", function()
        local html = run_filter({
            [[<?xml version="1.0" encoding="utf-8"?>
<?xml-stylesheet type="text/xsl" href="/svn.xsl"?>
<svn version="1.14.1 (r1886195)"
     href="http://subversion.apache.org/">
<index rev="242" path="/" base="demo1">
<updir href="../"/>
<file name="access.accs" href="access.accs" />]],
            [[<dir name="arbortext" href="arbortext/" />
<dir name="dita" href="dita/" />]],
            [[<file name="repos.html" href="repos.html" />
</index>
</svn>
]]
        })

        -- lustache HTML-escapes {{...}} variables, including turning "/"
        -- into "&#x2F;" (mustache's standard escape table) -- this is
        -- correct/expected since title/path/base are attacker-influenceable
        -- via the request URL and must not be rendered raw.
        assert.truthy(html:find("<title>demo1 - Revision 242: &#x2F;</title>", 1, true))
        assert.truthy(html:find("<h1>demo1 - Revision 242: &#x2F;</h1>", 1, true))

        assert.truthy(html:find(
            'Powered by <a href="http:&#x2F;&#x2F;subversion.apache.org&#x2F;">Apache Subversion</a> version 1.14.1 (r1886195).',
            1, true
        ))

        local _, updir_pos = html:find('<li class="updir">', 1, true)
        local _, access_pos = html:find('access.accs', 1, true)
        local _, arbortext_pos = html:find('arbortext/', 1, true)
        local _, dita_pos = html:find('dita/', 1, true)
        local _, repos_pos = html:find('repos.html', 1, true)

        assert.truthy(updir_pos < access_pos)
        assert.truthy(access_pos < arbortext_pos)
        assert.truthy(arbortext_pos < dita_pos)
        assert.truthy(dita_pos < repos_pos)

        local _, li_count = html:gsub('<li class=', '')
        assert.are.equal(5, li_count)
    end)

    it("handles the entire document arriving in a single bucket", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<updir href="../"/>
<file name="README.md" href="README.md" />
</index>
</svn>]]
        })

        assert.truthy(html:find("<title>myrepo - Revision 7: &#x2F;trunk&#x2F;</title>", 1, true))
        assert.truthy(html:find("version 1.14.1 (r1886195)", 1, true))
        assert.truthy(html:find('<li class="file"><a href="README.md">README.md</a></li>', 1, true))
    end)

    it("HTML-escapes entry names and hrefs", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="1" path="/" base="demo1">
<file name="a &amp; b &lt;c&gt;.txt" href="a%20%26%20b.txt" />
</index>
</svn>]]
        })

        assert.truthy(html:find("a &amp; b &lt;c&gt;.txt", 1, true))
        assert.falsy(html:find("a & b <c>.txt", 1, true))
    end)

    it("still renders a full document when the <svn> version attribute is missing", function()
        local html = run_filter({
            [[<svn href="http://subversion.apache.org/">
<index rev="1" path="/" base="demo1">
<updir href="../"/>
</index>
</svn>]]
        })

        assert.truthy(html:find("<!DOCTYPE html>", 1, true))
        assert.truthy(html:find("Powered by", 1, true))
        assert.truthy(html:find("</html>", 1, true))
    end)

    it("renders plain relative hrefs (no htmx) for the default \"simple\" template", function()
        -- "simple" never does in-place DOM expansion, so a plain relative
        -- href -- resolved by the browser against the current page's own
        -- URL on a normal full-page navigation -- is correct at any nesting
        -- depth without needing to be anchored to r.uri.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/arbortext/" base="myrepo">
<updir href="../"/>
<dir name="dita" href="dita/" />
<file name="repos.html" href="repos.html" />
</index>
</svn>]]
        }, "/svn/demo1/arbortext/")

        assert.truthy(html:find('<li class="updir"><a href="../">../</a></li>', 1, true))
        assert.truthy(html:find('<li class="dir"><a href="dita/">dita/</a></li>', 1, true))
        assert.truthy(html:find('<li class="file"><a href="repos.html">repos.html</a></li>', 1, true))
        assert.falsy(html:find("hx-get", 1, true))
        assert.falsy(html:find("htmx.org", 1, true))
    end)

    it("anchors both href and hx-get to the requested directory when SVN_INDEX_TEMPLATE is \"htmx\"", function()
        -- This is what makes expansion (and plain navigation on expanded,
        -- nested entries) work at any nesting depth: each fragment is a
        -- real response to its own directory's URL, so anchoring both href
        -- and hx-get to r.uri (rather than leaving them as the bare
        -- relative values svn's XML provides) keeps them correct no matter
        -- how deep the fragment ends up nested client-side -- a relative
        -- href would otherwise resolve against the top-level document's
        -- URL, not the directory the entry actually belongs to.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/arbortext/" base="myrepo">
<updir href="../"/>
<dir name="dita" href="dita/" />
<file name="repos.html" href="repos.html" />
</index>
</svn>]]
        }, "/svn/demo1/arbortext/", { SVN_INDEX_TEMPLATE = "htmx" })

        assert.truthy(html:find("htmx.org", 1, true))
        assert.truthy(html:find('<li class="updir"><a href="/svn/demo1/arbortext/../">../</a></li>', 1, true))
        assert.truthy(html:find('<a href="/svn/demo1/arbortext/dita/" hx-get="/svn/demo1/arbortext/dita/"', 1, true))
        assert.truthy(html:find('<li class="file"><a href="/svn/demo1/arbortext/repos.html">repos.html</a></li>', 1, true))
    end)

    it("hides .updir via CSS when it lands nested (i.e. added by an htmx expansion), not at the top level", function()
        -- dir.mustache's hx-swap="beforeend" hx-target="closest li" inserts
        -- a clicked-open subdirectory's fragment as a child of that
        -- directory's own <li>, so its <updir> ends up nested inside
        -- another <li> -- unlike the real top-level <updir>, which sits
        -- directly under the page's own <ul class="svn-index">. The `li
        -- .updir` rule distinguishes the two structurally. "wa-page" no
        -- longer renders <updir> inline at all (see the next test), so it's
        -- not part of this one.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<updir href="../"/>
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "htmx" })

        assert.truthy(html:find("li .updir {", 1, true))
        assert.truthy(html:find("display: none;", 1, true))

        -- "simple" never nests a fragment inside an <li> (no htmx), so the
        -- top-level <updir> is the only one that can ever appear and the
        -- rule would be dead weight.
        local simple_html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<updir href="../"/>
</index>
</svn>]]
        })

        assert.falsy(simple_html:find("li .updir {", 1, true))
    end)

    it("hides .file (and .updir) inside the wa-page navigation tree regardless of nesting depth", function()
        -- "wa-page" no longer renders an inline updir entry at all (it's
        -- replaced by the header's "Up" button), and its navigation tree
        -- only ever browses folders -- files fetched into it via htmx are
        -- hidden by a single non-recursive CSS rule scoped to the nav tree.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<updir href="../"/>
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find("wa-tree.svn-nav .file", 1, true))
        assert.truthy(html:find("wa-tree.svn-nav .updir", 1, true))
        assert.falsy(html:find('<wa-tree-item class="updir">', 1, true))
    end)

    it("renders identically whether SVN_INDEX_TEMPLATE is unset or explicitly \"simple\"", function()
        local fixture = {
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<updir href="../"/>
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }

        local default_html = run_filter(fixture)
        local explicit_html = run_filter(fixture, nil, { SVN_INDEX_TEMPLATE = "simple" })

        assert.are.equal(default_html, explicit_html)
    end)

    it("renders an unprefixed title/h1 for the SVNParentPath 'Collection of Repositories' listing", function()
        -- mod_dav_svn's parentpath-collection resource has no revision and
        -- no single repository, so it omits both the rev and base
        -- attributes on <index> (rather than emitting them empty) and never
        -- emits <updir>. svn's own default rendering skips the
        -- "{base} - Revision {rev}: " prefix entirely in this case, leaving
        -- just the bare path ("Collection of Repositories").
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index path="Collection of Repositories">
<dir name="demo1" href="demo1/" />
<dir name="demo2" href="demo2/" />
</index>
</svn>]]
        })

        assert.truthy(html:find("<title>Collection of Repositories</title>", 1, true))
        assert.truthy(html:find("<h1>Collection of Repositories</h1>", 1, true))
        assert.falsy(html:find("Revision", 1, true))
        assert.falsy(html:find('<li class="updir"', 1, true))

        -- Each <dir> here is a repository root, not an ordinary
        -- subdirectory, so it's rendered with the "repo" template/class
        -- rather than "dir" -- and as a plain link rather than an htmx
        -- in-place expansion, since expansion should only ever start from
        -- a repository root, never span across repositories.
        assert.truthy(html:find(
            '<li class="repo"><a href="demo1/">demo1/</a></li>', 1, true
        ))
        assert.truthy(html:find(
            '<li class="repo"><a href="demo2/">demo2/</a></li>', 1, true
        ))
        assert.falsy(html:find('<li class="dir"', 1, true))
        assert.falsy(html:find("hx-get", 1, true))
    end)

    it("renders an ordinary <dir> with the \"dir\" template/class when browsing inside a repository", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<dir name="arbortext" href="arbortext/" />
</index>
</svn>]]
        })

        assert.truthy(html:find('<li class="dir">', 1, true))
        assert.falsy(html:find('<li class="repo"', 1, true))
    end)

    it("builds a consistently percent-encoded hx_href for entries under a directory whose own name needed encoding", function()
        -- mod_dav_svn's own XML "href" attribute is always percent-encoded
        -- (e.g. "140%20Securing/"). request_href (the prefix every entry's
        -- hx_href is anchored to) must be too -- built from
        -- "r.unparsed_uri" (the raw, still-encoded request URI), not
        -- "r.uri" (Apache's own *decoded* parsed path, which for a
        -- directory like "140 Maintenance and Service" would otherwise
        -- inject a literal space into the very same hx_href that also
        -- contains "%20" elsewhere -- exactly the inconsistency a real
        -- browser hit, reproduced here with mismatched uri/unparsed_uri).
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/graphics/140 Maintenance and Service/" base="demo3">
<dir name="140 Securing" href="140%20Securing/" />
</index>
</svn>]]
        },
            "/svn/demo3/graphics/140 Maintenance and Service/",
            { SVN_INDEX_TEMPLATE = "wa-page" },
            {},
            "/svn/demo3/graphics/140%20Maintenance%20and%20Service/"
        )

        assert.truthy(html:find(
            'hx-get="/svn/demo3/graphics/140%20Maintenance%20and%20Service/140%20Securing/"',
            1, true
        ))
        assert.falsy(html:find(' Maintenance and Service/', 1, true))
    end)

    it("warns via r:warn when a <dir> href doesn't end with '/', since is_target_any's prefix check relies on that", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<dir name="arbortext" href="arbortext" />
</index>
</svn>]]
        })

        local warning = nil
        for _, entry in ipairs(r.logs) do
            if entry.level == "warn" then
                warning = entry.msg
            end
        end

        assert.truthy(warning)
        assert.truthy(warning:find("arbortext", 1, true))
    end)

    it("renders the wa-page shell when SVN_INDEX_TEMPLATE is \"wa-page\", with entries unchanged", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<updir href="../"/>
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find("<wa-page>", 1, true))
        assert.truthy(html:find("webawesome.css", 1, true))
        assert.truthy(html:find('<header slot="header">', 1, true))
        assert.truthy(html:find('<footer slot="footer" id="svn-footer">', 1, true))
        assert.truthy(html:find(
            '<wa-tree-item class="file"><a href="/svn/demo1/README.md"><wa-icon name="file" variant="regular"></wa-icon> README.md</a></wa-tree-item>',
            1, true
        ))
    end)

    it("strips developer-facing comments from the wa-page shell by default", function()
        -- load_template_set's cache is keyed by template_type alone, not
        -- by SVN_INDEX_STRIP_COMMENTS (see its own comment: production
        -- never varies that env within one worker's lifetime, so whichever
        -- mode first loads "wa-page" wins for the rest of the process).
        -- Other tests above already loaded "wa-page" in default (stripped)
        -- mode, but re-dofile'ing here gets a fresh template_cache so this
        -- test doesn't depend on that happening to be true.
        dofile(ROOT .. "mod-lua/svn-index.lua")

        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.falsy(html:find('"wa-lazy-load" bubbles', 1, true))
        assert.falsy(html:find("/*", 1, true))
        assert.falsy(html:find("<!--", 1, true))

        -- Functional code on either side of stripped comments survives.
        assert.truthy(html:find('document.addEventListener("wa-lazy-load"', 1, true))
        assert.truthy(html:find("wa-page::part(header) {", 1, true))
    end)

    it("serves the wa-page shell with comments intact when SVN_INDEX_STRIP_COMMENTS is disabled", function()
        -- Same reasoning as above, in reverse: without a fresh
        -- template_cache here, this would see whatever mode an earlier
        -- test already loaded "wa-page" in.
        dofile(ROOT .. "mod-lua/svn-index.lua")

        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page", SVN_INDEX_STRIP_COMMENTS = "0" })

        assert.truthy(html:find('"wa-lazy-load" bubbles', 1, true))
        assert.truthy(html:find('document.addEventListener("wa-lazy-load"', 1, true))
    end)

    it("exposes the wa-page header's background color as an overridable --svn-header-bg custom property", function()
        -- No value is set for --svn-header-bg anywhere in the shipped
        -- template -- only used as a var() fallback -- so a site overrides
        -- it by setting the property itself from later CSS (e.g. a
        -- page-head-end.mustache <style> block), without editing this file.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find(
            "background: var(--svn-header-bg, var(--wa-color-brand-fill-loud));",
            1, true
        ))
    end)

    it("builds a breadcrumb trail (with htmx expansion and repo/dir icons) and the \"Start\"/\"Up\" toolbar hrefs from path depth", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/arbortext/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, "/svn/myrepo/trunk/arbortext/", { SVN_INDEX_TEMPLATE = "wa-page" })

        -- path has 2 segments ("trunk", "arbortext"): myrepo (is_repo) is
        -- the repo root, trunk and arbortext (both is_dir) descend from it;
        -- arbortext (current) is unlinked, the other two carry hx-get for
        -- htmx's own click-triggered swap (dir.mustache's own pattern --
        -- no plain "href", deliberately: confirmed via a real browser that
        -- combining a real href with hx-get on wa-breadcrumb-item fires
        -- BOTH htmx's own fetch AND the anchor's native default navigation,
        -- racing each other into a real full-page reload).
        assert.truthy(html:find(
            '<wa-breadcrumb-item hx-get="/svn/myrepo/" hx-target="#svn-index" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item" hx-select-oob="#svn-breadcrumb,#svn-footer,#svn-header-left" hx-trigger="click"><wa-icon name="database"></wa-icon> myrepo</wa-breadcrumb-item>',
            1, true
        ))
        assert.truthy(html:find(
            '<wa-breadcrumb-item hx-get="/svn/myrepo/trunk/" hx-target="#svn-index" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item" hx-select-oob="#svn-breadcrumb,#svn-footer,#svn-header-left" hx-trigger="click"><wa-icon name="folder" variant="regular"></wa-icon> trunk</wa-breadcrumb-item>',
            1, true
        ))
        assert.truthy(html:find(
            '<wa-breadcrumb-item><wa-icon name="folder" variant="regular"></wa-icon> arbortext</wa-breadcrumb-item>',
            1, true
        ))
        -- Absolute, not "../../../" -- see the note above compute_breadcrumbs
        -- for why repo_parent_path can't be relative like "Up" is.
        assert.truthy(html:find('<a href="/svn/"><wa-icon name="house">', 1, true))
        assert.truthy(html:find('<a href="../"><wa-icon name="turn-up">', 1, true))
    end)

    it("hides the \"Up\" link and collapses the breadcrumb to a single, icon-less, unlinked crumb on the Collection of Repositories listing", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index path="Collection of Repositories">
<dir name="demo1" href="demo1/" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.falsy(html:find('<wa-icon name="turn-up">', 1, true))
        assert.truthy(html:find('<wa-breadcrumb-item>Collection of Repositories</wa-breadcrumb-item>', 1, true))
    end)

    it("wires wa-page dir entries with lazy-loading plumbing but never sets lazy itself", function()
        -- dir.mustache's wa-tree-item never sets "lazy" -- it's the same
        -- markup rendered into both main (a strictly flat listing) and the
        -- nav tree (which wants in-place lazy expansion), so main's copies
        -- would otherwise show a dead expand chevron too. Nav opts in
        -- itself, marking its own newly-fetched dir children lazy=true
        -- after the fact (see the "htmx:after:swap" tests below) -- so
        -- outside of that, hx-trigger="wa-lazy-load" just sits dormant
        -- until nav sets lazy=true, at which point wa-tree-item's own
        -- chevron interaction can fire it. Separately, the label's own
        -- "click[this.parentElement.selected]" trigger only fires a plain
        -- click when the item is already selected -- covering the
        -- reselect-to-refresh case (a click that *doesn't* change
        -- selection never fires wa-selection-change at all) -- and each
        -- <wa-tree>'s own centralized hx-on:wa-selection-change (see
        -- page.mustache) covers everything else: a selecting click
        -- anywhere in the item's row (not just the label) or keyboard
        -- activation, by synthesizing a real click on this same span once
        -- Web Awesome's own wa-tree reports the selection change (it
        -- dispatches that event on itself, never on the individual
        -- wa-tree-item -- confirmed via wa-tree's own source, tree.ts's
        -- selectItem()). No double-fire: by the time that synthetic click
        -- lands, .selected is already true (wa-tree sets it before
        -- dispatching), so it satisfies the very same
        -- "click[this.parentElement.selected]" filter -- while the
        -- original real click that *caused* the selection does not, since
        -- it's evaluated before wa-tree's own handler (further up the
        -- bubble chain) has had a chance to mutate .selected. So main
        -- updates no matter how many times the same or a different entry
        -- is activated.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<dir name="arbortext" href="arbortext/" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find(
            '<wa-tree-item class="dir" hx-get="/svn/demo1/arbortext/" hx-trigger="wa-lazy-load" hx-target="this" hx-swap="beforeend" hx-select=".svn-index > wa-tree-item">',
            1, true
        ))
        assert.truthy(html:find(
            '<span hx-get="/svn/demo1/arbortext/" hx-target="#svn-index" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item" hx-select-oob="#svn-breadcrumb,#svn-footer,#svn-header-left" hx-trigger="click[this.parentElement.selected]">',
            1, true
        ))
    end)

    it("never wires htmx onto wa-page repo entries, since expansion must not span across repositories", function()
        -- Unlike an ordinary <dir>, a <repo> entry (only rendered on the
        -- SVNParentPath "Collection of Repositories" listing) is a
        -- repository root -- crossing into it is a bigger boundary than
        -- moving between two folders of the same repo, so it stays a plain
        -- link/full navigation, matching the same invariant the "simple"
        -- template already enforces above ("renders an unprefixed title/h1
        -- for the ... 'Collection of Repositories' listing").
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index path="Collection of Repositories">
<dir name="demo1" href="demo1/" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        -- The immediate "class=\"repo\"...><a href=...>" transition (no
        -- attributes in between) proves this specific entry carries no
        -- hx-get/lazy wiring -- a page-wide search for "hx-get"/"lazy" would
        -- false-fail here since the page's own nav root item and lazy-clear
        -- script always contain those strings regardless of fixture. The
        -- dead-zone/keyboard click synthesis for this plain <a href> (same
        -- as file.mustache) lives on each <wa-tree>'s own
        -- hx-on:wa-selection-change instead (see page.mustache) -- not
        -- here, since Web Awesome's own wa-tree dispatches that event on
        -- itself, never on the individual wa-tree-item.
        assert.truthy(html:find('<wa-tree-item class="repo"><a href="/svn/demo1/demo1/">', 1, true))
    end)

    it("removes the lazy attribute after its own swap lands, via a page-level htmx:after:swap listener", function()
        -- htmx 4.0.0-beta6 dispatches fully colon-namespaced lifecycle
        -- events ("htmx:after:swap", not the "htmx:afterSwap"/"afterSwap"
        -- naming used by earlier htmx versions), and this build's hx-on
        -- shorthand doesn't map onto that -- confirmed by driving a real
        -- browser through this exact flow. A single page-level listener,
        -- scoped to elements that still have the `lazy` attribute, is what
        -- actually clears it (see dir.mustache/repo.mustache for the lazy
        -- tree items this applies to).
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('addEventListener("htmx:after:swap"', 1, true))
        assert.truthy(html:find('removeAttribute("lazy")', 1, true))
    end)

    it("also clears wa-tree-item's own loading state, not just the lazy attribute", function()
        -- wa-tree-item's "loading" spinner (aria-busy) is a separate reactive
        -- property from "lazy", and only clears once the item observes an
        -- actual child-list mutation -- confirmed via a real browser that
        -- expanding a directory with zero entries appends nothing (hx-select
        -- matches nothing, so beforeend inserts no nodes), leaving "loading"
        -- stuck forever since no mutation ever happens. Setting the property
        -- directly ends it regardless of whether anything was appended.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find("event.target.loading = false", 1, true))
    end)

    it("re-syncs nav's stale [selected] highlight via htmx:after:history:push, since main label/breadcrumb clicks never touch nav's own render path", function()
        -- Nav's own label clicks already keep [selected] correct on their
        -- own (wa-tree's built-in single-selection behavior), but main's
        -- label clicks and breadcrumb clicks both swap "#svn-index"
        -- without ever re-rendering anything in nav, leaving its
        -- server-rendered snapshot stale. This can't key off
        -- "htmx:after:swap"'s own event.target -- confirmed via a real
        -- browser that htmx dispatches that event on the request's source
        -- element only if still connected at dispatch time, falling back
        -- to `document` otherwise, and for both of those flows the clicked
        -- element sits inside whatever this very swap (or its "#svn-breadcrumb"
        -- oob swap) just replaced, so it's already disconnected --
        -- "htmx:after:history:push" sidesteps that, firing on `document`
        -- unconditionally with the exact pushed path already available.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('addEventListener("htmx:after:history:push"', 1, true))
        assert.truthy(html:find("event.detail?.path", 1, true))
        assert.truthy(html:find('.svn-nav wa-tree-item.dir[selected]', 1, true))
        assert.truthy(html:find('.svn-nav wa-tree-item.dir[hx-get]', 1, true))
    end)

    it("drops the nav expand chevron once a lazy item has no folder children left", function()
        -- wa-tree-item's expand chevron is driven by actually having child
        -- wa-tree-item elements, not by whether they're visible -- so a
        -- folder containing only files (hidden from nav via CSS), or no
        -- entries at all, would otherwise still show a chevron that reveals
        -- nothing. wa-tree-item exposes "isLeaf" as a real, settable
        -- property (not just a computed one), so setting it directly covers
        -- both cases uniformly -- confirmed via a real browser, including
        -- that this works even for a directory with zero entries (where
        -- hx-select matches nothing and nothing is ever appended at all).
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find(':scope > wa-tree-item:not(.dir)', 1, true))
        assert.truthy(html:find(':scope > wa-tree-item.dir', 1, true))
        assert.truthy(html:find('event.target.isLeaf = dirChildren.length === 0', 1, true))
    end)

    it("marks nav's own newly-fetched dir entries lazy, both at the root and nested under an already-expanded item -- except ones already on the auto-expand path", function()
        -- dir.mustache never sets "lazy" itself (see the test above) -- nav
        -- opts in after the fact instead, via a single unified check
        -- covering both the root-level population (event.target is the
        -- "svn-nav" tree itself) and a nested item's own children (once it
        -- finishes loading), since both sit inside/at ".svn-nav". It marks
        -- newly fetched .dir children lazy=true so each one gets its own
        -- future expand capability in turn -- except a child whose own
        -- hx-trigger is "load" (i.e. is itself on the auto-expand path,
        -- server-rendered that way -- see "is_target_any" in
        -- ENTRY_CONTEXT_BUILDERS.dir), which must be marked expanded=true
        -- instead: confirmed via a real browser that marking it lazy=true
        -- too visually collapses it, undoing its own auto-expansion.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('if (event.target.closest?.(".svn-nav")) {', 1, true))
        assert.truthy(html:find('if (child.getAttribute("hx-trigger") === "load") {', 1, true))
        assert.truthy(html:find("child.expanded = true;", 1, true))
        assert.truthy(html:find("child.lazy = true;", 1, true))
    end)

    it("stops a nested lazy-load from also re-triggering already-loaded ancestor tree items", function()
        -- "wa-lazy-load" bubbles, and htmx's hx-trigger binding is permanent
        -- once an element has been processed (removing the hx-trigger/lazy
        -- *attributes* later doesn't detach it) -- confirmed via a real
        -- browser that, without this guard, expanding a nested folder two
        -- levels deep in the nav tree also re-fetches and duplicates every
        -- already-loaded ancestor above it. The fix injects a one-time
        -- stopPropagation listener directly onto the real originating
        -- element from a capture-phase document listener, which runs before
        -- the event reaches the target and so is in place in time.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('addEventListener("wa-lazy-load"', 1, true))
        assert.truthy(html:find("stopPropagation()", 1, true))
        assert.truthy(html:find("{ once: true }", 1, true))
    end)

    it("gives the main listing a stable id for dir/repo entries to target when swapping main content", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('<wa-tree class="svn-index" id="svn-index" hx-on:wa-selection-change=', 1, true))
    end)

    it("wires the wa-page navigation tree itself to load the repo root's own listing, with no top-level wrapper item", function()
        -- The nav tree used to wrap the fetched entries in a permanently
        -- "expanded" item representing the current directory -- but that
        -- was purely redundant (the breadcrumb already shows where you
        -- are), and it cost an extra indentation level for nothing. Putting
        -- the hx-get/hx-trigger/hx-select directly on <wa-tree> itself, with
        -- hx-swap="innerHTML" replacing its own content, makes the fetched
        -- entries direct (top-level) children instead. It now always starts
        -- at the *repo root* (nav_root_path, the absolute "/svn/myrepo/"
        -- for this one-segment fixture) rather than the current directory
        -- ("."), so ancestors above the current folder are visible too,
        -- not just its own children.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, "/svn/myrepo/trunk/", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find(
            [[<wa-tree class="svn-nav" hx-get="/svn/myrepo/" hx-trigger="load" hx-target="this" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item" hx-on:wa-selection-change="event.detail.selection.forEach(item => item.querySelector(':scope > span[hx-get], :scope > a[href]')?.click())">]],
            1, true
        ))
    end)

    it("nav_root_path resolves to \".\" on the Collection of Repositories listing, and to the repo's own absolute root href at the repo root itself", function()
        -- Not has_base (the Collection listing) falls back to the literal
        -- "." (today's behavior, unchanged). At the repo root itself
        -- (has_base true, zero path segments), nav_root_path is instead
        -- breadcrumbs[1].hx_href with zero segments -- the current
        -- directory's own absolute href, which also just means "this same
        -- directory", now spelled out explicitly rather than via a
        -- relative "" that only resolved correctly by relying on the
        -- browser's own current-location context.
        local collection_html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index path="Collection of Repositories">
<dir name="demo1" href="demo1/" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(collection_html:find('hx-get="."', 1, true))

        local repo_root_html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, "/svn/myrepo/", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(repo_root_html:find('hx-get="/svn/myrepo/"', 1, true))
    end)

    it("marks only the entry on the path to HX-Current-URL as expanded/load-triggered, leaving siblings unchanged", function()
        -- Nav's own auto-expand-to-current-folder feature: HX-Current-URL
        -- reflects the browser's actual target throughout the whole
        -- cascade (location.href never changes during nav's own background
        -- fetches), so each request can independently decide, from that
        -- alone, whether one of its own entries sits on the path to it --
        -- no query-string state threading needed. HX-Target="wa-tree"
        -- marks this as one of nav's own requests (see the main-swap
        -- exclusion test below).
        local fixture = {
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name="trunk" href="trunk/" />
<dir name="branches" href="branches/" />
</index>
</svn>]]
        }

        local html = run_filter(
            fixture, "/svn/demo1/", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Current-URL"] = "http://host/svn/demo1/trunk/arbortext/", ["HX-Target"] = "wa-tree" }
        )

        assert.truthy(html:find(
            '<wa-tree-item class="dir" hx-get="/svn/demo1/trunk/" hx-trigger="load"',
            1, true
        ))
        assert.truthy(html:find(
            '<wa-tree-item class="dir" hx-get="/svn/demo1/branches/" hx-trigger="wa-lazy-load"',
            1, true
        ))
    end)

    it("marks the final target directory itself on-path too, not just its strict ancestors", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name="trunk" href="trunk/" />
</index>
</svn>]]
        }, "/svn/demo1/", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Current-URL"] = "http://host/svn/demo1/trunk/", ["HX-Target"] = "wa-tree" }
        )

        assert.truthy(html:find(
            '<wa-tree-item class="dir" selected hx-get="/svn/demo1/trunk/" hx-trigger="load"',
            1, true
        ))
    end)

    it("marks only the exact target directory (not a strict ancestor) as selected", function()
        local fixture = {
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name="trunk" href="trunk/" />
</index>
</svn>]]
        }

        local html = run_filter(
            fixture, "/svn/demo1/", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Current-URL"] = "http://host/svn/demo1/trunk/arbortext/", ["HX-Target"] = "wa-tree" }
        )

        assert.truthy(html:find(
            '<wa-tree-item class="dir" hx-get="/svn/demo1/trunk/" hx-trigger="load"',
            1, true
        ))
        assert.falsy(html:find(
            '<wa-tree-item class="dir" selected',
            1, true
        ))
    end)

    it("carries mod_dav_svn's own revision-pin suffix (\"?p=10\") on ordinary entries with zero code changes needed, via the existing request_href .. href concatenation", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/marketing/" base="demo3">
<dir name="lang" href="lang/?p=10" />
</index>
</svn>]]
        }, "/svn/demo3/marketing/?p=10", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('hx-get="/svn/demo3/marketing/lang/?p=10"', 1, true))
    end)

    it("carries the revision pin through breadcrumbs and nav_root_path, which this filter builds itself with no XML href to inherit it from", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/trunk/arbortext/" base="myrepo">
<file name="README.md" href="README.md?p=10" />
</index>
</svn>]]
        }, "/svn/myrepo/trunk/arbortext/?p=10", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('<wa-breadcrumb-item hx-get="/svn/myrepo/?p=10"', 1, true))
        assert.truthy(html:find('<wa-breadcrumb-item hx-get="/svn/myrepo/trunk/?p=10"', 1, true))
        assert.truthy(html:find('<wa-tree class="svn-nav" hx-get="/svn/myrepo/?p=10" hx-trigger="load"', 1, true))
    end)

    it("carries the revision pin in HX-Push-Url too, so a reload or copy-pasted URL doesn't silently lose it", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/trunk/arbortext/" base="myrepo">
<file name="README.md" href="README.md?p=10" />
</index>
</svn>]]
        }, "/svn/myrepo/trunk/arbortext/?p=10", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Target"] = "wa-tree#svn-index" }
        )

        assert.are.equal("/svn/myrepo/trunk/arbortext/?p=10", r.headers_out["HX-Push-Url"])
    end)

    it("marks an ancestor on-path even though its own hx_href (with \"?p=10\") is never a whole-string prefix of the deeper, query-bearing target -- proves path and revision must be compared independently", function()
        -- An ancestor's own hx_href (".../trunk/?p=10") is never a string-
        -- prefix of the deeper target's own path (".../trunk/arbortext/",
        -- nav_target_path is already query-free) even with the query kept
        -- on both sides -- they diverge exactly where one has "?p=10" and
        -- the other continues with "arbortext/". Path and revision-pin are
        -- compared independently instead (see "same_revision" in
        -- ENTRY_CONTEXT_BUILDERS.dir).
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/" base="myrepo">
<dir name="trunk" href="trunk/?p=10" />
</index>
</svn>]]
        }, "/svn/demo1/?p=10", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Current-URL"] = "http://host/svn/demo1/trunk/arbortext/?p=10", ["HX-Target"] = "wa-tree" }
        )

        assert.truthy(html:find(
            '<wa-tree-item class="dir" hx-get="/svn/demo1/trunk/?p=10" hx-trigger="load"',
            1, true
        ))
    end)

    it("marks the exact target directory selected when both its path and revision pin match HX-Current-URL", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/" base="myrepo">
<dir name="trunk" href="trunk/?p=10" />
</index>
</svn>]]
        }, "/svn/demo1/?p=10", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Current-URL"] = "http://host/svn/demo1/trunk/?p=10", ["HX-Target"] = "wa-tree" }
        )

        assert.truthy(html:find(
            '<wa-tree-item class="dir" selected hx-get="/svn/demo1/trunk/?p=10" hx-trigger="load"',
            1, true
        ))
    end)

    it("does not mark an entry on-path when its own revision doesn't match HX-Current-URL's, even at the identical path", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name="trunk" href="trunk/" />
</index>
</svn>]]
        }, "/svn/demo1/", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Current-URL"] = "http://host/svn/demo1/trunk/?p=10", ["HX-Target"] = "wa-tree" }
        )

        assert.truthy(html:find(
            '<wa-tree-item class="dir" hx-get="/svn/demo1/trunk/" hx-trigger="wa-lazy-load"',
            1, true
        ))
        assert.falsy(html:find('<wa-tree-item class="dir" selected', 1, true))
    end)

    it("does not false-fire r:warn on a valid revision-pinned href, since the trailing-slash check now looks before any \"?p=REV\" suffix", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/trunk/" base="myrepo">
<dir name="arbortext" href="arbortext/?p=10" />
</index>
</svn>]]
        }, "/svn/demo1/trunk/?p=10")

        for _, entry in ipairs(r.logs) do
            assert.are_not.equal("warn", entry.level)
        end
    end)

    it("still fires r:warn for a genuinely missing trailing slash even when a query string is present, proving the fix checks \"before the query\", not \"disabled entirely\"", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/trunk/" base="myrepo">
<dir name="arbortext" href="arbortext?p=10" />
</index>
</svn>]]
        }, "/svn/demo1/trunk/?p=10")

        local warning = nil

        for _, entry in ipairs(r.logs) do
            if entry.level == "warn" then
                warning = entry.msg
            end
        end

        assert.truthy(warning)
    end)

    it("appends SVN_INDEX_QUERY_FILE's own literal query-string value to file entries' own links only, layering after an existing \"?p=REV\" when both apply", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/trunk/" base="myrepo">
<dir name="arbortext" href="arbortext/?p=10" />
<file name="README.md" href="README.md?p=10" />
</index>
</svn>]]
        }, "/svn/demo1/trunk/?p=10",
            { SVN_INDEX_TEMPLATE = "wa-page", SVN_INDEX_QUERY_FILE = "view=details&this=that" }
        )

        -- "&amp;", not "&": hx_href goes through escape_html (like every
        -- other href in this file) before being placed in the template,
        -- same as any other HTML attribute value.
        assert.truthy(html:find(
            '<a href="/svn/demo1/trunk/README.md?p=10&amp;view=details&amp;this=that">',
            1, true
        ))
        assert.truthy(html:find(
            '<wa-tree-item class="dir" hx-get="/svn/demo1/trunk/arbortext/?p=10" hx-trigger="wa-lazy-load"',
            1, true
        ))
    end)

    it("appends SVN_INDEX_QUERY_FILE's own literal query-string value using \"?\" rather than \"&\" when the file entry has no existing query", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, "/svn/demo1/trunk/",
            { SVN_INDEX_TEMPLATE = "wa-page", SVN_INDEX_QUERY_FILE = "view=details&this=that" }
        )

        assert.truthy(html:find(
            '<a href="/svn/demo1/trunk/README.md?view=details&amp;this=that">',
            1, true
        ))
    end)

    it("appends repo_root to history_href, layering after an existing \"?p=REV\" pin with \"&amp;\"", function()
        -- svn-log.lua's own output_filter has no way to know where the
        -- repo root sits in the URL space (only the directory-listing XML
        -- this file parses carries <index base="..." path="...">) -- it
        -- reads this back via r.args to anchor changed-path links. Built
        -- raw (both request_href+revision_suffix and the repo_root
        -- addition) and escape_html'd exactly once at the end, like every
        -- other href in this file -- hence "&amp;", not "&".
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/trunk/" base="myrepo">
</index>
</svn>]]
        }, "/svn/myrepo/trunk/?p=10", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find(
            'hx-action="/svn/myrepo/trunk/?p=10&amp;repo_root=/svn/myrepo/"',
            1, true
        ))
    end)

    it("appends repo_root to history_href using \"?\" rather than \"&amp;\" when unpinned", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/trunk/" base="myrepo">
</index>
</svn>]]
        }, "/svn/myrepo/trunk/", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find(
            'hx-action="/svn/myrepo/trunk/?repo_root=/svn/myrepo/"',
            1, true
        ))
    end)

    it("tags a dir entry matching SVN_INDEX_HIDE_DIR with the \"navhidden\" class, leaving a non-matching sibling plain", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name=".cms" href=".cms/" />
<dir name="trunk" href="trunk/" />
</index>
</svn>]]
        }, "/svn/demo1/",
            { SVN_INDEX_TEMPLATE = "wa-page", SVN_INDEX_HIDE_DIR = "^\\." }
        )

        assert.truthy(html:find('<wa-tree-item class="dir navhidden"', 1, true))
        assert.truthy(html:find('<wa-tree-item class="dir" hx-get="/svn/demo1/trunk/"', 1, true))
    end)

    it("supports native PCRE alternation in SVN_INDEX_HIDE_DIR to match several distinct names at once", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name="lang" href="lang/" />
<dir name="release" href="release/" />
<dir name="trunk" href="trunk/" />
</index>
</svn>]]
        }, "/svn/demo1/",
            { SVN_INDEX_TEMPLATE = "wa-page", SVN_INDEX_HIDE_DIR = "^lang$|^release$" }
        )

        assert.truthy(html:find('<wa-tree-item class="dir navhidden" hx-get="/svn/demo1/lang/"', 1, true))
        assert.truthy(html:find('<wa-tree-item class="dir navhidden" hx-get="/svn/demo1/release/"', 1, true))
        assert.truthy(html:find('<wa-tree-item class="dir" hx-get="/svn/demo1/trunk/"', 1, true))
    end)

    it("never tags any entry \"navhidden\" when SVN_INDEX_HIDE_DIR is unset", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name=".cms" href=".cms/" />
</index>
</svn>]]
        }, "/svn/demo1/", { SVN_INDEX_TEMPLATE = "wa-page" })

        -- Note: a plain substring search for "navhidden" would always match
        -- the CSS rule text in the page's own <style> block -- this checks
        -- for the class actually being applied to an entry instead.
        assert.falsy(html:find('class="dir navhidden"', 1, true))
    end)

    it("logs a warning and treats a malformed SVN_INDEX_HIDE_DIR regex as unset, rather than crashing the filter", function()
        local html, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name="trunk" href="trunk/" />
</index>
</svn>]]
        }, "/svn/demo1/",
            { SVN_INDEX_TEMPLATE = "wa-page", SVN_INDEX_HIDE_DIR = "(" }
        )

        assert.falsy(html:find('class="dir navhidden"', 1, true))

        local warning = nil

        for _, entry in ipairs(r.logs) do
            if entry.level == "warn" then
                warning = entry.msg
            end
        end

        assert.truthy(warning)
    end)

    it("never tags a \"repo\" entry (Collection of Repositories) \"navhidden\", even when its name matches SVN_INDEX_HIDE_DIR", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="0" path="Collection of Repositories">
<dir name="lang" href="lang/" />
</index>
</svn>]]
        }, "/svn/",
            { SVN_INDEX_TEMPLATE = "wa-page", SVN_INDEX_HIDE_DIR = "^lang$" }
        )

        assert.truthy(html:find('<wa-tree-item class="repo">', 1, true))
        assert.falsy(html:find('class="repo navhidden"', 1, true))
    end)

    it("shows the revision badge only while actively pinned, never for ordinary HEAD browsing", function()
        local pinned_html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md?p=10" />
</index>
</svn>]]
        }, "/svn/demo1/trunk/?p=10", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(pinned_html:find('<span class="revision-badge wa-font-size-s">10</span>', 1, true))

        local head_html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, "/svn/demo1/trunk/", { SVN_INDEX_TEMPLATE = "wa-page" })

        -- The bare class name alone would also match the static ".revision
        -- -badge { ... }" CSS rule, which is always present in <style>
        -- regardless of whether anything actually pinned -- checking for
        -- the <span> markup itself is what actually proves the badge is
        -- (or isn't) rendered.
        assert.falsy(head_html:find('<span class="revision-badge">', 1, true))
    end)

    it("\"Up\" preserves the revision pin while staying inside the same repository, \"Start\" resets to HEAD (confirmed with the user)", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/trunk/arbortext/" base="myrepo">
<file name="README.md" href="README.md?p=10" />
</index>
</svn>]]
        }, "/svn/myrepo/trunk/arbortext/?p=10", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('<a href="../?p=10"><wa-icon name="turn-up">', 1, true))
        assert.truthy(html:find('<a href="/svn/"><wa-icon name="house">', 1, true))
    end)

    it("\"Up\" drops the revision pin at the repo root, since it exits to the Collection-of-Repositories listing there, which has no revision concept at all", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="10" path="/" base="myrepo">
<file name="README.md" href="README.md?p=10" />
</index>
</svn>]]
        }, "/svn/myrepo/?p=10", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('<a href="../"><wa-icon name="turn-up">', 1, true))
        assert.falsy(html:find('<a href="../?p=10">', 1, true))
    end)

    it("\"Start\" is absolute even at the repo root itself (0 path segments), landing one level up on the Collection-of-Repositories listing", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, "/svn/myrepo/", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('<a href="/svn/"><wa-icon name="house">', 1, true))
    end)

    it("\"Start\" on the Collection-of-Repositories listing itself is this same absolute URL, not a relative self-link", function()
        -- A relative "" would have resolved (at click time, in a real
        -- browser) against whatever URL is *currently* in the address bar
        -- -- which, after any htmx-driven navigation elsewhere on the page
        -- (this header is never re-rendered by any htmx swap), could be a
        -- completely different, deeper location than this response's own.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="0" path="Collection of Repositories">
<dir name="demo1" href="demo1/" />
</index>
</svn>]]
        }, "/svn/", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('<a href="/svn/"><wa-icon name="house">', 1, true))
    end)

    it("never marks an entry on-path for main's own content-swap request, even with a matching HX-Current-URL", function()
        -- The edge case this whole is_named_swap_target guard exists for:
        -- without it, an entry in main's response (dir.mustache is the
        -- exact same shared markup) could get incorrectly marked
        -- load-triggered just because HX-Current-URL happens to still point
        -- somewhere below it (sent at request time, before this response's
        -- own HX-Push-Url takes effect) -- main must always stay flat.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name="trunk" href="trunk/" />
</index>
</svn>]]
        }, "/svn/demo1/", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Current-URL"] = "http://host/svn/demo1/trunk/arbortext/", ["HX-Target"] = "wa-tree#svn-index" }
        )

        assert.truthy(html:find(
            '<wa-tree-item class="dir" hx-get="/svn/demo1/trunk/" hx-trigger="wa-lazy-load"',
            1, true
        ))
    end)

    it("never marks anything on-path without HX-Current-URL at all, e.g. a plain non-htmx page load", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/" base="myrepo">
<dir name="trunk" href="trunk/" />
</index>
</svn>]]
        }, "/svn/demo1/", { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find(
            '<wa-tree-item class="dir" hx-get="/svn/demo1/trunk/" hx-trigger="wa-lazy-load"',
            1, true
        ))
    end)

    it("returns HX-Push-Url only for the main-content-swap request, not nav's own in-place expansion", function()
        -- htmx's own "HX-Target" request header names the resolved swap
        -- target as "<tagname>#<id>" (confirmed via a real browser), not a
        -- bare id -- dir.mustache's label targets "#svn-index"
        -- (hx-target="#svn-index"), so that specific request arrives as
        -- "wa-tree#svn-index": a named target, per is_named_swap_target.
        -- Only *that* request represents an actual "navigate to a new
        -- folder", so only it should push a new URL; the nav tree's own
        -- lazy expansion targets "this" (an element with no id), which
        -- htmx sends as just "wa-tree-item" -- an unnamed target, so it
        -- must not push anything, since it never changes what main is
        -- showing.
        local fixture = {
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/arbortext/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }

        local _, main_swap_r = run_filter(
            fixture, "/svn/demo1/trunk/arbortext/", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Target"] = "wa-tree#svn-index" }
        )
        assert.are.equal("/svn/demo1/trunk/arbortext/", main_swap_r.headers_out["HX-Push-Url"])

        local _, nav_expand_r = run_filter(
            fixture, "/svn/demo1/trunk/arbortext/", { SVN_INDEX_TEMPLATE = "wa-page" },
            { ["HX-Target"] = "wa-tree-item" }
        )
        assert.is_nil(nav_expand_r.headers_out["HX-Push-Url"])

        local _, no_htmx_r = run_filter(
            fixture, "/svn/demo1/trunk/arbortext/", { SVN_INDEX_TEMPLATE = "wa-page" }
        )
        assert.is_nil(no_htmx_r.headers_out["HX-Push-Url"])
    end)

    it("logs HX-Current-URL when htmx sends it, and skips the log line otherwise", function()
        local fixture = {
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }

        local function has_current_url_log(r)
            for _, entry in ipairs(r.logs) do
                if entry.msg:find("HX-Current-URL: http://example/here", 1, true) then
                    return true
                end
            end

            return false
        end

        local _, with_header_r = run_filter(
            fixture, nil, nil, { ["HX-Current-URL"] = "http://example/here" }
        )
        assert.truthy(has_current_url_log(with_header_r))

        local _, without_header_r = run_filter(fixture)

        for _, entry in ipairs(without_header_r.logs) do
            assert.falsy(entry.msg:find("HX-Current-URL", 1, true))
        end
    end)

    it("pulls the breadcrumb, footer, and header cluster along via hx-select-oob on dir.mustache's own main-swap label", function()
        -- All three would otherwise go stale once main's content is
        -- swapped to a different directory -- the footer shows the current
        -- repository/path/revision, the same kind of "reflects wherever
        -- main currently is" content the breadcrumb already is, and the
        -- header cluster's own "History" link (history_href, see
        -- template_context) is both absolute and request-specific --
        -- unlike "Start" (fixed) or "Up" (a relative href that re-resolves
        -- against wherever the browser currently is), it goes stale after
        -- exactly this kind of non-reloading navigation unless refreshed
        -- the same way.
        -- Rather than a server-side distinction (like HX-Push-Url's
        -- "wa-tree#svn-index" HX-Target check above), this is scoped
        -- entirely client-side: only dir.mustache's label itself (the
        -- element with hx-target="#svn-index") carries
        -- hx-select-oob="#svn-breadcrumb,#svn-footer,#svn-header-left", so only
        -- *its own* requests ever pull the fetched page's
        -- breadcrumb/footer/header along -- nav's own in-place lazy-load
        -- fetch is a different element entirely (no hx-select-oob at all)
        -- and is naturally unaffected, with no header-sniffing needed on
        -- the Lua side. "#svn-breadcrumb" is the wrapping div (not just
        -- <wa-breadcrumb> itself), so the revision badge -- a sibling
        -- inside that same div -- rides along with it as one conceptual
        -- unit. Scoped to that div, not the whole "#svn-subheader", so this
        -- swap leaves the "Show folders" wa-switch (also inside
        -- #svn-subheader) alone -- its own checked state would otherwise reset
        -- every time main navigates to a new directory. The footer and
        -- header cluster have no such stateful sibling to protect (both
        -- purely informational/navigational), so each is targeted as a
        -- whole, unlike #svn-subheader.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<dir name="arbortext" href="arbortext/" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('<div class="wa-cluster" id="svn-breadcrumb">', 1, true))
        assert.truthy(html:find('<footer slot="footer" id="svn-footer" class="wa-font-size-xs">', 1, true))
        assert.truthy(html:find('<div class="wa-cluster" id="svn-header-left">', 1, true))
        assert.truthy(html:find(
            '<span hx-get="/svn/demo1/arbortext/" hx-target="#svn-index" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item" hx-select-oob="#svn-breadcrumb,#svn-footer,#svn-header-left" hx-trigger="click[this.parentElement.selected]">',
            1, true
        ))
    end)

    it("sets a new weak ETag for the transformed body on a plain page load, replacing mod_dav_svn's own original one", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        })

        assert.are.equal('W/"7-lua"', r.headers_out["ETag"])
    end)

    it("still sets the new ETag for a main-content-swap request even with HX-Current-URL present -- the omission below is scoped to nav's own fetches specifically, not to \"any htmx request\"", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, nil,
            { ["HX-Current-URL"] = "http://host/svn/demo1/trunk/", ["HX-Target"] = "wa-tree#svn-index" }
        )

        assert.are.equal('W/"7-lua"', r.headers_out["ETag"])
    end)

    it("does not set the new ETag for nav's own root/lazy-expansion fetches, since their expanded/selected markers can differ for the identical URL+revision depending on HX-Current-URL", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, nil,
            { ["HX-Current-URL"] = "http://host/svn/demo1/trunk/", ["HX-Target"] = "wa-tree" }
        )

        assert.falsy(r.headers_out["ETag"])
    end)

    it("does not set the new ETag on the Collection of Repositories listing, which has no revision concept at all, even though mod_dav_svn still emits a \"rev\" attribute there", function()
        -- Confirmed against a real server: mod_dav_svn's Collection-of-
        -- Repositories listing omits "base" but NOT necessarily "rev"
        -- (e.g. still emits rev="0") -- this fixture deliberately includes
        -- it, proving the ETag guard keys off "index.base ~= \"\"" (the
        -- same has_base signal used everywhere else in this file), not
        -- "index.rev ~= \"\"", which would otherwise wrongly treat this
        -- page as having a real revision.
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="0" path="Collection of Repositories">
<dir name="demo1" href="demo1/" />
</index>
</svn>]]
        })

        assert.falsy(r.headers_out["ETag"])
    end)

    it("does not set Cache-Control on a plain, non-htmx page load, since that response is always the same, safely cacheable document for its URL", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        })

        assert.falsy(r.headers_out["Cache-Control"])
    end)

    it("sets Cache-Control: no-store for a main-content-swap request, since it shares its URL with nav's own lazy-expansion fetches and only request headers distinguish them", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, nil,
            { ["HX-Request"] = "true", ["HX-Current-URL"] = "http://host/svn/demo1/trunk/", ["HX-Target"] = "wa-tree#svn-index" }
        )

        assert.are.equal("no-store", r.headers_out["Cache-Control"])
    end)

    it("sets Cache-Control: no-store for nav's own lazy-expansion fetches, so a cache never replays a stale expansion state for a URL it shares with other requests", function()
        local _, r = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, nil,
            { ["HX-Request"] = "true", ["HX-Current-URL"] = "http://host/svn/demo1/trunk/", ["HX-Target"] = "wa-tree" }
        )

        assert.are.equal("no-store", r.headers_out["Cache-Control"])
    end)

    it("renders an empty {{{page-head-end}}} placeholder by default (all four shipped templates ship an empty page-head-end.mustache)", function()
        local fixture = {
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }

        for _, template_type in ipairs({ "simple", "htmx", "htmx-remix", "wa-page" }) do
            local html = run_filter(fixture, nil, { SVN_INDEX_TEMPLATE = template_type })

            assert.truthy(html:find("</style>\n\n</head>", 1, true))
        end
    end)

    it("renders page-head-end.mustache's content, with the same context as page.mustache, just before </head>", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<file name="README.md" href="README.md" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "test-custom-override" })

        -- page-head-end.custom.mustache (see below) sits alongside
        -- page-head-end.mustache in templates/test-custom-override/ -- this
        -- confirms the *default* file's own content renders when no
        -- override is requested, elsewhere in this same describe block.
        local head_start, head_end = html:find("<head>.-</head>")
        assert.truthy(head_start)

        -- "/" is escaped to "&#x2F;" by lustache's own default table, same
        -- as every other {{...}}-interpolated field in this file (see the
        -- very first test above) -- page-head-end.custom.mustache uses
        -- plain {{path}}, so it's escaped like any other template variable.
        local head_html = html:sub(head_start, head_end)
        assert.truthy(head_html:find('<meta name="custom-page-head-end" content="&#x2F;trunk&#x2F;">', 1, true))
        assert.falsy(head_html:find("default-page-head-end", 1, true))
    end)

    it("prefers a \"name.custom.mustache\" file over \"name.mustache\" for any template, not just page-head-end", function()
        -- templates/test-custom-override/ ships both dir.mustache (would
        -- render "DEFAULT-DIR:...") and dir.custom.mustache (renders
        -- "CUSTOM-DIR:..." with an extra CSS class) -- proving the override
        -- convention implemented in read_template() applies uniformly to
        -- every template file svn-index.lua loads, not just the new
        -- page-head-end one.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<dir name="arbortext" href="arbortext/" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "test-custom-override" })

        assert.truthy(html:find('<li class="dir-custom">CUSTOM-DIR:', 1, true))
        assert.falsy(html:find("DEFAULT-DIR:", 1, true))
    end)
end)
