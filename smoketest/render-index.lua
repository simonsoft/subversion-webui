-- Standalone driver for nav-large-folder.test.mjs: dofile()s the REAL
-- mod-lua/svn-index.lua directly (same non-require'd pattern spec/*.lua
-- already uses) and drives its real output_filter through the same
-- coroutine/bucket mock-request protocol spec/svn_index_spec.lua's own
-- run_filter helper uses -- so the browser smoke test's server answers
-- each page load and htmx fetch with actually-rendered HTML.
--
-- Reads the <svn><index> XML from stdin. arg[1] is the request URI;
-- optional arg[2]/arg[3] are the HX-Target/HX-Current-URL request headers
-- of an htmx-issued fetch (HX-Request is set whenever arg[2] is given).
--
-- Writes the rendered HTML to stdout. Any r:err(...) log entry from
-- svn-index.lua is written to stderr and treated as a hard failure here
-- (os.exit(1)), same as render-fixture.lua.

local function script_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source and source:match("(.*[/\\])") or "./"
end

local ROOT = script_dir() .. "../"

dofile(ROOT .. "mod-lua/svn-index.lua")

local function make_request(uri, hx_target, hx_current_url)
    local headers_in = {}

    if hx_target then
        headers_in["HX-Request"] = "true"
        headers_in["HX-Target"] = hx_target
        headers_in["HX-Current-URL"] = hx_current_url
    end

    local r = {
        method = "GET",
        uri = uri:match("^([^?#]*)"),
        unparsed_uri = uri,
        args = uri:match("%?(.*)$"),
        content_type = "text/xml; charset=utf-8",
        subprocess_env = { SVN_INDEX_TEMPLATE = "wa-page" },
        headers_in = headers_in,
        headers_out = {},
        logs = {}
    }

    local function logger(level)
        return function(self, msg) table.insert(self.logs, { level = level, msg = msg }) end
    end

    r.info, r.debug, r.warn, r.err = logger("info"), logger("debug"), logger("warn"), logger("err")

    return r
end

local function run_output_filter(xml, r)
    local co = coroutine.create(function() return output_filter(r) end)
    local chunks = { xml }

    _G.bucket = nil

    local i = 0
    local pieces = {}

    while true do
        local ok, yielded = coroutine.resume(co)

        if not ok then
            io.stderr:write("output_filter raised an error: " .. tostring(yielded) .. "\n")
            os.exit(1)
        end

        if coroutine.status(co) == "dead" then
            break
        end

        pieces[#pieces + 1] = yielded
        i = i + 1
        _G.bucket = chunks[i]
    end

    _G.bucket = nil

    local had_error = false
    for _, entry in ipairs(r.logs) do
        if entry.level == "err" then
            io.stderr:write("svn-index.lua logged an error: " .. entry.msg .. "\n")
            had_error = true
        end
    end

    if had_error then
        os.exit(1)
    end

    return table.concat(pieces)
end

io.write(run_output_filter(io.read("*a"), make_request(arg[1], arg[2], arg[3])))
