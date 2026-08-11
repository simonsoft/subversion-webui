-- Mirrors spec/svn_index_spec.lua's own harness style: dofile()s the mod_lua
-- script directly (not require'd -- it's a plain script defining global
-- input_filter/output_filter functions) and drives it through the same
-- coroutine/bucket streaming protocol Apache's mod_lua uses in production.
--
-- Note: both svn-index.lua and svn-log.lua define a global function named
-- output_filter. busted sandboxes each spec *file's* own global writes into
-- a private table (see svn_index_spec.lua's own comment on this) -- this is
-- relied on here for the first time with two files defining the identical
-- global name; running `busted spec/` with both spec files present is the
-- actual confirmation that this isolation holds.
local function spec_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source:match("(.*/)") or "./"
end

local ROOT = spec_dir() .. "../"

dofile(ROOT .. "mod-lua/svn-log.lua")

-- unparsed_uri carries both path and query string (e.g.
-- "/svn/demo1/trunk/?p=42"); r.args is derived from it the same way real
-- Apache/mod_lua would populate it. headers_in defaults to the Content-Type
-- htmx v4 itself sends by default for the History link's request (see
-- is_form_encoded_content_type's own comment in svn-log.lua) -- the allow
-- list there means that's the ONLY value input_filter ever treats as its
-- own, so this default represents "this app's own synthetic REPORT
-- request" for the majority of input_filter tests, which are about body
-- construction, not gating. Pass an explicit headers_in (including a bare
-- {} for "absent") to test the gate itself.
local function make_request(method, unparsed_uri, subprocess_env, headers_in)
    local raw_target = unparsed_uri or "/svn/demo1/"

    local r = {
        method = method or "REPORT",
        uri = raw_target:match("^([^?#]*)"),
        unparsed_uri = raw_target,
        args = raw_target:match("%?(.*)$"),
        subprocess_env = subprocess_env or {},
        headers_in = headers_in or { ["Content-Type"] = "application/x-www-form-urlencoded" },
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

-- Drives input_filter(r) through mod_lua's own documented protocol: a bare,
-- argument-less first yield (distinct from output_filter's yield("")), then
-- one argument-less yield per drained request-body chunk, then a final
-- yield carrying the synthesized replacement body. `chunks` (defaulting to
-- none, matching production -- htmx's hx-action issues the REPORT with no
-- body) are fed into the global `bucket` between resumes exactly like
-- svn_index_spec.lua's own run_filter does for the output side.
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

-- Drives output_filter(r) exactly like svn_index_spec.lua's own run_filter.
-- log.mustache/log-item.mustache only exist under templates/wa-page/ (this
-- feature is wired into the wa-page skin only -- see README.md), so
-- default to it here rather than "simple" (svn-index.lua's own default,
-- which has no log templates at all).
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

describe("svn-log input_filter", function()
    it("never touches bucket and yields nothing for a non-REPORT request", function()
        local body, _, yield_count = run_input_filter(
            { "ignored" }, "/svn/demo1/trunk/", nil, "GET"
        )

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
    end)

    it("passes through untouched for a real REPORT request declaring Content-Type: text/xml", function()
        -- Proves real svn-client REPORT traffic (update-report,
        -- file-revs-report, etc.) against the same Location is never
        -- intercepted -- r.method alone is not a sufficient gate. Real svn
        -- clients always declare "text/xml" on a REPORT body (confirmed
        -- against libsvn_ra_serf/log.c: handler->body_type = "text/xml").
        local body, _, yield_count = run_input_filter(
            { "<S:update-report/>" }, "/svn/demo1/trunk/", nil, "REPORT",
            { ["Content-Type"] = "text/xml; charset=\"utf-8\"" }
        )

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
    end)

    it("also passes through for a bare \"application/xml\" Content-Type", function()
        local body, _, yield_count = run_input_filter(
            {}, "/svn/demo1/trunk/", nil, "REPORT",
            { ["Content-Type"] = "application/xml" }
        )

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
    end)

    it("passes through untouched for a REPORT with an absent Content-Type, rather than assuming it's ours", function()
        -- The allow-list design point: a broken/non-standard svn client
        -- that fails to declare "text/xml" the way real ones always do
        -- must still be left alone, not silently treated as this app's own
        -- just because its Content-Type isn't XML either.
        local body, _, yield_count = run_input_filter({}, "/svn/demo1/trunk/", nil, "REPORT", {})

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
    end)

    it("also passes through for an unrelated, non-XML, non-form-encoded Content-Type", function()
        local body, _, yield_count = run_input_filter(
            {}, "/svn/demo1/trunk/", nil, "REPORT",
            { ["Content-Type"] = "text/plain" }
        )

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
    end)

    it("treats a bare form-encoded Content-Type (no charset parameter) as this app's own", function()
        local body = run_input_filter(
            {}, "/svn/demo1/trunk/", nil, "REPORT",
            { ["Content-Type"] = "application/x-www-form-urlencoded" }
        )

        assert.truthy(body:find('<S:log-report', 1, true))
    end)

    it("also treats htmx v4's own actual default Content-Type (with its charset suffix) as this app's own", function()
        local body = run_input_filter(
            {}, "/svn/demo1/trunk/", nil, "REPORT",
            { ["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8" }
        )

        assert.truthy(body:find('<S:log-report', 1, true))
    end)

    it("synthesizes a log-report body with the default limit, end-revision=0, and no start-revision (HEAD)", function()
        local body = run_input_filter({}, "/svn/demo1/trunk/")

        assert.truthy(body:find('<S:log-report xmlns:S="svn:" xmlns:D="DAV:">', 1, true))
        -- end-revision must always be explicit "0": per the log-report
        -- schema, omitting it defaults to HEAD (exactly like
        -- start-revision's own default), which would otherwise collapse an
        -- unpinned request into a one-revision HEAD-to-HEAD window instead
        -- of "as far back as it goes". start-revision is left omitted here
        -- (defaults to HEAD) -- start > end (HEAD > 0) is what makes the
        -- server stream newest-first.
        assert.truthy(body:find('<S:end-revision>0</S:end-revision>', 1, true))
        assert.truthy(body:find('<S:limit>50</S:limit>', 1, true))
        assert.truthy(body:find('<S:discover-changed-paths/>', 1, true))
        assert.truthy(body:find('<S:path></S:path>', 1, true))
        assert.truthy(body:find('</S:log-report>', 1, true))
        assert.falsy(body:find('<S:start-revision>', 1, true))
    end)

    it("honors an active ?p=REV pin as the start-revision (peg), while still setting end-revision=0", function()
        local body = run_input_filter({}, "/svn/demo1/trunk/?p=42")

        assert.truthy(body:find('<S:start-revision>42</S:start-revision>', 1, true))
        assert.truthy(body:find('<S:end-revision>0</S:end-revision>', 1, true))
    end)

    it("honors SVN_LOG_LIMIT when set", function()
        local body = run_input_filter(
            {}, "/svn/demo1/trunk/", { SVN_LOG_LIMIT = "10" }
        )

        assert.truthy(body:find('<S:limit>10</S:limit>', 1, true))
    end)

    it("discards whatever body chunks the client actually sent", function()
        local body = run_input_filter(
            { "<garbage", "-not-xml->" }, "/svn/demo1/trunk/"
        )

        assert.falsy(body:find("garbage", 1, true))
        assert.truthy(body:find('<S:log-report', 1, true))
    end)

    it("falls back to defaults for an invalid revision pin or SVN_LOG_LIMIT, never emitting the raw attacker string", function()
        local body = run_input_filter(
            {}, "/svn/demo1/trunk/?p=abc", { SVN_LOG_LIMIT = "not-a-number" }
        )

        assert.truthy(body:find('<S:limit>50</S:limit>', 1, true))
        assert.falsy(body:find('<S:start-revision>', 1, true))
        assert.falsy(body:find("abc", 1, true))
        assert.falsy(body:find("not-a-number", 1, true))
    end)

    it("falls back to defaults for a negative revision pin or SVN_LOG_LIMIT", function()
        local body = run_input_filter(
            {}, "/svn/demo1/trunk/?p=-1", { SVN_LOG_LIMIT = "-5" }
        )

        assert.truthy(body:find('<S:limit>50</S:limit>', 1, true))
        assert.falsy(body:find('<S:start-revision>', 1, true))
    end)

    it("never lets non-numeric revision-pin content reach the synthesized XML body", function()
        local body = run_input_filter(
            {}, [[/svn/demo1/trunk/?p=1</S:log-report><evil>]]
        )

        assert.truthy(body:find('<S:limit>50</S:limit>', 1, true))
        assert.falsy(body:find('<S:start-revision>', 1, true))
        assert.falsy(body:find('evil', 1, true))
    end)
end)

describe("svn-log output_filter", function()
    it("renders the preamble, streamed log items and footer across multiple buckets", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>42</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T12:00:00.000000Z</S:date>
<D:comment>Fix bug</D:comment>]],
            [[<S:modified-path node-kind="file" text-mods="true" prop-mods="false">/trunk/foo.txt</S:modified-path>
</S:log-item>
<S:log-item>
<D:version-name>41</D:version-name>
<D:creator-displayname>bob</D:creator-displayname>
<S:date>2023-12-31T09:00:00.000000Z</S:date>
<D:comment>Add feature</D:comment>
<S:added-path node-kind="file" text-mods="true" prop-mods="false">/trunk/bar.txt</S:added-path>]],
            [[<S:deleted-path node-kind="file" text-mods="false" prop-mods="false">/trunk/old.txt</S:deleted-path>
</S:log-item>
</S:log-report>
]]
        }, "/svn/demo1/trunk/?p=42")

        assert.truthy(html:find('<table class="svn-log-table">', 1, true))
        assert.truthy(html:find('href="/svn/demo1/trunk/?p=42"', 1, true))

        assert.truthy(html:find('<td class="revision">42</td>', 1, true))
        assert.truthy(html:find('<td class="author">alice</td>', 1, true))
        assert.truthy(html:find('<td class="date">2024-01-01T12:00:00.000000Z</td>', 1, true))
        assert.truthy(html:find('<pre>Fix bug</pre>', 1, true))
        assert.truthy(html:find('<span class="action">M</span> /trunk/foo.txt', 1, true))

        assert.truthy(html:find('<td class="revision">41</td>', 1, true))
        assert.truthy(html:find('<span class="action">A</span> /trunk/bar.txt', 1, true))
        assert.truthy(html:find('<span class="action">D</span> /trunk/old.txt', 1, true))

        local _, rev42_pos = html:find('42</td>', 1, true)
        local _, rev41_pos = html:find('41</td>', 1, true)
        assert.truthy(rev42_pos < rev41_pos)
    end)

    it("handles the entire document arriving in a single bucket", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>7</D:version-name>
<D:creator-displayname>carol</D:creator-displayname>
<S:date>2024-02-02T00:00:00.000000Z</S:date>
<D:comment>Initial import</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.truthy(html:find('<td class="revision">7</td>', 1, true))
        assert.truthy(html:find('<td class="author">carol</td>', 1, true))
        assert.truthy(html:find('<pre>Initial import</pre>', 1, true))
    end)

    it("HTML-escapes the commit message and changed-path text", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>1</D:version-name>
<D:creator-displayname>eve</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>a &amp; b &lt;c&gt;</D:comment>
<S:added-path node-kind="file">/trunk/&lt;weird&gt;.txt</S:added-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.truthy(html:find("a &amp; b &lt;c&gt;", 1, true))
        assert.falsy(html:find("a & b <c>", 1, true))
        assert.truthy(html:find("&lt;weird&gt;.txt", 1, true))
        assert.falsy(html:find("<weird>.txt", 1, true))
    end)

    it("still renders a valid, empty table when there are zero log items", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:"></S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.truthy(html:find('<table class="svn-log-table">', 1, true))
        assert.truthy(html:find('<tbody>', 1, true))
        assert.falsy(html:find('class="log-item"', 1, true))
    end)

    it("logs an error and stops cleanly on malformed XML, instead of crashing the filter", function()
        local html, r = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:"><S:log-item></S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.are.equal("", html)

        local found_err = false
        for _, entry in ipairs(r.logs) do
            if entry.level == "err" then
                found_err = true
            end
        end
        assert.truthy(found_err)
    end)
end)
