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

local function make_request(uri, subprocess_env)
    local r = {
        method = "GET",
        uri = uri or "/svn/demo1/",
        content_type = "text/xml; charset=utf-8",
        subprocess_env = subprocess_env or {},
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
    r.err = logger("err")

    return r
end

-- Feeds `chunks` to output_filter(r) one at a time via the global `bucket`,
-- mirroring mod_lua's runtime: `bucket` is still nil on the very first
-- resume, and only gets set to the next chunk *after* the script yields
-- (that first yield is the handshake that tells the runtime to fetch
-- input) -- pre-populating it before the first resume would hide a script
-- that forgets to yield before ever touching `bucket`.
local function run_filter(chunks, uri, subprocess_env)
    local r = make_request(uri, subprocess_env)
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
        -- .updir` rule distinguishes the two structurally.
        for _, template_type in ipairs({ "htmx", "wa-page" }) do
            local html = run_filter({
                [[<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="7" path="/trunk/" base="myrepo">
<updir href="../"/>
<file name="README.md" href="README.md" />
</index>
</svn>]]
            }, nil, { SVN_INDEX_TEMPLATE = template_type })

            assert.truthy(html:find("li .updir {", 1, true), template_type .. " should hide nested .updir")
            assert.truthy(html:find("display: none;", 1, true), template_type .. " should hide nested .updir")
        end

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
        assert.truthy(html:find('<li class="file"><a href="/svn/demo1/README.md">README.md</a></li>', 1, true))
    end)
end)
