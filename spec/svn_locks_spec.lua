-- Mirrors spec/svn_log_spec.lua's own harness style: dofile()s the mod_lua
-- script directly (not require'd) and drives it through the same
-- coroutine/bucket streaming protocol Apache's mod_lua uses in production.
local function spec_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source:match("(.*/)") or "./"
end

local ROOT = spec_dir() .. "../"

dofile(ROOT .. "mod-lua/svn-locks.lua")

-- headers_in defaults to both the Content-Type AND the "HX-Svn-Report:
-- locks" header fetchLocks() actually sends (see page.mustache) -- the
-- combination that represents "this app's own synthetic locks REPORT" for
-- the majority of input_filter tests, which are about body construction,
-- not gating. Pass an explicit headers_in (including a bare {} for
-- "absent") to test the gate itself.
local function make_request(method, unparsed_uri, subprocess_env, headers_in)
    local raw_target = unparsed_uri or "/svn/demo1/"

    local r = {
        method = method or "REPORT",
        uri = raw_target:match("^([^?#]*)"),
        unparsed_uri = raw_target,
        args = raw_target:match("%?(.*)$"),
        subprocess_env = subprocess_env or {},
        headers_in = headers_in or {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["HX-Svn-Report"] = "locks"
        },
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

-- Drives input_filter(r) through mod_lua's own documented protocol -- see
-- spec/svn_log_spec.lua's own run_input_filter for the full rationale.
local function run_input_filter(chunks, unparsed_uri, subprocess_env, method, headers_in)
    local r = make_request(method, unparsed_uri, subprocess_env, headers_in)
    local co = coroutine.create(function()
        return input_filter(r)
    end)

    _G.bucket = nil

    local i = 0
    local pieces = {}
    local yield_count = 0

    while true do
        local ok, yielded = coroutine.resume(co)

        if not ok then
            error("input_filter raised an error: " .. tostring(yielded))
        end

        if coroutine.status(co) == "dead" then
            break
        end

        yield_count = yield_count + 1

        if yielded then
            pieces[#pieces + 1] = yielded
        end

        i = i + 1
        _G.bucket = (chunks or {})[i]
    end

    _G.bucket = nil

    return table.concat(pieces), r, yield_count
end

-- Drives output_filter(r) exactly like spec/svn_log_spec.lua's own
-- run_output_filter. lock-badge.mustache only exists under templates/wa-page/
-- (this feature is wired into the wa-page skin only -- see README.md), so
-- default to it here.
local function run_output_filter(chunks, unparsed_uri, subprocess_env)
    local r = make_request("REPORT", unparsed_uri, subprocess_env or { SVN_INDEX_TEMPLATE = "wa-page" })
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

describe("svn-locks input_filter", function()
    it("never touches bucket and yields nothing for a non-REPORT request", function()
        local body, _, yield_count = run_input_filter(
            { "ignored" }, "/svn/demo1/trunk/", nil, "GET"
        )

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
    end)

    it("passes through untouched for a REPORT with an absent HX-Svn-Report header", function()
        local body, _, yield_count = run_input_filter(
            { "ignored" }, "/svn/demo1/trunk/", nil, "REPORT",
            { ["Content-Type"] = "application/x-www-form-urlencoded" }
        )

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
    end)

    it("passes through untouched for a REPORT marked HX-Svn-Report: log (svn-log.lua's own traffic)", function()
        local body, _, yield_count = run_input_filter(
            { "ignored" }, "/svn/demo1/trunk/", nil, "REPORT",
            { ["Content-Type"] = "application/x-www-form-urlencoded", ["HX-Svn-Report"] = "log" }
        )

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
    end)

    it("passes through untouched for a real REPORT request declaring Content-Type: text/xml, even with HX-Svn-Report: locks", function()
        local body, _, yield_count = run_input_filter(
            { "ignored" }, "/svn/demo1/trunk/", nil, "REPORT",
            { ["Content-Type"] = "text/xml", ["HX-Svn-Report"] = "locks" }
        )

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
    end)

    it("synthesizes a get-locks-report body at immediates depth, with an empty <S:path> (the request URI itself)", function()
        local body = run_input_filter({}, "/svn/demo1/trunk/")

        assert.truthy(body:find('<S:get-locks-report xmlns:S="svn:" xmlns:D="DAV:">', 1, true))
        assert.truthy(body:find('<S:path></S:path>', 1, true))
        assert.truthy(body:find('<S:depth>immediates</S:depth>', 1, true))
        assert.truthy(body:find('</S:get-locks-report>', 1, true))
    end)

    it("discards whatever body chunks the client actually sent", function()
        local body = run_input_filter({ "some", "client", "body" }, "/svn/demo1/trunk/")

        assert.falsy(body:find("some", 1, true))
        assert.falsy(body:find("client", 1, true))
    end)

    it("sets Content-Type/Content-Length on the synthesized body", function()
        local body, r = run_input_filter({}, "/svn/demo1/trunk/")

        assert.are.equal("text/xml; charset=utf-8", r.headers_in["Content-Type"])
        assert.are.equal(tostring(#body), r.headers_in["Content-Length"])
    end)
end)

describe("svn-locks output_filter", function()
    it("renders one lock-badge OOB fragment per <S:lock>, keyed by the same percent-encoded path_id svn-index.lua computes", function()
        local html = run_output_filter({
            [[<S:get-locks-report xmlns:S="svn:" xmlns:D="DAV:">
<S:lock>
<S:path>/trunk/my file.txt</S:path>
<S:token>opaquelocktoken:abc</S:token>
<S:owner>alice</S:owner>
<S:comment>Editing chapter 3</S:comment>
<S:created>2026-08-15T10:23:41.000000Z</S:created>
</S:lock>
</S:get-locks-report>]]
        })

        assert.truthy(html:find('id="lock-/trunk/my%20file.txt"', 1, true))
        assert.truthy(html:find('hx-swap-oob="true"', 1, true))
        assert.truthy(html:find("Locked by alice", 1, true))
        assert.truthy(html:find("2026-08-15T10:23:41.000000Z", 1, true))
        assert.truthy(html:find("Editing chapter 3", 1, true))
    end)

    it("omits the comment clause entirely when a lock has no comment", function()
        local html = run_output_filter({
            [[<S:get-locks-report xmlns:S="svn:" xmlns:D="DAV:">
<S:lock>
<S:path>/trunk/README.md</S:path>
<S:owner>bob</S:owner>
<S:created>2026-08-15T10:23:41.000000Z</S:created>
</S:lock>
</S:get-locks-report>]]
        })

        assert.truthy(html:find('Locked by bob (2026-08-15T10:23:41.000000Z)"', 1, true))
    end)

    it("renders a badge per lock when multiple files are locked", function()
        local html = run_output_filter({
            [[<S:get-locks-report xmlns:S="svn:" xmlns:D="DAV:">
<S:lock>
<S:path>/trunk/a.txt</S:path>
<S:owner>alice</S:owner>
<S:created>2026-08-15T10:00:00.000000Z</S:created>
</S:lock>
<S:lock>
<S:path>/trunk/b.txt</S:path>
<S:owner>bob</S:owner>
<S:created>2026-08-15T11:00:00.000000Z</S:created>
</S:lock>
</S:get-locks-report>]]
        })

        local _, a_pos = html:find('id="lock-/trunk/a.txt"', 1, true)
        local _, b_pos = html:find('id="lock-/trunk/b.txt"', 1, true)

        assert.truthy(a_pos)
        assert.truthy(b_pos)
        assert.truthy(a_pos < b_pos)
    end)

    it("renders an empty body for zero locks, rather than an empty wrapper element", function()
        local html = run_output_filter({
            [[<S:get-locks-report xmlns:S="svn:" xmlns:D="DAV:">
</S:get-locks-report>]]
        })

        assert.are.equal("", html)
    end)

    it("HTML-escapes owner/comment, and percent-encodes path_id, without double-encoding", function()
        local html = run_output_filter({
            [[<S:get-locks-report xmlns:S="svn:" xmlns:D="DAV:">
<S:lock>
<S:path>/trunk/a &amp; b (draft).txt</S:path>
<S:owner>o'brien</S:owner>
<S:comment>&lt;script&gt;</S:comment>
<S:created>2026-08-15T10:00:00.000000Z</S:created>
</S:lock>
</S:get-locks-report>]]
        })

        -- Source XML entities (&amp;, &lt;, &gt;) are decoded by the parser
        -- before Lua ever sees the text (item.path is a literal "&", item.
        -- comment a literal "<script>") -- percent_encode_path/escape_html
        -- then encode those raw bytes exactly once.
        assert.truthy(html:find('id="lock-/trunk/a%20%26%20b%20%28draft%29.txt"', 1, true))
        assert.truthy(html:find("o&#39;brien", 1, true))
        assert.truthy(html:find("&lt;script&gt;", 1, true))
    end)

    it("logs an error and stops cleanly on malformed XML, instead of crashing the filter", function()
        local html, r = run_output_filter({ "<S:get-locks-report><S:lock>" })

        local has_error = false
        for _, entry in ipairs(r.logs) do
            if entry.level == "err" then
                has_error = true
            end
        end

        assert.truthy(has_error)
    end)

    it("renders across multiple buckets split mid-element", function()
        local html = run_output_filter({
            [[<S:get-locks-report xmlns:S="svn:" xmlns:D="DAV:">
<S:lock>
<S:path>/trunk/a.txt</S:path>
<S:ow]],
            [[ner>alice</S:owner>
<S:created>2026-08-15T10:00:00.000000Z</S:created>
</S:lock>
</S:get-locks-report>]]
        })

        assert.truthy(html:find('id="lock-/trunk/a.txt"', 1, true))
        assert.truthy(html:find("Locked by alice", 1, true))
    end)
end)
