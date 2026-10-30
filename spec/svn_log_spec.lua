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

    it("honors SVN_LOG_LIMIT_SCROLL instead of SVN_LOG_LIMIT on a continuous-scroll continuation request (?more=1)", function()
        local body = run_input_filter(
            {}, "/svn/demo1/trunk/?more=1", { SVN_LOG_LIMIT = "10", SVN_LOG_LIMIT_SCROLL = "200" }
        )

        assert.truthy(body:find('<S:limit>200</S:limit>', 1, true))
    end)

    it("ignores SVN_LOG_LIMIT_SCROLL on a plain (non-continuation) request, even when it's set", function()
        local body = run_input_filter(
            {}, "/svn/demo1/trunk/", { SVN_LOG_LIMIT = "10", SVN_LOG_LIMIT_SCROLL = "200" }
        )

        assert.truthy(body:find('<S:limit>10</S:limit>', 1, true))
    end)

    it("falls back to SVN_LOG_LIMIT's own resolution when SVN_LOG_LIMIT_SCROLL is unset on a ?more=1 request", function()
        local body = run_input_filter(
            {}, "/svn/demo1/trunk/?more=1", { SVN_LOG_LIMIT = "10" }
        )

        assert.truthy(body:find('<S:limit>10</S:limit>', 1, true))
    end)

    it("falls back all the way to the hardcoded default on a ?more=1 request when neither limit env var is set", function()
        local body = run_input_filter({}, "/svn/demo1/trunk/?more=1")

        assert.truthy(body:find('<S:limit>50</S:limit>', 1, true))
    end)

    it("falls back to SVN_LOG_LIMIT for an invalid SVN_LOG_LIMIT_SCROLL on a ?more=1 request, never emitting the raw attacker string", function()
        local body = run_input_filter(
            {}, "/svn/demo1/trunk/?more=1", { SVN_LOG_LIMIT = "10", SVN_LOG_LIMIT_SCROLL = "not-a-number" }
        )

        assert.truthy(body:find('<S:limit>10</S:limit>', 1, true))
        assert.falsy(body:find("not-a-number", 1, true))
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

    it("yields exactly one value for every drained body chunk, as mod_lua's input filter requires", function()
        -- mod_lua (httpd's mod_lua.c, lua_input_filter_handle) fails the
        -- whole request when a per-bucket yield carries no value -- which a
        -- real browser triggers, since htmx sends the clicked <wa-icon>'s
        -- own name as a form body.
        local r = make_request("REPORT", "/svn/demo1/trunk/")
        local co = coroutine.create(function() return input_filter(r) end)
        local chunks = { "clock-rotate-left=undefined", "more" }

        _G.bucket = nil
        assert.is_true((coroutine.resume(co)))

        for _, chunk in ipairs(chunks) do
            _G.bucket = chunk
            local results = table.pack(coroutine.resume(co))

            assert.is_true(results[1])
            assert.are.equal(2, results.n)
            assert.are.equal("", results[2])
        end

        _G.bucket = nil
        local ok, body = coroutine.resume(co)
        assert.is_true(ok)
        assert.truthy(body:find("<S:log-report", 1, true))
    end)

    it("synthesizes a file-revs-report from N-1 to N instead of a log-report for a diff link's request (?diff=1)", function()
        local body = run_input_filter({}, "/svn/demo1/trunk/foo.txt?p=42&diff=1&repo_root=/svn/demo1/")

        assert.are.equal(
            '<S:file-revs-report xmlns:S="svn:"><S:start-revision>41</S:start-revision>'
                .. '<S:end-revision>42</S:end-revision><S:path></S:path></S:file-revs-report>',
            body
        )
    end)

    it("never asks a diff for a negative start-revision", function()
        local body = run_input_filter({}, "/svn/demo1/trunk/foo.txt?p=0&diff=1")

        assert.truthy(body:find('<S:start-revision>0</S:start-revision>', 1, true))
        assert.truthy(body:find('<S:end-revision>0</S:end-revision>', 1, true))
    end)

    it("leaves <S:path> out of a diff request without a valid revision, so mod_dav_svn answers with its own error", function()
        for _, uri in ipairs({ "/svn/demo1/trunk/foo.txt?diff=1", [[/svn/demo1/trunk/foo.txt?p=1</S:path><evil>&diff=1]] }) do
            local body = run_input_filter({}, uri)

            assert.are.equal('<S:file-revs-report xmlns:S="svn:"></S:file-revs-report>', body)
        end
    end)

    it("still passes a real svn client's own file-revs-report through untouched, whatever its query string", function()
        local body, _, yield_count = run_input_filter(
            { "<S:file-revs-report/>" }, "/svn/demo1/trunk/foo.txt?p=42&diff=1", nil, "REPORT",
            { ["Content-Type"] = "text/xml" }
        )

        assert.are.equal("", body)
        assert.are.equal(0, yield_count)
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
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find('<div class="svn-log">', 1, true))

        assert.truthy(html:find('<a class="revision-badge wa-font-size-s" href="/svn/demo1/trunk/?p=42">42</a>', 1, true))
        assert.truthy(html:find('<wa-icon name="user" variant="solid" style="font-size: 0.8rem;"></wa-icon> <strong>alice</strong>', 1, true))
        assert.truthy(html:find('date="2024-01-01T12:00:00.000000Z" month="numeric" day="numeric" year="numeric" hour="numeric" minute="numeric"></wa-format-date>', 1, true))
        assert.truthy(html:find('<em>Fix bug</em>', 1, true))
        assert.truthy(html:find('<div class="log-message-full wa-flank wa-color-text-quiet"><wa-icon name="comment" variant="solid" style="font-size: 0.8rem;"></wa-icon><em>Fix bug</em></div>', 1, true))
        -- Followed by its diff link (see "svn-log output_filter diff
        -- links" below for that link's own markup).
        assert.truthy(html:find('<wa-icon name="pen" variant="solid" style="font-size: 0.8rem;"></wa-icon><span><a href="/svn/demo1/trunk/foo.txt?p=42">/trunk/foo.txt</a> <a class="changed-path-diff"', 1, true))

        assert.truthy(html:find('<a class="revision-badge wa-font-size-s" href="/svn/demo1/trunk/?p=41">41</a>', 1, true))
        assert.truthy(html:find('<wa-icon name="plus" variant="solid" style="font-size: 0.8rem;"></wa-icon><span><a href="/svn/demo1/trunk/bar.txt?p=41">/trunk/bar.txt</a></span>', 1, true))
        assert.truthy(html:find('<wa-icon name="trash" variant="solid" style="font-size: 0.8rem;"></wa-icon><span><a href="/svn/demo1/trunk/old.txt?p=40">/trunk/old.txt</a></span>', 1, true))

        local _, rev42_pos = html:find('>42<', 1, true)
        local _, rev41_pos = html:find('>41<', 1, true)
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

        assert.truthy(html:find('<a class="revision-badge wa-font-size-s" href="/svn/demo1/trunk/?p=7">7</a>', 1, true))
        assert.truthy(html:find('<strong>carol</strong>', 1, true))
        assert.truthy(html:find('<em>Initial import</em>', 1, true))
        assert.truthy(html:find('<div class="log-message-full wa-flank wa-color-text-quiet"><wa-icon name="comment" variant="solid" style="font-size: 0.8rem;"></wa-icon><em>Initial import</em></div>', 1, true))
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

    it("marks both message wrappers with log-message-empty (dimming the comment icon) when a revision has no log message, but not otherwise", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>1</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment></D:comment>
</S:log-item>
<S:log-item>
<D:version-name>2</D:version-name>
<D:creator-displayname>bob</D:creator-displayname>
<S:date>2024-01-02T00:00:00.000000Z</S:date>
<D:comment>Has a message</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.truthy(html:find('<div class="log-message-preview log-message-empty wa-color-text-quiet">', 1, true))
        assert.truthy(html:find('<div class="log-message-full log-message-empty wa-flank wa-color-text-quiet">', 1, true))
        assert.truthy(html:find('<div class="log-message-preview wa-color-text-quiet"><span>', 1, true))
        assert.truthy(html:find('<div class="log-message-full wa-flank wa-color-text-quiet">', 1, true))
    end)

    it("treats a whitespace-only log message as blank too, not just a literal empty string", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>1</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>

</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.truthy(html:find('<div class="log-message-preview log-message-empty wa-color-text-quiet">', 1, true))
        assert.truthy(html:find('<div class="log-message-full log-message-empty wa-flank wa-color-text-quiet">', 1, true))
    end)

    it("still renders a valid, empty div when there are zero log items", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:"></S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.truthy(html:find('<div class="svn-log">', 1, true))
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

    it("renders a copy/move's own source with a small revision badge (no icon, no @ sign), but not for a plain change", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>50</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-03-01T00:00:00.000000Z</S:date>
<D:comment>Rename file</D:comment>
<S:added-path node-kind="file" copyfrom-path="/trunk/old-name.txt" copyfrom-rev="30">/trunk/new-name.txt</S:added-path>
<S:modified-path node-kind="file">/trunk/unrelated.txt</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find('<span class="copy-from wa-color-text-quiet wa-font-size-s">from <a href="/svn/demo1/trunk/old-name.txt?p=30">/trunk/old-name.txt</a> <span class="revision-badge revision-badge-small wa-font-size-s">30</span></span>', 1, true))
        assert.falsy(html:find('arrow-right', 1, true))
        assert.falsy(html:find('@30', 1, true))

        -- The sibling plain modified-path (no copyfrom attrs) must render
        -- as a complete <li>...</li> with NO copy-from span appended --
        -- this exact, closed string wouldn't match if one leaked in. (Its
        -- diff link is the only thing after the path itself.)
        assert.truthy(html:find(
            '<li class="action-m wa-flank"><wa-icon name="pen" variant="solid" style="font-size: 0.8rem;"></wa-icon><span><a href="/svn/demo1/trunk/unrelated.txt?p=50">/trunk/unrelated.txt</a>'
                .. ' <a class="changed-path-diff" href="/svn/demo1/trunk/unrelated.txt?p=50&amp;diff=1&amp;repo_root=/svn/demo1/"'
                .. ' hx-action="/svn/demo1/trunk/unrelated.txt?p=50&amp;diff=1&amp;repo_root=/svn/demo1/" hx-method="REPORT"'
                .. ' hx-target="#svn-diff-content" hx-swap="innerHTML" hx-trigger="click" title="Diff"'
                .. ' aria-label="Diff against the previous revision"><wa-icon name="code-compare" variant="solid"></wa-icon></a></span></li>',
            1, true
        ))
    end)

    it("links a deleted path at the revision before its deletion, while sibling changes keep the entry's own revision", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>60</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-04-01T00:00:00.000000Z</S:date>
<D:comment>Remove obsolete stuff</D:comment>
<S:deleted-path node-kind="dir">/trunk/obsolete</S:deleted-path>
<S:deleted-path node-kind="file">/trunk/old.txt</S:deleted-path>
<S:replaced-path node-kind="file">/trunk/swapped.txt</S:replaced-path>
<S:modified-path node-kind="file">/trunk/kept.txt</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find('<a href="/svn/demo1/trunk/obsolete?p=59">/trunk/obsolete</a>', 1, true))
        assert.truthy(html:find('<a href="/svn/demo1/trunk/old.txt?p=59">/trunk/old.txt</a>', 1, true))
        -- A replaced path exists (as its new node) at the entry's own
        -- revision, so only an outright deletion shifts back.
        assert.truthy(html:find('<a href="/svn/demo1/trunk/swapped.txt?p=60">/trunk/swapped.txt</a>', 1, true))
        assert.truthy(html:find('<a href="/svn/demo1/trunk/kept.txt?p=60">/trunk/kept.txt</a>', 1, true))
        assert.truthy(html:find('<a class="revision-badge wa-font-size-s" href="/svn/demo1/trunk/?p=60">60</a>', 1, true))
    end)

    it("falls back to plain, unlinked changed-path text when repo_root is absent, while the revision badge still links", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>12</D:version-name>
<D:creator-displayname>bob</D:creator-displayname>
<S:date>2024-01-05T00:00:00.000000Z</S:date>
<D:comment>No repo_root here</D:comment>
<S:modified-path node-kind="file">/trunk/foo.txt</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.truthy(html:find('<a class="revision-badge wa-font-size-s" href="/svn/demo1/trunk/?p=12">12</a>', 1, true))
        -- This exact, closed substring (icon straight through to the
        -- </li>, no <a href> in between) wouldn't match if a link had
        -- been produced.
        assert.truthy(html:find('<wa-icon name="pen" variant="solid" style="font-size: 0.8rem;"></wa-icon><span>/trunk/foo.txt</span></li>', 1, true))
    end)

    it("percent-encodes changed-path segments (space, parens, ampersand, UTF-8), without encoding the '/' separator", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>9</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Odd filename</D:comment>
<S:modified-path node-kind="file">/trunk/my file (v2)&amp;more/caf&#233;.txt</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find(
            'href="/svn/demo1/trunk/my%20file%20%28v2%29%26more/caf%C3%A9.txt?p=9"', 1, true
        ))
    end)

    it("applies SVN_INDEX_QUERY_FILE only to file node-kind changed-path entries, never directories", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>20</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Mixed entry</D:comment>
<S:modified-path node-kind="file">/trunk/foo.txt</S:modified-path>
<S:added-path node-kind="dir">/trunk/newdir</S:added-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/", {
            SVN_INDEX_TEMPLATE = "wa-page",
            SVN_INDEX_QUERY_FILE = "view=details"
        })

        assert.truthy(html:find('href="/svn/demo1/trunk/foo.txt?p=20&amp;view=details"', 1, true))
        assert.truthy(html:find('href="/svn/demo1/trunk/newdir?p=20"', 1, true))
        assert.falsy(html:find('newdir?p=20&amp;view=details', 1, true))
    end)

    it("includes lang on wa-format-date only when SVN_LOG_DATE_LANG is set", function()
        local with_lang = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>1</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/", { SVN_INDEX_TEMPLATE = "wa-page", SVN_LOG_DATE_LANG = "sv" })

        assert.truthy(with_lang:find('lang="sv"></wa-format-date>', 1, true))

        local without_lang = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>1</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.falsy(without_lang:find(' lang="', 1, true))
        assert.truthy(without_lang:find('minute="numeric"></wa-format-date>', 1, true))
    end)

    it("appends a 'load more' sentinel when a batch comes back exactly full (rendered_count == the resolved limit)", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>10</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/", { SVN_INDEX_TEMPLATE = "wa-page", SVN_LOG_LIMIT = "1" })

        -- A full 1-item batch (== SVN_LOG_LIMIT) means older history may
        -- still exist -- the sentinel pins the next fetch one revision
        -- below the last one actually rendered, and marks itself as a
        -- continuation via "more=1" (see resolve_log_limit).
        assert.truthy(html:find('class="svn-log-more', 1, true))
        assert.truthy(html:find('hx-action="/svn/demo1/trunk/?p=9&amp;more=1"', 1, true))
    end)

    it("omits the sentinel when a batch comes back short of the resolved limit (log-report already reached end-revision=0 on its own)", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>10</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/", { SVN_INDEX_TEMPLATE = "wa-page", SVN_LOG_LIMIT = "5" })

        assert.falsy(html:find('svn-log-more', 1, true))
    end)

    it("omits the sentinel when the last rendered revision is already 0, even though the batch was otherwise full", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>0</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/", { SVN_INDEX_TEMPLATE = "wa-page", SVN_LOG_LIMIT = "1" })

        assert.falsy(html:find('svn-log-more', 1, true))
    end)

    it("echoes repo_root through into the sentinel's own more_href when present, omits it when absent", function()
        local with_repo_root = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>10</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/", { SVN_INDEX_TEMPLATE = "wa-page", SVN_LOG_LIMIT = "1" })

        assert.truthy(with_repo_root:find(
            'hx-action="/svn/demo1/trunk/?p=9&amp;more=1&amp;repo_root=/svn/demo1/"', 1, true
        ))

        local without_repo_root = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>10</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/", { SVN_INDEX_TEMPLATE = "wa-page", SVN_LOG_LIMIT = "1" })

        assert.falsy(without_repo_root:find('repo_root', 1, true))
    end)

    it("uses SVN_LOG_LIMIT_SCROLL (not SVN_LOG_LIMIT) as the resolved limit when rendering a continuation request's own response", function()
        -- Confirms output_filter's own resolve_log_limit call reads the
        -- same "more=1" flag input_filter does: a 2-item batch is "full"
        -- here (SVN_LOG_LIMIT_SCROLL=2), even though it's short of
        -- SVN_LOG_LIMIT=10 -- proving the sentinel decision used the
        -- scroll limit, not the plain one, for this ?more=1 request.
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>10</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
<S:log-item>
<D:version-name>9</D:version-name>
<D:creator-displayname>bob</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>y</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?more=1", { SVN_INDEX_TEMPLATE = "wa-page", SVN_LOG_LIMIT = "10", SVN_LOG_LIMIT_SCROLL = "2" })

        assert.truthy(html:find('hx-action="/svn/demo1/trunk/?p=8&amp;more=1"', 1, true))
    end)

    it("prefers \"log-item.custom.mustache\" over \"log-item.mustache\" when both exist (mirrors svn-index.lua's own override convention)", function()
        -- templates/test-custom-override/ ships both log-item.mustache
        -- (renders "DEFAULT:...") and log-item.custom.mustache (renders
        -- "CUSTOM:...") -- proving load_log_template_set's read_template()
        -- picks the override the same way svn-index.lua's does.
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>7</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/", { SVN_INDEX_TEMPLATE = "test-custom-override" })

        assert.truthy(html:find('<div class="log-item-custom">CUSTOM:7</div>', 1, true))
        assert.falsy(html:find("DEFAULT:", 1, true))
    end)

    it("marks a log-item log-item-own-change when the browsed folder's own path is in changed_paths", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>15</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Set property on trunk</D:comment>
<S:modified-path node-kind="dir">/trunk</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find('<wa-details class="log-item log-item-own-change">', 1, true))
    end)

    it("marks a log-item log-item-descendant-change, not log-item-own-change, when only a child path changed", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>16</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Edit a file under trunk</D:comment>
<S:modified-path node-kind="file">/trunk/foo.txt</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.falsy(html:find('log-item-own-change', 1, true))
        assert.truthy(html:find('<wa-details class="log-item log-item-descendant-change">', 1, true))
    end)

    it("applies both classes together when a single revision changes both the folder itself and a descendant", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>17</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Reprop trunk and add a file</D:comment>
<S:modified-path node-kind="dir">/trunk</S:modified-path>
<S:added-path node-kind="file">/trunk/new.txt</S:added-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find('<wa-details class="log-item log-item-own-change log-item-descendant-change">', 1, true))
    end)

    it("treats the repo root's own changed-path sentinel \"/\" as an own-change when browsing the repo root itself", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>1</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Initial repo creation</D:comment>
<S:added-path node-kind="dir">/</S:added-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/?repo_root=/svn/demo1/")

        assert.truthy(html:find('<wa-details class="log-item log-item-own-change">', 1, true))
    end)

    it("applies neither class when repo_root is absent, even for what would otherwise be an exact own-path match", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>18</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>No repo_root here</D:comment>
<S:modified-path node-kind="dir">/trunk</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.falsy(html:find('log-item-own-change', 1, true))
        assert.falsy(html:find('log-item-descendant-change', 1, true))
        assert.truthy(html:find('<wa-details class="log-item">', 1, true))
    end)

    it("compares own-change paths in percent-encoded space, matching a raw changed-path against an encoded browsed folder", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>19</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Reprop an oddly-named dir</D:comment>
<S:modified-path node-kind="dir">/my dir</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/my%20dir/?repo_root=/svn/demo1/")

        assert.truthy(html:find('<wa-details class="log-item log-item-own-change">', 1, true))
    end)

    it("applies neither class, without crashing, when repo_root isn't actually a prefix of the browsed folder's own URL", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>20</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Mismatched repo_root</D:comment>
<S:modified-path node-kind="dir">/trunk</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/?repo_root=/svn/otherrepo/")

        assert.falsy(html:find('log-item-own-change', 1, true))
        assert.falsy(html:find('log-item-descendant-change', 1, true))
    end)

    -- File targets: the per-file history icon and the "?history=" deep
    -- link (both built in svn-index.lua) fire a REPORT against a FILE's
    -- own URL, which never carries a trailing slash -- unlike every test
    -- above, all of which use a directory-shaped unparsed_uri. These
    -- confirm output_filter's own request_href is no longer force-slashed
    -- (see its own comment), so it doesn't corrupt the hrefs it builds.
    it("does not force a trailing slash onto a file target's own revision_href", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>42</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Edit file</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/file.txt?repo_root=/svn/demo1/")

        assert.truthy(html:find('href="/svn/demo1/trunk/file.txt?p=42"', 1, true))
        assert.falsy(html:find('file.txt/?p=42', 1, true))
    end)

    it("does not force a trailing slash into the 'load more' sentinel href for a file target", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>10</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/file.txt", { SVN_INDEX_TEMPLATE = "wa-page", SVN_LOG_LIMIT = "1" })

        assert.truthy(html:find('hx-action="/svn/demo1/trunk/file.txt?p=9&amp;more=1"', 1, true))
        assert.falsy(html:find('file.txt/?p=9', 1, true))
    end)

    it("still classifies own_change correctly for a file target without a trailing slash", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>15</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>Edit file itself</D:comment>
<S:modified-path node-kind="file">/trunk/file.txt</S:modified-path>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/file.txt?repo_root=/svn/demo1/")

        assert.truthy(html:find('<wa-details class="log-item log-item-own-change">', 1, true))
        assert.falsy(html:find('log-item-descendant-change', 1, true))
    end)

    it("marks the preamble svn-log-file for a file target, so page.mustache can hide the meaningless Folder-only toggle", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>10</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/file.txt")

        assert.truthy(html:find('<div class="svn-log svn-log-file">', 1, true))
    end)

    it("does not mark the preamble svn-log-file for a directory target", function()
        local html = run_output_filter({
            [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>10</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
</S:log-item>
</S:log-report>]]
        }, "/svn/demo1/trunk/")

        assert.truthy(html:find('<div class="svn-log">', 1, true))
        assert.falsy(html:find('svn-log-file', 1, true))
    end)
