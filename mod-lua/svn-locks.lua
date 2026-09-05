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

local function read_file(path)
    local file, err = io.open(path, "r")

    if not file then
        error("failed to open template file '" .. path .. "': " .. tostring(err))
    end

    local content = file:read("*a")
    file:close()

    return content
end

-- Duplicated from svn-index.lua/svn-log.lua (see their own comments for the
-- rationale): loads "<name>.mustache" unless a "<name>.custom.mustache" sits
-- alongside it in the same template type's directory.
local function read_template(dir, name)
    local custom_path = dir .. name .. ".custom.mustache"
    local custom_file = io.open(custom_path, "r")

    if custom_file then
        custom_file:close()
        return read_file(custom_path)
    end

    return read_file(dir .. name .. ".mustache")
end

-- Duplicated from svn-index.lua/svn-log.lua: no require-able shared module
-- exists in this repo.
local function escape_html(value)
    value = tostring(value or "")

    return (value:gsub("&", "&amp;")
                 :gsub("<", "&lt;")
                 :gsub(">", "&gt;")
                 :gsub('"', "&quot;")
                 :gsub("'", "&#39;"))
end

-- Duplicated from svn-index.lua/svn-log.lua: percent-encodes byte-for-byte
-- (unreserved set plus "/" kept literal). Used here to turn a lock's own
-- <S:path> (a raw, repo-absolute, non-percent-encoded path -- mod_dav_svn's
-- log-report emits changed-paths the same raw way, per svn-log.lua's own
-- comment) into the SAME id svn-index.lua's path_id already computes for
-- that file's listing row, so this filter's own OOB-swap fragments can
-- target it by id. No directory-prefix concatenation needed here (unlike
-- svn-index.lua's build_path_id): get-locks-report's own <S:path> is
-- already the complete repo-absolute path, not a bare child name.
local function percent_encode_path(path)
    return (tostring(path or ""):gsub("[^%w%-%._~/]", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

-- Duplicated from svn-log.lua (see its own comment for the full rationale):
-- a REPORT is only ever treated as this app's own synthetic traffic when its
-- Content-Type is *exactly* form-encoded -- an allow-list, not a deny-list,
-- so any other client (a real svn client's own REPORT traffic included)
-- passes through untouched by default.
local function is_form_encoded_content_type(content_type)
    if not content_type then
        return false
    end

    return content_type:lower():match("^application/x%-www%-form%-urlencoded") ~= nil
end

-- get-locks-report always asks about "the resource identified by the
-- request URI itself" (an empty <S:path>, the same convention
-- svn-log.lua's own build_log_report_body uses for log-report), at
-- "immediates" depth -- the browsed directory plus its own immediate
-- children, matching what a single directory listing shows (one level,
-- like "svn list"). Unlike log-report, get-locks-report has no revision
-- concept to pin -- locks are inherently a live/HEAD-only notion.
--
-- NOT independently verified against a live mod_dav_svn server in this
-- session (unlike svn-log.lua's own log-report body, whose comments note
-- it WAS confirmed that way) -- this mirrors the documented SVN DeltaV
-- get-locks-report request shape. Verify against a real server before
-- relying on this in production.
local function build_get_locks_report_body()
    return '<S:get-locks-report xmlns:S="svn:" xmlns:D="DAV:">'
        .. '<S:path></S:path>'
        .. '<S:depth>immediates</S:depth>'
        .. '</S:get-locks-report>'
end

-- ---------------------------------------------------------------------
-- input_filter: synthesizes the get-locks-report request body.
-- ---------------------------------------------------------------------

-- SetInputFilter (see svn-log.lua's own comment) has no per-request
-- condition mechanism -- it runs on every request under the Location this
-- is wired into, INCLUDING svn-log.lua's own SVN_LOG_REPORT_BODY filter's
-- traffic if both are chained onto the same Location (as README.md's
-- config does): a plain "REPORT + form-encoded" check alone can't tell
-- this filter's own traffic apart from svn-log.lua's. The triggering
-- element sends an "HX-Svn-Report: locks" header (see page.mustache's own
-- fetchLocks()) that svn-log.lua's own input_filter has been taught to
-- treat as "not mine" (see its own gate) -- this filter's gate is the
-- mirror image: only ever "mine" when that header is *exactly* "locks",
-- an allow-list matching is_form_encoded_content_type's own philosophy.
function input_filter(r)
    local content_type = r.headers_in and r.headers_in["Content-Type"]
    local report_kind = r.headers_in and r.headers_in["HX-Svn-Report"]

    if r.method ~= "REPORT" or not is_form_encoded_content_type(content_type) or report_kind ~= "locks" then
        return
    end

    -- LuaInputFilter's first yield is a bare, argument-less handshake --
    -- see svn-log.lua's own comment on this same convention.
    coroutine.yield()

    -- Drain and discard the client's own request body (fetchLocks() issues
    -- the REPORT with no body).
    while bucket do
        coroutine.yield()
    end

    local body = build_get_locks_report_body()

    r.headers_in["Content-Length"] = tostring(#body)
    r.headers_in["Content-Type"] = "text/xml; charset=utf-8"

    coroutine.yield(body)
end

-- ---------------------------------------------------------------------
-- output_filter: renders mod_dav_svn's <S:get-locks-report> response XML
-- as a sequence of htmx out-of-band lock-badge swaps, one per lock -- no
-- wrapping shell (unlike svn-index.lua/svn-log.lua's preamble/postamble):
-- the response is consumed purely for its OOB side effects
-- (hx-swap="none" on the triggering element), so an empty response (no
-- locks) is a perfectly valid, if unremarkable, body.
-- ---------------------------------------------------------------------

-- Direct, non-nested children of <S:lock> that carry text content. Element
-- names arrive with their literal "S:" prefix, the same unconfigured way
-- lxp.new is already used in svn-index.lua/svn-log.lua (no
-- namespace-processing mode).
--
-- NOT independently verified against a live mod_dav_svn server in this
-- session -- see build_get_locks_report_body's own caveat above; this
-- mirrors the documented get-locks-report response shape (svn_lock_t's own
-- fields: path, owner, comment, creation date -- token/expiration omitted,
-- not needed for display).
local LOCK_TEXT_FIELDS = {
    ["S:path"] = "path",
    ["S:owner"] = "owner",
    ["S:comment"] = "comment",
    ["S:created"] = "created"
}

-- Cache of already-loaded lock-badge templates, keyed by template type --
-- mirrors svn-index.lua/svn-log.lua's own template-set caching rationale.
local lock_badge_template_cache = {}

local function load_lock_badge_template(template_type)
    local cached = lock_badge_template_cache[template_type]

    if cached then
        return cached
    end

    if not template_type:match("^[%w%-]+$") then
        error("invalid template type '" .. tostring(template_type) .. "'")
    end

    local dir = template_dir(template_type)
    local badge = read_template(dir, "lock-badge")

    lock_badge_template_cache[template_type] = badge

    return badge
end

local function render_lock_badge(template, item)
    return lustache:render(template, {
        path_id = percent_encode_path(item.path),
        owner = escape_html(item.owner),
        created = escape_html(item.created),
        -- nil (not "") when blank -- same convention svn-log.lua's own
        -- render_log_item already uses for "message", so lock-badge.mustache
        -- can key "{{#comment}}" directly off this field.
        comment = (item.comment:match("^%s*$") == nil) and escape_html(item.comment) or nil
    })
end

function output_filter(r)
    local bucket_count = 0
    local element_count = 0
    local rendered_count = 0
    local pending_output = {}

    -- Reuses SVN_INDEX_TEMPLATE (not a separate env var), same reasoning as
    -- svn-log.lua's own output_filter: the lock-badge trigger only exists in
    -- wa-page's own page.mustache, so this filter only ever needs to resolve
    -- wa-page's own lock-badge.mustache.
    local template_type = (r.subprocess_env and r.subprocess_env.SVN_INDEX_TEMPLATE) or ""

    if template_type == "" then
        template_type = DEFAULT_TEMPLATE_TYPE
    end

    local badge_template = load_lock_badge_template(template_type)

    -- Set these before emitting any transformed response content.
    r.content_type = "text/html; charset=utf-8"
    r.headers_out["Content-Length"] = nil
    r.headers_out["ETag"] = nil

    r:info(string.format(
        "SVN locks filter entered: method=%s uri=%s content-type=%s template=%s",
        tostring(r.method),
        tostring(r.uri),
        tostring(r.content_type),
        template_type
    ))

    local item = nil
    local capture_field, capture_buffer = nil, nil

    -- No element stack needed for capture_field/capture_buffer: per
    -- LOCK_TEXT_FIELDS' own assumption, every text-bearing element is a
    -- direct, non-nested child of <S:lock> -- a single flat "current
    -- capture" tracker is sufficient (mirrors svn-log.lua's own
    -- TEXT_FIELDS handling).
    local parser = lxp.new({
        StartElement = function(_, name)
            element_count = element_count + 1

            r:debug(string.format(
                "SVN locks XML element #%d: name=%s",
                element_count,
                tostring(name)
            ))

            if name == "S:lock" then
                item = { path = "", owner = "", comment = "", created = "" }
                return
            end

            if item and LOCK_TEXT_FIELDS[name] then
                capture_field, capture_buffer = LOCK_TEXT_FIELDS[name], ""
            end

            -- Any other element (S:get-locks-report root, S:token,
            -- S:expires, ...) is silently ignored -- deliberately not an
            -- error, since these are valid parts of the schema this filter
            -- simply doesn't render.
        end,

        CharacterData = function(_, text)
            if capture_field then
                capture_buffer = capture_buffer .. text
            end
        end,

        EndElement = function(_, name)
            if capture_field and LOCK_TEXT_FIELDS[name] then
                item[LOCK_TEXT_FIELDS[name]] = capture_buffer
                capture_field, capture_buffer = nil, nil
                return
            end

            if name == "S:lock" and item then
                rendered_count = rendered_count + 1
                pending_output[#pending_output + 1] = render_lock_badge(badge_template, item)
                item = nil
            end
        end
    })

    if not parser then
        r:err("Failed to create LuaExpat parser")
        return
    end

    -- lxp's own parser:close() can itself raise a Lua error -- see
    -- svn-log.lua's own safe_close comment for the full rationale.
    local function safe_close()
        local ok, err = pcall(function() parser:close() end)

        if not ok then
            r:err("SVN locks XML parser close error: " .. tostring(err))
        end
    end

    -- mod_lua only fetches the first input chunk into `bucket` after the
    -- coroutine yields once -- see svn-index.lua/svn-log.lua's own comment
    -- on this same convention.
    coroutine.yield("")

    while bucket do
        bucket_count = bucket_count + 1
        pending_output = {}

        r:debug(string.format(
            "SVN locks XML bucket #%d: %d bytes",
            bucket_count,
            #bucket
        ))

        local ok, err, line, column = parser:parse(bucket)

        if not ok then
            r:err(string.format(
                "SVN locks XML parse error in bucket #%d at line %s, column %s: %s",
                bucket_count,
                tostring(line),
                tostring(column),
                tostring(err)
            ))

            safe_close()
            return
        end

        coroutine.yield(table.concat(pending_output))
    end

    pending_output = {}

    local ok, err, line, column = parser:parse()

    if not ok then
        r:err(string.format(
            "SVN locks XML finalization error at line %s, column %s: %s",
            tostring(line),
            tostring(column),
            tostring(err)
        ))

        safe_close()
        return
    end

    safe_close()

    coroutine.yield(table.concat(pending_output))

    r:info(string.format(
        "SVN locks transformed: buckets=%d elements=%d locks=%d",
        bucket_count,
        element_count,
        rendered_count
    ))
end
