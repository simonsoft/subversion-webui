local lxp = require "lxp"
local lustache = require "lustache"

-- Resolve the repo root next to this script, regardless of the current
-- working directory or the absolute path Apache was configured with
-- (LuaInputFilter/LuaOutputFilter both take an absolute path to this file).
local function script_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source and source:match("(.*[/\\])") or "./"
end

local function template_dir(template_type)
    return script_dir() .. "../templates/" .. template_type .. "/"
end

local DEFAULT_TEMPLATE_TYPE = "simple"
local SVNLOG_TAG = "{{{svn_log}}}"
local DEFAULT_LOG_LIMIT = 50

-- Only a request carrying both REPORT as the method *and* this query-string
-- marker is treated as this app's own History request -- see input_filter.
local HISTORY_MARKER = "history"

local function read_file(path)
    local file, err = io.open(path, "r")

    if not file then
        error("failed to open template file '" .. path .. "': " .. tostring(err))
    end

    local content = file:read("*a")
    file:close()

    return content
end

-- Duplicated from svn-index.lua: no require-able shared module exists in
-- this repo, and this is the only other file that needs it.
local function escape_html(value)
    value = tostring(value or "")

    return (value:gsub("&", "&amp;")
                 :gsub("<", "&lt;")
                 :gsub(">", "&gt;")
                 :gsub('"', "&quot;")
                 :gsub("'", "&#39;"))
end

-- Duplicated from svn-index.lua (see its own comment on why a decoded r.uri
-- isn't used here either -- request_href below is built from r.unparsed_uri
-- the same way).
local function url_path(url)
    local path = url:match("^%a[%w+.-]*://[^/]*(/.*)$") or url

    return path:match("^([^?#]*)")
end

-- Duplicated from svn-index.lua (see its own comment on why this hand-rolled
-- scan is used uniformly instead of r:parseargs()).
local function parse_query_param(str, key)
    if not str then
        return nil
    end

    local query = (str:match("%?(.*)$") or str):match("^([^#]*)")

    for pair in query:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=(.*)$")
        if k == key then
            return v
        end
    end

    return nil
end

-- limit/end-revision both originate from r.args, which is
-- attacker-controlled, and are concatenated directly into an XML request
-- body below (see build_log_report_body) -- they MUST be validated as plain
-- non-negative integers first. Returns the canonical decimal string form,
-- or nil if invalid/absent.
local function validate_nonneg_integer(str)
    if not str then
        return nil
    end

    local n = tonumber(str)

    if not n or n ~= math.floor(n) or n < 0 then
        return nil
    end

    return string.format("%d", n)
end

