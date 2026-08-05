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

-- unparsed_uri defaults to mirroring `uri` -- correct for every existing
-- fixture, which only ever uses plain ASCII paths where the encoded
-- (r.unparsed_uri) and decoded (r.uri) forms are identical anyway. Pass it
-- explicitly to test percent-encoding-sensitive behavior (see the
-- "request_href" note in output_filter for why the real filter reads
-- r.unparsed_uri, not r.uri).
local function make_request(uri, subprocess_env, headers_in, unparsed_uri)
    local r = {
        method = "GET",
        uri = uri or "/svn/demo1/",
        unparsed_uri = unparsed_uri or uri or "/svn/demo1/",
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
        assert.truthy(html:find('<footer slot="footer">', 1, true))
        assert.truthy(html:find(
            '<wa-tree-item class="file"><a href="/svn/demo1/README.md"><wa-icon name="file" variant="regular"></wa-icon> README.md</a></wa-tree-item>',
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
            '<wa-breadcrumb-item hx-get="/svn/myrepo/" hx-target="#svn-index" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item" hx-select-oob="#breadcrumb" hx-trigger="click"><wa-icon name="database"></wa-icon> myrepo</wa-breadcrumb-item>',
            1, true
        ))
        assert.truthy(html:find(
            '<wa-breadcrumb-item hx-get="/svn/myrepo/trunk/" hx-target="#svn-index" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item" hx-select-oob="#breadcrumb" hx-trigger="click"><wa-icon name="folder" variant="regular"></wa-icon> trunk</wa-breadcrumb-item>',
            1, true
        ))
        assert.truthy(html:find(
            '<wa-breadcrumb-item><wa-icon name="folder" variant="regular"></wa-icon> arbortext</wa-breadcrumb-item>',
            1, true
        ))
        assert.truthy(html:find('<a href="../../../"><wa-icon name="house">', 1, true))
        assert.truthy(html:find('<a href="../"><wa-icon name="arrow-up">', 1, true))
    end)

    it("hides the \"Up\" link and collapses the breadcrumb to a single, icon-less, unlinked crumb on the Collection of Repositories listing", function()
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index path="Collection of Repositories">
<dir name="demo1" href="demo1/" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.falsy(html:find('<wa-icon name="arrow-up">', 1, true))
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
        -- chevron interaction can fire it. Separately, clicking the label
        -- itself (a plain "click", not "click once") re-fetches and swaps
        -- #svn-index's content every time, so main updates no matter how
        -- many times the same or a different entry is clicked.
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
            '<span hx-get="/svn/demo1/arbortext/" hx-target="#svn-index" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item" hx-select-oob="#breadcrumb" hx-trigger="click">',
            1, true
        ))
        assert.falsy(html:find("click once", 1, true))
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
        -- script always contain those strings regardless of fixture.
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

        assert.truthy(html:find('<wa-tree class="svn-index" id="svn-index">', 1, true))
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
            '<wa-tree class="svn-nav" hx-get="/svn/myrepo/" hx-trigger="load" hx-target="this" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item">',
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

    it("pulls the breadcrumb along via hx-select-oob on dir.mustache's own main-swap label", function()
        -- The breadcrumb would otherwise go stale once main's content is
        -- swapped to a different directory. Rather than a server-side
        -- distinction (like HX-Push-Url's "wa-tree#svn-index" HX-Target
        -- check above), this is scoped entirely client-side: only
        -- dir.mustache's label itself (the element with
        -- hx-target="#svn-index") carries hx-select-oob="#breadcrumb", so
        -- only *its own* requests ever pull the fetched page's breadcrumb
        -- along -- nav's own in-place lazy-load fetch is a different
        -- element entirely (no hx-select-oob at all) and is naturally
        -- unaffected, with no header-sniffing needed on the Lua side.
        -- Scoped to "#breadcrumb" specifically, not the whole
        -- "#subheader", so this swap leaves the "Show folders" wa-switch
        -- (also inside #subheader) alone -- its own checked state would
        -- otherwise reset every time main navigates to a new directory.
        local html = run_filter({
            [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<dir name="arbortext" href="arbortext/" />
</index>
</svn>]]
        }, nil, { SVN_INDEX_TEMPLATE = "wa-page" })

        assert.truthy(html:find('<wa-breadcrumb id="breadcrumb">', 1, true))
        assert.truthy(html:find(
            '<span hx-get="/svn/demo1/arbortext/" hx-target="#svn-index" hx-swap="innerHTML" hx-select=".svn-index > wa-tree-item" hx-select-oob="#breadcrumb" hx-trigger="click">',
            1, true
        ))
    end)
end)
