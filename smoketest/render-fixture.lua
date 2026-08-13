-- Standalone driver for history-dialog.test.mjs: dofile()s the REAL
-- mod-lua/svn-log.lua directly (same non-require'd pattern spec/*.lua
-- already uses) and drives its real output_filter through the same
-- coroutine/bucket mock-request protocol spec/svn_log_spec.lua's own
-- run_output_filter helper uses, against a realistic multi-entry
-- <S:log-report> XML fixture -- so the browser smoke test exercises
-- actually-rendered HTML, not a hand-approximated mock of what the
-- templates "should" produce.
--
-- Deliberately NOT part of spec/ and NOT require()d by it: a separate,
-- standalone entry point invoked as a child process by the Node smoke
-- test, not a busted spec. spec/ itself is never modified to support this.
--
-- Writes the rendered HTML to stdout. Any r:err(...) log entry from
-- svn-log.lua is written to stderr and treated as a hard failure here
-- (os.exit(1)) -- a run that silently produced empty/partial HTML would
-- otherwise fail confusingly downstream in Puppeteer's own assertions
-- instead of at the actual point of failure.

local function script_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source and source:match("(.*[/\\])") or "./"
end

local ROOT = script_dir() .. "../"

dofile(ROOT .. "mod-lua/svn-log.lua")

local function read_file(path)
    local file, err = io.open(path, "r")

    if not file then
        io.stderr:write("failed to open fixture file '" .. path .. "': " .. tostring(err) .. "\n")
        os.exit(1)
    end

    local content = file:read("*a")
    file:close()

    return content
end

-- Mirrors spec/svn_log_spec.lua's own make_request/run_output_filter
-- helpers closely (same request field shapes, same coroutine/bucket
-- driving loop) but duplicated, not shared: no require-able module exists
-- between spec/ and this standalone script, and spec/ must not be touched.
local function make_request(unparsed_uri, subprocess_env)
    local r = {
        method = "REPORT",
        uri = unparsed_uri:match("^([^?#]*)"),
        unparsed_uri = unparsed_uri,
        args = unparsed_uri:match("%?(.*)$"),
        subprocess_env = subprocess_env or { SVN_INDEX_TEMPLATE = "wa-page" },
        headers_in = {},
        headers_out = {},
        logs = {}
    }

    local function logger(level)
        return function(self, msg) table.insert(self.logs, { level = level, msg = msg }) end
    end

    r.info, r.debug, r.warn, r.err = logger("info"), logger("debug"), logger("warn"), logger("err")

    return r
end

local function run_output_filter(xml, unparsed_uri, subprocess_env)
    local r = make_request(unparsed_uri, subprocess_env)
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
            io.stderr:write("svn-log.lua logged an error: " .. entry.msg .. "\n")
            had_error = true
        end
    end

    if had_error then
        os.exit(1)
    end

    return table.concat(pieces)
end

-- Optional CLI args (arg[1]: fixture path, arg[2]: browse URI) let a second
-- caller render a different fixture/URI combination through this same real
-- output_filter -- see history-dialog.test.mjs's own folder-toggle test
-- section. Both default to today's original hardcoded values, so the
-- original no-args invocation is unaffected.
local fixture_path = arg[1] or (script_dir() .. "fixtures/log-report.xml")
local browse_uri = arg[2] or "/svn/demo1/trunk/?repo_root=/svn/demo1/"

local fixture_xml = read_file(fixture_path)

io.write(run_output_filter(
    fixture_xml,
    browse_uri,
    { SVN_INDEX_TEMPLATE = "wa-page", SVN_LOG_LIMIT = "50" }
))
