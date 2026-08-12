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
        }, "/svn/demo1/trunk/?repo_root=/svn/demo1/")

        assert.truthy(html:find('<div class="svn-log">', 1, true))

        assert.truthy(html:find('<a class="revision-badge" href="/svn/demo1/trunk/?p=42">42</a>', 1, true))
        assert.truthy(html:find('<wa-icon name="user" variant="solid" style="font-size: 0.8rem;"></wa-icon> <strong>alice</strong>', 1, true))
        assert.truthy(html:find('date="2024-01-01T12:00:00.000000Z" month="numeric" day="numeric" year="numeric" hour="numeric" minute="numeric"></wa-format-date>', 1, true))
        assert.truthy(html:find('<em>Fix bug</em>', 1, true))
        assert.truthy(html:find('<div class="log-message-full wa-flank"><wa-icon name="comment" variant="solid" style="font-size: 0.8rem;"></wa-icon><em>Fix bug</em></div>', 1, true))
        assert.truthy(html:find('<wa-icon name="pen" variant="solid" style="font-size: 0.8rem;"></wa-icon><span><a href="/svn/demo1/trunk/foo.txt?p=42">/trunk/foo.txt</a></span>', 1, true))

        assert.truthy(html:find('<a class="revision-badge" href="/svn/demo1/trunk/?p=41">41</a>', 1, true))
        assert.truthy(html:find('<wa-icon name="plus" variant="solid" style="font-size: 0.8rem;"></wa-icon><span><a href="/svn/demo1/trunk/bar.txt?p=41">/trunk/bar.txt</a></span>', 1, true))
        assert.truthy(html:find('<wa-icon name="trash" variant="solid" style="font-size: 0.8rem;"></wa-icon><span><a href="/svn/demo1/trunk/old.txt?p=41">/trunk/old.txt</a></span>', 1, true))

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

        assert.truthy(html:find('<a class="revision-badge" href="/svn/demo1/trunk/?p=7">7</a>', 1, true))
        assert.truthy(html:find('<strong>carol</strong>', 1, true))
        assert.truthy(html:find('<em>Initial import</em>', 1, true))
        assert.truthy(html:find('<div class="log-message-full wa-flank"><wa-icon name="comment" variant="solid" style="font-size: 0.8rem;"></wa-icon><em>Initial import</em></div>', 1, true))
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

        assert.truthy(html:find('<div class="log-message-preview log-message-empty">', 1, true))
        assert.truthy(html:find('<div class="log-message-full log-message-empty wa-flank">', 1, true))
        assert.truthy(html:find('<div class="log-message-preview"><span>', 1, true))
        assert.truthy(html:find('<div class="log-message-full wa-flank">', 1, true))
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

        assert.truthy(html:find('<div class="log-message-preview log-message-empty">', 1, true))
        assert.truthy(html:find('<div class="log-message-full log-message-empty wa-flank">', 1, true))
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

        assert.truthy(html:find('<span class="copy-from">from <a href="/svn/demo1/trunk/old-name.txt?p=30">/trunk/old-name.txt</a> <span class="revision-badge revision-badge-small">30</span></span>', 1, true))
        assert.falsy(html:find('arrow-right', 1, true))
        assert.falsy(html:find('@30', 1, true))

        -- The sibling plain modified-path (no copyfrom attrs) must render
        -- as a complete <li>...</li> with NO copy-from span appended --
        -- this exact, closed string wouldn't match if one leaked in.
        assert.truthy(html:find(
            '<li class="action-m wa-flank"><wa-icon name="pen" variant="solid" style="font-size: 0.8rem;"></wa-icon><span><a href="/svn/demo1/trunk/unrelated.txt?p=50">/trunk/unrelated.txt</a></span></li>',
            1, true
        ))
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

        assert.truthy(html:find('<a class="revision-badge" href="/svn/demo1/trunk/?p=12">12</a>', 1, true))
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
end)
