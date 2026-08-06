-- See svn_index_spec.lua's header comment for how this drives the
-- coroutine/bucket streaming protocol mod_lua uses in production.
local function spec_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source:match("(.*/)") or "./"
end

local ROOT = spec_dir() .. "../"

dofile(ROOT .. "mod-lua/xslt-polyfill.lua")

local function make_request(subprocess_env)
    local r = {
        method = "GET",
        uri = "/svn/demo1/",
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
    r.warn = logger("warn")
    r.err = logger("err")

    return r
end

local function run_filter(chunks, subprocess_env)
    local r = make_request(subprocess_env)
    local co = coroutine.create(function()
        return output_filter(r)
    end)

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

describe("xslt-polyfill output_filter", function()
    it("inserts the polyfill script as the root element's first child", function()
        local xml = run_filter({
            [[<?xml version="1.0" encoding="utf-8"?>
<?xml-stylesheet type="text/xsl" href="/svn.xsl"?>
<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="242" path="/" base="demo1">
<updir href="../"/>
</index>
</svn>
]]
        }, { XSLT_POLYFILL_URL = "/static/xslt-polyfill.min.js" })

        local expected = '<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">'
            .. '<script src="/static/xslt-polyfill.min.js" xmlns="http://www.w3.org/1999/xhtml"></script>'

        assert.truthy(xml:find(expected, 1, true))

        -- Comes after the leading declaration/PI, not before them.
        local _, decl_pos = xml:find("<?xml-stylesheet", 1, true)
        local script_pos = xml:find("<script", 1, true)
        assert.truthy(decl_pos < script_pos)
    end)

    it("works across multiple input buckets, even split mid-tag", function()
        local xml = run_filter({
            [[<?xml version="1.0"?>
<sv]],
            [[n version="1.14.1">
<index rev="1" path="/" base="demo1"/>
</svn>
]]
        }, { XSLT_POLYFILL_URL = "/static/xslt-polyfill.min.js" })

        assert.truthy(xml:find(
            '<svn version="1.14.1"><script src="/static/xslt-polyfill.min.js" xmlns="http://www.w3.org/1999/xhtml"></script>',
            1, true
        ))
    end)

    it("leaves the body byte-for-byte unmodified when XSLT_POLYFILL_URL is unset", function()
        local fixture = [[<svn version="1.14.1"><index rev="1" path="/" base="demo1"/></svn>]]

        local xml = run_filter({ fixture })

        assert.are.equal(fixture, xml)
        assert.are.equal("1234", ({ ["Content-Length"] = "1234" })["Content-Length"])
    end)

    it("clears Content-Length and ETag once the body is modified", function()
        local fixture = [[<svn version="1.14.1"><index rev="1" path="/" base="demo1"/></svn>]]

        local _, r = run_filter({ fixture }, { XSLT_POLYFILL_URL = "/static/xslt-polyfill.min.js" })

        assert.is_nil(r.headers_out["Content-Length"])
        assert.is_nil(r.headers_out["ETag"])
    end)

    it("does not touch headers when the body is left unmodified", function()
        local fixture = [[<svn version="1.14.1"><index rev="1" path="/" base="demo1"/></svn>]]

        local _, r = run_filter({ fixture })

        assert.are.equal("1234", r.headers_out["Content-Length"])
        assert.are.equal('"abc"', r.headers_out["ETag"])
    end)

    it("leaves a self-closing root element untouched (no child slot to insert into)", function()
        local fixture = [[<?xml version="1.0"?><svn version="1.14.1"/>]]

        local xml = run_filter({ fixture }, { XSLT_POLYFILL_URL = "/static/xslt-polyfill.min.js" })

        assert.are.equal(fixture, xml)
    end)

    it("skips comments preceding the root element", function()
        local xml = run_filter({
            [[<?xml version="1.0"?><!-- a > b --><svn version="1.14.1"><index/></svn>]]
        }, { XSLT_POLYFILL_URL = "/static/xslt-polyfill.min.js" })

        assert.truthy(xml:find(
            '<svn version="1.14.1"><script src="/static/xslt-polyfill.min.js" xmlns="http://www.w3.org/1999/xhtml"></script>',
            1, true
        ))
    end)

    it("HTML-attribute-escapes a polyfill URL containing a double quote", function()
        local fixture = [[<svn version="1.14.1"><index/></svn>]]

        local xml = run_filter({ fixture }, { XSLT_POLYFILL_URL = '/static/x"ss.js' })

        assert.truthy(xml:find('src="/static/x&quot;ss.js"', 1, true))
    end)

    it("gives up and passes the body through unmodified once the buffered prologue exceeds the size cap", function()
        -- No '<' anywhere in this, so find_insertion_point never even gets
        -- a candidate to evaluate -- it should just keep returning nil
        -- until the cap trips.
        local fixture = string.rep("x", 70000)

        local xml, r = run_filter({ fixture }, { XSLT_POLYFILL_URL = "/static/xslt-polyfill.min.js" })

        assert.are.equal(fixture, xml)
        assert.are.equal("1234", r.headers_out["Content-Length"])
        assert.are.equal('"abc"', r.headers_out["ETag"])

        local warned = false
        for _, entry in ipairs(r.logs) do
            if entry.level == "warn" then
                warned = true
            end
        end
        assert.truthy(warned)
    end)

    it("passes later buckets straight through once resolved, unmodified", function()
        local xml = run_filter({
            [[<svn version="1.14.1"><index/>]],
            [[<extra>more]],
            [[ content</extra></svn>]]
        }, { XSLT_POLYFILL_URL = "/static/xslt-polyfill.min.js" })

        assert.truthy(xml:find(
            '<script src="/static/xslt-polyfill.min.js" xmlns="http://www.w3.org/1999/xhtml"></script>',
            1, true
        ))
        assert.truthy(xml:find("<extra>more content</extra>", 1, true))
    end)
end)
