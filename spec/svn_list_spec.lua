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

dofile(ROOT .. "mod-lua/svn-list.lua")

local function make_request()
    local r = {
        method = "GET",
        uri = "/svn/demo1/",
        content_type = "text/xml; charset=utf-8",
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
local function run_filter(chunks)
    local r = make_request()
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

describe("svn-list output_filter", function()
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
end)