end)

-- One log entry, with whatever changed-path elements the test needs.
local function log_report_with(revision, changed_paths_xml)
    return [[<S:log-report xmlns:S="svn:" xmlns:D="DAV:">
<S:log-item>
<D:version-name>]] .. revision .. [[</D:version-name>
<D:creator-displayname>alice</D:creator-displayname>
<S:date>2024-01-01T00:00:00.000000Z</S:date>
<D:comment>x</D:comment>
]] .. changed_paths_xml .. [[
</S:log-item>
</S:log-report>]]
end

describe("svn-log output_filter diff links", function()
    it("links a modified file's diff, as a REPORT into #svn-diff-content", function()
        local html = run_output_filter({
            log_report_with(42, [[<S:modified-path node-kind="file" text-mods="true" prop-mods="false">/trunk/foo.txt</S:modified-path>]])
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find(
            '<a href="/svn/demo1/trunk/foo.txt?p=42">/trunk/foo.txt</a> <a class="changed-path-diff"'
                .. ' href="/svn/demo1/trunk/foo.txt?p=42&amp;diff=1&amp;repo_root=/svn/demo1/"'
                .. ' hx-action="/svn/demo1/trunk/foo.txt?p=42&amp;diff=1&amp;repo_root=/svn/demo1/"'
                .. ' hx-method="REPORT" hx-target="#svn-diff-content"',
            1, true
        ))
    end)

    it("links a property-only change, and a copy or rename that also changed the file", function()
        local html = run_output_filter({
            log_report_with(42, [[<S:modified-path node-kind="file" text-mods="false" prop-mods="true">/trunk/props.txt</S:modified-path>
<S:added-path copyfrom-path="/trunk/old.txt" copyfrom-rev="41" node-kind="file" text-mods="true" prop-mods="false">/trunk/renamed.txt</S:added-path>
<S:replaced-path copyfrom-path="/branches/b/x.txt" copyfrom-rev="40" node-kind="file" text-mods="false" prop-mods="true">/trunk/x.txt</S:replaced-path>]])
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find('href="/svn/demo1/trunk/props.txt?p=42&amp;diff=1', 1, true))
        assert.truthy(html:find('href="/svn/demo1/trunk/renamed.txt?p=42&amp;diff=1', 1, true))
        assert.truthy(html:find('href="/svn/demo1/trunk/x.txt?p=42&amp;diff=1', 1, true))
    end)

    it("offers no diff for a pure rename, a plain add, a deletion or a directory", function()
        local html = run_output_filter({
            log_report_with(42, [[<S:added-path copyfrom-path="/trunk/old.txt" copyfrom-rev="41" node-kind="file" text-mods="false" prop-mods="false">/trunk/renamed.txt</S:added-path>
<S:added-path node-kind="file" text-mods="true" prop-mods="false">/trunk/new.txt</S:added-path>
<S:deleted-path node-kind="file" text-mods="false" prop-mods="false">/trunk/old.txt</S:deleted-path>
<S:modified-path node-kind="dir" text-mods="false" prop-mods="true">/trunk/sub</S:modified-path>]])
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.falsy(html:find("changed-path-diff", 1, true))
    end)

    it("still links a modified file when the server sends no text-mods/prop-mods at all", function()
        local html = run_output_filter({
            log_report_with(42, [[<S:modified-path node-kind="file">/trunk/foo.txt</S:modified-path>]])
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find('href="/svn/demo1/trunk/foo.txt?p=42&amp;diff=1', 1, true))
    end)

    it("offers no diff without repo_root, like changed-path links themselves", function()
        local html = run_output_filter({
            log_report_with(42, [[<S:modified-path node-kind="file" text-mods="true" prop-mods="false">/trunk/foo.txt</S:modified-path>]])
        }, "/svn/demo1/trunk/")

        assert.falsy(html:find("changed-path-diff", 1, true))
    end)

    it("never adds SVN_INDEX_QUERY_FILE to the diff link, only to the path's own link", function()
        local html = run_output_filter({
            log_report_with(42, [[<S:modified-path node-kind="file" text-mods="true" prop-mods="false">/trunk/foo.txt</S:modified-path>]])
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/", {
            SVN_INDEX_TEMPLATE = "wa-page",
            SVN_INDEX_QUERY_FILE = "view=details"
        })

        assert.truthy(html:find('href="/svn/demo1/trunk/foo.txt?p=42&amp;view=details"', 1, true))
        assert.truthy(html:find('href="/svn/demo1/trunk/foo.txt?p=42&amp;diff=1&amp;repo_root=/svn/demo1/"', 1, true))
        assert.falsy(html:find('diff=1[^"]*view=details'))
    end)

    it("percent-encodes the diff link's path the same way as the path's own link", function()
        local html = run_output_filter({
            log_report_with(42, [[<S:modified-path node-kind="file" text-mods="true" prop-mods="false">/trunk/a b&amp;c.txt</S:modified-path>]])
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find('href="/svn/demo1/trunk/a%20b%26c.txt?p=42&amp;diff=1', 1, true))
    end)
end)

-- Captured from a real mod_dav_svn 1.14 server, like every response in
-- svn_diff_spec.lua (see its own header): readme.txt from r1 to r2.
local FILE_REVS_README_R2 = [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/readme.txt" rev="1">
<S:rev-prop name="svn:log">r1 initial</S:rev-prop>
<S:txdelta>U1ZOAAAAHQEdnWxpbmUgb25lCmxpbmUgdHdvCmxpbmUgdGhyZWUK</S:txdelta></S:file-rev>
<S:file-rev path="/trunk/readme.txt" rev="2">
<S:rev-prop name="svn:log">r2 text + prop</S:rev-prop>
<S:set-prop name="cms:status">draft</S:set-prop>
<S:txdelta>U1ZOAAAdLQMfDgCfMiBjaGFuZ2VkCmxpbmUgdGhyZWUKbGluZSBmb3VyCg==</S:txdelta></S:file-rev>
</S:file-revs-report>
]]

describe("svn-log output_filter diff rendering (?diff=1)", function()
    local DIFF_URI = "/svn/demo1/trunk/readme.txt?p=2&diff=1&repo_root=/svn/demo1/"

    it("renders diff.mustache: summary with links, property changes and content hunks", function()
        local html, r = run_output_filter({ FILE_REVS_README_R2:sub(1, 200), FILE_REVS_README_R2:sub(201) }, DIFF_URI)

        assert.are.equal("text/html; charset=utf-8", r.content_type)
        assert.is_nil(r.headers_out["Content-Length"])
        assert.is_nil(r.headers_out["ETag"])

        assert.truthy(html:find('<div class="svn-diff" data-label="readme.txt">', 1, true))
        -- One path (it's the same on both sides), then each side's own
        -- revision badge linking to that version, with its commit in a
        -- tooltip.
        local _, path_count = html:gsub("/trunk/readme.txt</a>", "")
        assert.are.equal(1, path_count)
        assert.truthy(html:find(
            '<span class="svn-diff-path"><a href="/svn/demo1/trunk/readme.txt?p=2">/trunk/readme.txt</a></span>\n'
                .. '<a id="svn-diff-old-revision" class="revision-badge wa-font-size-s" href="/svn/demo1/trunk/readme.txt?p=1">1</a>\n'
                .. '<wa-tooltip for="svn-diff-old-revision">r1<br><em>r1 initial</em></wa-tooltip>\n'
                .. '<wa-icon name="arrow-right" variant="solid" class="wa-color-text-quiet"></wa-icon>\n'
                .. '<a id="svn-diff-new-revision" class="revision-badge wa-font-size-s" href="/svn/demo1/trunk/readme.txt?p=2">2</a>\n'
                .. '<wa-tooltip for="svn-diff-new-revision">r2<br><em>r2 text + prop</em></wa-tooltip>',
            1, true
        ))
        assert.truthy(html:find('>+2</wa-badge>', 1, true))
        assert.truthy(html:find('>&minus;1</wa-badge>', 1, true))
        assert.truthy(html:find('<code>cms:status</code><span class="wa-color-text-quiet wa-font-size-s">property added</span>', 1, true))
        assert.truthy(html:find('<tr class="svn-diff-hunk"><td colspan="3">@@ -1,3 +1,4 @@</td></tr>', 1, true))
        assert.truthy(html:find(
            '<tr class="svn-diff-line svn-diff-removed"><td class="svn-diff-number">2</td><td class="svn-diff-number"></td><td class="svn-diff-code">line two</td></tr>',
            1, true
        ))
        assert.truthy(html:find(
            '<tr class="svn-diff-line svn-diff-added"><td class="svn-diff-number"></td><td class="svn-diff-number">2</td><td class="svn-diff-code">line 2 changed</td></tr>',
            1, true
        ))
        assert.truthy(html:find(
            '<tr class="svn-diff-line svn-diff-context"><td class="svn-diff-number">3</td><td class="svn-diff-number">3</td><td class="svn-diff-code">line three</td></tr>',
            1, true
        ))
        -- Every row was rendered through diff-line.mustache; no mustache
        -- tag is left over in the page.
        assert.falsy(html:find("{{", 1, true))
    end)

    it("adds SVN_INDEX_QUERY_FILE to the summary's own file links, like the History dialog's", function()
        local html = run_output_filter({ FILE_REVS_README_R2 }, DIFF_URI, {
            SVN_INDEX_TEMPLATE = "wa-page",
            SVN_INDEX_QUERY_FILE = "view=details"
        })

        assert.truthy(html:find('href="/svn/demo1/trunk/readme.txt?p=1&amp;view=details"', 1, true))
    end)

    it("shows both paths when the file was copied or renamed, and each commit's author and date in its tooltip", function()
        local html = run_output_filter({ [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/readme.txt" rev="2">
<S:rev-prop name="svn:author">alice</S:rev-prop>
<S:rev-prop name="svn:date">2026-10-29T23:35:08.786192Z</S:rev-prop>
<S:rev-prop name="svn:log">Edit</S:rev-prop>
<S:txdelta>U1ZOAAAALQEtrWxpbmUgb25lCmxpbmUgMiBjaGFuZ2VkCmxpbmUgdGhyZWUKbGluZSBmb3VyCg==</S:txdelta></S:file-rev>
<S:file-rev path="/branches/b1/readme.txt" rev="4">
<S:txdelta>U1ZOAAAtKgULCQCLFhdicmFuY2ggZWRpdA==</S:txdelta></S:file-rev>
</S:file-revs-report>
]] }, "/svn/demo1/branches/b1/readme.txt?p=4&diff=1&repo_root=/svn/demo1/", {
            SVN_INDEX_TEMPLATE = "wa-page",
            SVN_LOG_DATE_LANG = "sv"
        })

        assert.truthy(html:find('<span class="svn-diff-path"><a href="/svn/demo1/trunk/readme.txt?p=2">/trunk/readme.txt</a></span>', 1, true))
        assert.truthy(html:find('<span class="svn-diff-path"><a href="/svn/demo1/branches/b1/readme.txt?p=4">/branches/b1/readme.txt</a></span>', 1, true))
        assert.truthy(html:find(
            '<wa-tooltip for="svn-diff-old-revision">r2 &middot; alice &middot; <wa-format-date date="2026-10-29T23:35:08.786192Z"'
                .. ' month="numeric" day="numeric" year="numeric" hour="numeric" minute="numeric" lang="sv"></wa-format-date>'
                .. '<br><em>Edit</em></wa-tooltip>',
            1, true
        ))
        -- The new side's file-rev here carries no rev-props at all.
        assert.truthy(html:find('<wa-tooltip for="svn-diff-new-revision">r4</wa-tooltip>', 1, true))
    end)

    it("honors SVN_DIFF_MAX_BYTES", function()
        local html = run_output_filter({ FILE_REVS_README_R2 }, DIFF_URI, {
            SVN_INDEX_TEMPLATE = "wa-page",
            SVN_DIFF_MAX_BYTES = "16"
        })

        assert.truthy(html:find('Content larger than <wa-format-bytes value="16">', 1, true))
        assert.falsy(html:find("svn-diff-hunk", 1, true))
    end)

    it("renders mod_dav_svn's own error document as a message", function()
        local html = run_output_filter({ [[<?xml version="1.0" encoding="utf-8"?>
<D:error xmlns:D="DAV:" xmlns:m="http://apache.org/dav/xmlns" xmlns:C="svn:">
<C:error/>
<m:human-readable errcode="160013">
File not found: revision 2, path '/trunk/gone.txt'
</m:human-readable>
</D:error>
]] }, DIFF_URI)

        assert.truthy(html:find(
            '<wa-callout variant="danger" size="s"><wa-icon slot="icon" name="triangle-exclamation" variant="solid"></wa-icon>File not found: revision 2, path &#39;/trunk/gone.txt&#39;</wa-callout>',
            1, true
        ))
    end)

    it("logs and renders a parse error for a response cut short, still draining every bucket", function()
        local html, r = run_output_filter({ FILE_REVS_README_R2:sub(1, 300), "</S:wrong>", "more" }, DIFF_URI)
        local logged = false

        for _, entry in ipairs(r.logs) do
            if entry.level == "err" and entry.msg:find("SVN diff XML parse error", 1, true) then
                logged = true
            end
        end

        assert.is_true(logged)
        assert.truthy(html:find("Unexpected response from the server", 1, true))
    end)

    it("leaves the log branch alone for a template type without diff templates", function()
        -- test-custom-override ships no diff.mustache at all: History
        -- itself must keep working there, which it can only do if diff
        -- templates are loaded on a diff request alone.
        local html = run_output_filter({
            log_report_with(7, "")
        }, "/svn/demo1/trunk/", { SVN_INDEX_TEMPLATE = "test-custom-override" })

        assert.truthy(html:find('<div class="log-item-custom">CUSTOM:7</div>', 1, true))
    end)
end)