-- Builds the svn:log-report request body mod_dav_svn's REPORT handler
-- expects. Always exactly one empty <S:path></S:path> -- meaning "the
-- resource identified by the request URI itself" -- since this app never
-- asks for the log of any path other than the directory currently being
-- browsed. discover-changed-paths is always requested (locked-in scope
-- decision: each log entry lists its added/modified/deleted paths).
--
-- start-revision is ALWAYS set, to "0" (the repository's own oldest
-- possible revision) -- confirmed against a real server that omitting it
-- does NOT mean "as far back as it goes": it defaults to HEAD, exactly
-- like end-revision's own default. Omitting both therefore asks for the
-- log between HEAD and HEAD -- a one-revision window -- which is why an
-- unpinned History click was only ever showing a row when the browsed
-- path happened to be touched by the single most recent commit, and
-- nothing otherwise. end_revision is nil unless the request was pinned via
-- "?p=REV" -- honored as the upper/peg bound; omitted entirely means HEAD,
-- which (now that start-revision is always explicit) is the intended
-- "walk from HEAD back to revision 0" range.
local function build_log_report_body(limit, end_revision)
    local parts = {
        '<S:log-report xmlns:S="svn:" xmlns:D="DAV:">',
        '<S:start-revision>0</S:start-revision>',
        '<S:limit>' .. limit .. '</S:limit>',
    }

    if end_revision then
        parts[#parts + 1] = '<S:end-revision>' .. end_revision .. '</S:end-revision>'
    end

    parts[#parts + 1] = '<S:discover-changed-paths/>'
    parts[#parts + 1] = '<S:path></S:path>'
    parts[#parts + 1] = '</S:log-report>'

    return table.concat(parts)
end

-- SetInputFilter (unlike LuaOutputFilter's FilterProvider) has no
-- per-request condition mechanism -- it runs on every request under the
-- Location this is wired into, including real svn-client REPORT traffic
-- (update-report, file-revs-report, etc.) against the exact same URL space.
-- The "history=1" marker (added only by this app's own History link, see
-- page.mustache) is what distinguishes this app's own synthetic REPORT
-- requests from everything else; r.method alone is not sufficient. A bare
-- early return, before ever touching bucket/coroutine.yield, is mod_lua's
-- own documented idiom for an input filter that should pass the original
-- content through unmodified.
function input_filter(r)
    if r.method ~= "REPORT" or parse_query_param(r.args, HISTORY_MARKER) ~= "1" then
        return
    end

    -- LuaInputFilter's first yield is a bare, argument-less handshake --
    -- confirmed against mod_lua's own docs -- distinct from
    -- LuaOutputFilter's own yield("") convention (see svn-index.lua).
    coroutine.yield()

    -- Drain and discard the client's own request body (htmx's hx-action
    -- issues the REPORT with no body; even if a body were attached, it's
    -- irrelevant here -- the real body is always fully synthesized below,
    -- from server-side state only).
    while bucket do
        coroutine.yield()
    end

    local limit = validate_nonneg_integer(
        r.subprocess_env and r.subprocess_env.SVN_LOG_LIMIT
    ) or tostring(DEFAULT_LOG_LIMIT)

    local end_revision = validate_nonneg_integer(parse_query_param(r.args, "p"))

    local body = build_log_report_body(limit, end_revision)

    -- Belt-and-braces only, not load-bearing: confirmed against httpd's own
    -- source that the REPORT body is actually read by the same core
    -- ap_xml_parse_input() PROPFIND/PROPPATCH/OPTIONS use (server/util_xml.c)
    -- -- it reads via ap_get_brigade(r->input_filters, ...) until it sees an
    -- EOS bucket, checking neither Content-Type nor Content-Length (the only
    -- cap is LimitXMLRequestBody). So mod_dav_svn's REPORT handler already
    -- sees exactly the synthesized body this filter yields, regardless of
    -- what's set here. Kept anyway in case dav_method_report itself ever
    -- deviates from that shared path on some server version.
    r.headers_in["Content-Length"] = tostring(#body)
    r.headers_in["Content-Type"] = "text/xml; charset=utf-8"

    coroutine.yield(body)
end

-- ---------------------------------------------------------------------
-- output_filter: renders mod_dav_svn's <S:log-report> response XML as a
-- basic HTML log table.
-- ---------------------------------------------------------------------

-- Direct, non-nested children of <S:log-item> that carry text content.
-- Element names arrive with their literal "S:"/"D:" prefixes, the same
-- unconfigured way lxp.new is already used in svn-index.lua (no
-- namespace-processing mode).
local TEXT_FIELDS = {
    ["D:version-name"] = "revision",
    ["D:creator-displayname"] = "author",
    ["S:date"] = "date",
    ["D:comment"] = "message"
}

local CHANGED_PATH_ACTIONS = {
    ["S:added-path"] = "A",
    ["S:modified-path"] = "M",
    ["S:deleted-path"] = "D",
    ["S:replaced-path"] = "R"
}

-- Cache of already-loaded template sets, keyed by template type -- mirrors
-- svn-index.lua's own load_template_set caching rationale.
local log_template_cache = {}

local function load_log_template_set(template_type)
    local cached = log_template_cache[template_type]

    if cached then
        return cached
    end

    if not template_type:match("^[%w%-]+$") then
        error("invalid template type '" .. tostring(template_type) .. "'")
    end

    local dir = template_dir(template_type)
    local raw = read_file(dir .. "log.mustache")
    local marker_start, marker_end = raw:find(SVNLOG_TAG, 1, true)

    if not marker_start then
        error("template '" .. template_type .. "/log.mustache' is missing the required '"
              .. SVNLOG_TAG .. "' placeholder")
    end

    local set = {
        preamble = raw:sub(1, marker_start - 1),
        postamble = raw:sub(marker_end + 1),
        item = read_file(dir .. "log-item.mustache")
    }

    log_template_cache[template_type] = set

    return set
end

local function render_log_item(templates, item)
    local changed_paths = {}

    for _, cp in ipairs(item.changed_paths) do
        changed_paths[#changed_paths + 1] = {
            action = cp.action,
            action_class = cp.action:lower(),
            path = escape_html(cp.path)
        }
    end

    return lustache:render(templates.item, {
        revision = escape_html(item.revision),
        author = escape_html(item.author),
        date = escape_html(item.date),
        message = escape_html(item.message),
        changed_paths = changed_paths
    })
end

function output_filter(r)
    local bucket_count = 0
    local element_count = 0
    local rendered_count = 0
    local pending_output = {}

    -- Reuses SVN_INDEX_TEMPLATE (not a separate env var): the History link
    -- only exists in wa-page's own page.mustache, so this filter only ever
    -- needs to resolve wa-page's own log.mustache/log-item.mustache -- but
    -- reads the same env var svn-index.lua uses, for consistency, rather
    -- than inventing a second template-selection knob.
    local template_type = (r.subprocess_env and r.subprocess_env.SVN_INDEX_TEMPLATE) or ""

    if template_type == "" then
        template_type = DEFAULT_TEMPLATE_TYPE
    end

    local templates = load_log_template_set(template_type)

    -- Same request_href convention as svn-index.lua: built from
    -- r.unparsed_uri (still percent-encoded), not the decoded r.uri.
    local request_href = url_path(tostring(r.unparsed_uri or r.uri or ""))

    if request_href ~= "" and not request_href:match("/$") then
        request_href = request_href .. "/"
    end

    local revision_pinned = parse_query_param(r.args, "p")
    local revision_suffix = revision_pinned and ("?p=" .. revision_pinned) or ""
    local listing_href = escape_html(request_href .. revision_suffix)

    local preamble_html = lustache:render(templates.preamble, { listing_href = listing_href })
    local postamble_html = templates.postamble
    local preamble_sent = false

    -- Set these before emitting any transformed response content.
    r.content_type = "text/html; charset=utf-8"

    -- The transformed body has a different length, and there's no stable
    -- revision-scoped identity for a log fragment to key an ETag off (unlike
    -- the directory listing's own W/"{rev}-lua") -- simplest to not set one.
    r.headers_out["Content-Length"] = nil
    r.headers_out["ETag"] = nil

    r:info(string.format(
        "SVN log filter entered: method=%s uri=%s content-type=%s template=%s",
        tostring(r.method),
        tostring(r.uri),
        tostring(r.content_type),
        template_type
    ))

    local item = nil
    local capture_target, capture_field, capture_buffer = nil, nil, nil

    -- No element stack is needed for capture_target/capture_field/
    -- capture_buffer: per the verified svn log-report schema, every
    -- text-bearing element (D:version-name, D:creator-displayname, S:date,
    -- D:comment, and the four *-path elements) is a direct, non-nested
    -- child of <S:log-item> -- a single flat "current capture" tracker is
    -- sufficient.
    local parser = lxp.new({
        StartElement = function(_, name, attr)
            element_count = element_count + 1

            r:debug(string.format(
                "SVN log XML element #%d: name=%s",
                element_count,
                tostring(name)
            ))

            if name == "S:log-item" then
                item = { revision = "", author = "", date = "", message = "", changed_paths = {} }
                return
            end

            if item and TEXT_FIELDS[name] then
                capture_target, capture_field, capture_buffer = item, TEXT_FIELDS[name], ""
                return
            end

            if item and CHANGED_PATH_ACTIONS[name] then
                local entry = { action = CHANGED_PATH_ACTIONS[name], path = "" }
                item.changed_paths[#item.changed_paths + 1] = entry
                capture_target, capture_field, capture_buffer = entry, "path", ""
            end

            -- Any other element (S:log-report root, S:has-children,
            -- S:subtractive-merge, S:revprop, ...) is silently ignored --
            -- deliberately not an error, since these are valid parts of the
            -- schema this filter simply doesn't render.
        end,

        CharacterData = function(_, text)
            if capture_target then
                capture_buffer = capture_buffer .. text
            end
        end,

        EndElement = function(_, name)
            if capture_target and (TEXT_FIELDS[name] or CHANGED_PATH_ACTIONS[name]) then
                capture_target[capture_field] = capture_buffer
                capture_target, capture_field, capture_buffer = nil, nil, nil
                return
            end

            if name == "S:log-item" and item then
                rendered_count = rendered_count + 1
                pending_output[#pending_output + 1] = render_log_item(templates, item)
                item = nil
            end
        end
    })

    if not parser then
        r:err("Failed to create LuaExpat parser")
        return
    end

    -- lxp's own parser:close() can itself raise a Lua error (not just
    -- return ok=false like parser:parse() does) when the document was left
    -- malformed/unclosed -- e.g. a mismatched end tag isn't always caught
    -- by the parse() call that reads it; expat can defer that particular
    -- well-formedness check to close(). pcall here keeps that from ever
    -- crashing the coroutine outright, consistent with this filter's own
    -- policy of always failing gracefully (log via r:err, then return).
    local function safe_close()
        local ok, err = pcall(function() parser:close() end)

        if not ok then
            r:err("SVN log XML parser close error: " .. tostring(err))
        end
    end

    -- mod_lua only fetches the first input chunk into `bucket` after the
    -- coroutine yields once; without this, `bucket` is still nil on the
    -- very first pass and the loop below never runs at all.
    coroutine.yield("")

    while bucket do
        bucket_count = bucket_count + 1
        pending_output = {}

        r:debug(string.format(
            "SVN log XML bucket #%d: %d bytes",
            bucket_count,
            #bucket
        ))

        local ok, err, line, column = parser:parse(bucket)

        if not ok then
            r:err(string.format(
                "SVN log XML parse error in bucket #%d at line %s, column %s: %s",
                bucket_count,
                tostring(line),
                tostring(column),
                tostring(err)
            ))

            safe_close()
            return
        end

        local output_parts = {}

        if not preamble_sent then
            output_parts[#output_parts + 1] = preamble_html
            preamble_sent = true
        end

        output_parts[#output_parts + 1] = table.concat(pending_output)

        coroutine.yield(table.concat(output_parts))
    end

    pending_output = {}

    local ok, err, line, column = parser:parse()

    if not ok then
        r:err(string.format(
            "SVN log XML finalization error at line %s, column %s: %s",
            tostring(line),
            tostring(column),
            tostring(err)
        ))

        safe_close()
        return
    end

    safe_close()

    local final_parts = {}

    -- Defensive fallback: an empty or malformed response body would
    -- otherwise never get a preamble at all.
    if not preamble_sent then
        final_parts[#final_parts + 1] = preamble_html
        preamble_sent = true
    end

    -- If the very last <S:log-item>'s </S:log-item> is only recognized by
    -- this final, no-argument parser:parse() call (rather than during the
    -- while-loop's own last parser:parse(bucket) call) -- which real-world
    -- bucket boundaries can trigger even though every hand-crafted split in
    -- this file's own test fixtures happens not to -- its rendered row was
    -- appended to pending_output here and must still be flushed; omitting
    -- it silently drops that row.
    final_parts[#final_parts + 1] = table.concat(pending_output)

    final_parts[#final_parts + 1] = postamble_html

    coroutine.yield(table.concat(final_parts))

    r:info(string.format(
        "SVN log listing transformed: buckets=%d elements=%d entries=%d",
        bucket_count,
        element_count,
        rendered_count
    ))
end
