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

local function read_file(path)
    local file, err = io.open(path, "r")

    if not file then
        error("failed to open template file '" .. path .. "': " .. tostring(err))
    end

    local content = file:read("*a")
    file:close()

    return content
end

-- Duplicated from svn-index.lua (see its own comment for the rationale):
-- loads "<name>.mustache" unless a "<name>.custom.mustache" sits alongside
-- it in the same template type's directory.
local function read_template(dir, name)
    local custom_path = dir .. name .. ".custom.mustache"
    local custom_file = io.open(custom_path, "r")

    if custom_file then
        custom_file:close()
        return read_file(custom_path)
    end

    return read_file(dir .. name .. ".mustache")
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

-- Duplicated from svn-index.lua (no shared module exists in this repo).
-- Merges an extra literal query-string fragment onto an href that may or
-- may not already have its own query.
local function append_query(href, extra_query)
    if not extra_query or extra_query == "" then
        return href
    end

    return href .. (href:find("?", 1, true) and "&" or "?") .. extra_query
end

-- Duplicated from svn-index.lua: request_href built from r.unparsed_uri
-- (still percent-encoded), not the decoded r.uri -- needed here for the
-- revision-badge link (see render_log_item's "revision_href").
local function url_path(url)
    local path = url:match("^%a[%w+.-]*://[^/]*(/.*)$") or url

    return path:match("^([^?#]*)")
end

-- mod_dav_svn's log-report emits changed-path text as raw,
-- NON-percent-encoded repo-root-relative paths -- unlike svn-index.lua's
-- directory-listing XML, whose href attributes ARE already
-- percent-encoded by mod_dav_svn itself. Nothing in this app currently
-- percent-encodes anything; this is the first such helper.
--
-- Byte-by-byte encoding is safe for UTF-8: every byte of a multi-byte
-- sequence is >0x7F, so each independently falls outside the allowed set
-- and gets escaped -- the resulting %XX%XX..., read back together, is the
-- correct encoding of the whole character. "/" is kept unencoded (a path
-- separator, not data), alongside RFC 3986's unreserved set.
local function percent_encode_path(path)
    return (tostring(path or ""):gsub("[^%w%-%._~/]", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
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

-- SVN_LOG_LIMIT_SCROLL governs each continuous-scroll ("load more") batch's
-- own size, independent of SVN_LOG_LIMIT (which governs only the initial
-- batch shown when History is first opened) -- lets an admin allow a much
-- bigger page size once a user is actively scrolling for more history,
-- without raising the cost of the synchronous initial fetch every History
-- click pays. Falls back to SVN_LOG_LIMIT's own resolution (default 50)
-- when unset/invalid, or when more_flag is false (a plain, non-continuation
-- request never consults SVN_LOG_LIMIT_SCROLL at all, even if it happens to
-- be set) -- so today's uniform single-limit behavior is what an
-- unconfigured server still gets. Shared by both filters (defined in this
-- one file, so no cross-file duplication is needed the way
-- svn-index.lua/svn-log.lua duplicate helpers between each other):
-- input_filter uses it to build <S:limit>, output_filter uses it to know
-- what ceiling this request's own response was actually bounded by (see
-- the "load more" sentinel decision in output_filter).
local function resolve_log_limit(env, more_flag)
    if more_flag then
        local scroll_limit = validate_nonneg_integer(env and env.SVN_LOG_LIMIT_SCROLL)
        if scroll_limit then
            return scroll_limit
        end
    end

    return validate_nonneg_integer(env and env.SVN_LOG_LIMIT) or tostring(DEFAULT_LOG_LIMIT)
end

-- Deliberately an allow-list, not a deny-list ("is this definitely NOT
-- svn-client traffic"): only a REPORT whose Content-Type is *exactly*
-- form-encoded is ever treated as this app's own -- everything else
-- (including a real svn client that, for whatever reason, fails to declare
-- "text/xml" the way libsvn_ra_serf/log.c's handler->body_type = "text/xml"
-- normally guarantees, or any other unexpected/absent Content-Type) passes
-- through untouched by default. This is strictly safer than gating on "not
-- XML": that would have silently intercepted (and replaced the body of)
-- any REPORT whose Content-Type was merely absent or unrecognized, not
-- just this app's own actual traffic.
--
-- "Form-encoded" here means htmx v4's own default Content-Type for a
-- request like the History link's own (hx-action/hx-method="REPORT", no
-- hx-vals/form ancestor to serialize): confirmed to be
-- "application/x-www-form-urlencoded;charset=UTF-8" -- the History link
-- itself sets nothing explicit (see page.mustache), it just relies on that
-- default. A bare prefix match here, not a full media-type parser, since
-- that trailing charset parameter is expected, not incidental.
local function is_form_encoded_content_type(content_type)
    if not content_type then
        return false
    end

    return content_type:lower():match("^application/x%-www%-form%-urlencoded") ~= nil
end

-- Builds the svn:log-report request body mod_dav_svn's REPORT handler
-- expects. Always exactly one empty <S:path></S:path> -- meaning "the
-- resource identified by the request URI itself" -- since this app never
-- asks for the log of any path other than the directory currently being
-- browsed. discover-changed-paths is always requested (locked-in scope
-- decision: each log entry lists its added/modified/deleted paths).
--
-- Order/direction: log-report walks from start-revision to end-revision,
-- returning results in THAT order -- start > end walks backward (newest
-- first), start < end walks forward (oldest first); same convention
-- "svn log -r HEAD:0" vs "-r 0:HEAD" uses. We want newest first (what
-- every log viewer, including svn's own, defaults to), so the peg
-- (peg_revision -- HEAD, or the "?p=REV" pin) goes into start-revision,
-- and end-revision is ALWAYS explicit "0" (confirmed against a real
-- server that omitting it defaults to HEAD, exactly like start-revision's
-- own default -- omitting both would ask for the log between HEAD and
-- HEAD, a one-revision window, which is why an earlier version of this
-- only ever showed a row when the browsed path happened to be touched by
-- the single most recent commit).
--
-- This also matters for repos with more history than `limit`: walking
-- backward from HEAD lets mod_dav_svn stop as soon as `limit` entries are
-- emitted (bounded work regardless of total revision count, the same
-- traversal direction "svn log" itself defaults to) -- getting this
-- backward would instead return the OLDEST `limit` revisions, not the
-- most recent ones, for any repo with more history than that.
-- peg_revision is nil unless the request was pinned via "?p=REV" --
-- omitted entirely means HEAD.
local function build_log_report_body(limit, peg_revision)
    local parts = {
        '<S:log-report xmlns:S="svn:" xmlns:D="DAV:">',
    }

    if peg_revision then
        parts[#parts + 1] = '<S:start-revision>' .. peg_revision .. '</S:start-revision>'
    end

    parts[#parts + 1] = '<S:end-revision>0</S:end-revision>'
    parts[#parts + 1] = '<S:limit>' .. limit .. '</S:limit>'
    parts[#parts + 1] = '<S:discover-changed-paths/>'
    parts[#parts + 1] = '<S:path></S:path>'
    parts[#parts + 1] = '</S:log-report>'

    return table.concat(parts)
end

-- SetInputFilter (unlike LuaOutputFilter's FilterProvider) has no
-- per-request condition mechanism -- it runs on every request under the
-- Location this is wired into, including real svn-client REPORT traffic
-- (update-report, file-revs-report, etc.) against the exact same URL space.
-- A REPORT request whose declared Content-Type is *exactly* form-encoded
-- (see is_form_encoded_content_type above) is what distinguishes this
-- app's own synthetic REPORT requests from everything else; r.method alone
-- is not sufficient. A bare early return, before ever touching
-- bucket/coroutine.yield, is mod_lua's own documented idiom for an input
-- filter that should pass the original content through unmodified.
--
-- "HX-Svn-Report: locks" (see svn-locks.lua) marks a REPORT explicitly as
-- someone else's synthetic traffic sharing this same Location/gate -- both
-- filters' SetInputFilter directives run unconditionally on every request
-- here (chain order is irrelevant either way, since only one of the two
-- ever positively claims a given request): this filter claims anything
-- form-encoded EXCEPT that marker, svn-locks.lua's own input_filter claims
-- ONLY that marker.
function input_filter(r)
    local content_type = r.headers_in and r.headers_in["Content-Type"]
    local report_kind = r.headers_in and r.headers_in["HX-Svn-Report"]

    if r.method ~= "REPORT" or not is_form_encoded_content_type(content_type) or report_kind == "locks" then
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

    -- "more=1" marks a continuous-scroll continuation request (see
    -- output_filter's own sentinel/more_href construction below) -- it
    -- only ever changes which limit env var resolve_log_limit consults,
    -- never anything else about how this body is built (peg_revision is
    -- read and applied identically either way).
    local more_flag = parse_query_param(r.args, "more") == "1"
    local limit = resolve_log_limit(r.subprocess_env, more_flag)

    local peg_revision = validate_nonneg_integer(parse_query_param(r.args, "p"))

    local body = build_log_report_body(limit, peg_revision)

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

-- The 4 confirmed Font Awesome solid icon names for each changed-path
-- action (verified by fetching each SVG directly from Font Awesome's own
-- package on unpkg.com).
local ACTION_ICONS = { A = "plus", M = "pen", D = "trash", R = "arrows-rotate" }

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
    local raw = read_template(dir, "log")
    local marker_start, marker_end = raw:find(SVNLOG_TAG, 1, true)

    if not marker_start then
        error("template '" .. template_type .. "/log.mustache' is missing the required '"
              .. SVNLOG_TAG .. "' placeholder")
    end

    local set = {
        preamble = raw:sub(1, marker_start - 1),
        postamble = raw:sub(marker_end + 1),
        item = read_template(dir, "log-item"),
        more = read_template(dir, "log-more")
    }

    log_template_cache[template_type] = set

    return set
end

-- Builds the href for one repo-root-relative path string (a changed
-- path's own destination, or its copyfrom-path). repo_root anchors it to
-- a real URL (see the "repo_root" query param read in output_filter,
-- sourced from svn-index.lua's history_href); percent_encode_path makes
-- the path safe inside an href; "?p=REV" pins it at whatever revision the
-- path text is meaningful for -- the log entry's OWN revision for the
-- destination, but copyfrom_rev for a copy source (these differ -- see
-- render_log_item). SVN_INDEX_QUERY_FILE is layered on top, but only for
-- file node-kind entries, mirroring svn-index.lua's own
-- ENTRY_CONTEXT_BUILDERS.file scoping exactly.
--
-- Returns nil (template falls back to plain, unlinked text) when
-- repo_root or revision is unknown -- e.g. a History link fetched before
-- "repo_root" existed in the URL, or a malformed copyfrom-rev.
local function build_changed_path_href(repo_root, path, revision, node_kind, query_file_params)
    if not repo_root or repo_root == "" or not revision or revision == "" then
        return nil
    end

    -- repo_root always ends in "/" (see svn-index.lua's href_through());
    -- log-report's own changed-path text always starts with "/" (it's
    -- repo-root-relative) -- strip it here to avoid a doubled "//".
    local relative_path = path:gsub("^/", "")
    local href = repo_root .. percent_encode_path(relative_path) .. "?p=" .. revision

    if node_kind == "file" then
        href = append_query(href, query_file_params)
    end

    return href
end

-- Builds the "load more" sentinel's own href: same directory currently
-- being browsed (request_href, exactly like render_log_item's own
-- revision_href below), pinned via "?p=" at one revision below the last
-- entry actually rendered -- continuing the backward walk from exactly
-- where this batch left off, without re-showing that last entry itself.
-- "more=1" is what tells input_filter/output_filter's own resolve_log_limit
-- calls to consult SVN_LOG_LIMIT_SCROLL instead of SVN_LOG_LIMIT for this
-- next batch. repo_root is echoed through unchanged (same raw query-string
-- value this request itself received) so changed-path links keep working
-- on the next batch too -- it isn't otherwise derivable by this filter
-- (see build_changed_path_href's own comment on why).
local function build_more_href(request_href, next_revision, repo_root)
    local href = request_href .. "?p=" .. next_revision .. "&more=1"

    if repo_root and repo_root ~= "" then
        href = href .. "&repo_root=" .. repo_root
    end

    return href
end

local function render_log_item(templates, item, context)
    local changed_paths = {}
    -- "Folder only" toggle support (see page.mustache's own
    -- "#svn-history-folder-toggle"/CSS): own_change means the browsed
    -- folder's OWN path (context.own_relative_path) is itself in this
    -- item's changed_paths -- creation, deletion, replace, or a
    -- property-only change, since a bare presence check covers all of
    -- those regardless of cp.action. descendant_change means some path
    -- STRICTLY UNDER the browsed folder changed. Not mutually exclusive:
    -- a single commit can both reprop the folder and add a child. Neither
    -- is ever set when context.own_relative_path is nil (repo_root
    -- absent/mismatched -- see output_filter) -- same degradation class
    -- as changed-path links themselves falling back to plain unlinked
    -- text in that case.
    local own_change, descendant_change = nil, nil

    for _, cp in ipairs(item.changed_paths) do
        local href = build_changed_path_href(
            context.repo_root, cp.path, item.revision, cp.node_kind, context.query_file_params
        )

        local entry = {
            action = cp.action,
            action_class = cp.action:lower(),
            icon = ACTION_ICONS[cp.action],
            path = escape_html(cp.path),
            href = href and escape_html(href) or nil
        }

        if cp.copyfrom_path then
            local copyfrom_href = build_changed_path_href(
                context.repo_root, cp.copyfrom_path, cp.copyfrom_rev, cp.node_kind, context.query_file_params
            )

            entry.copyfrom = {
                path = escape_html(cp.copyfrom_path),
                rev = escape_html(cp.copyfrom_rev),
                href = copyfrom_href and escape_html(copyfrom_href) or nil
            }
        end

        changed_paths[#changed_paths + 1] = entry

        -- Compared in the SAME normalized form (percent-encoded, no
        -- leading "/") build_changed_path_href already puts every
        -- changed-path into for href-building, against
        -- context.own_relative_path (derived the same way in
        -- output_filter) -- reusing percent_encode_path rather than
        -- inventing a decode counterpart.
        if context.own_relative_path then
            local cp_relative = percent_encode_path((cp.path:gsub("^/", "")))

            if cp_relative == context.own_relative_path then
                own_change = true
            elseif context.own_relative_path == ""
                or cp_relative:sub(1, #context.own_relative_path + 1) == context.own_relative_path .. "/" then
                descendant_change = true
            end
        end
    end

    return lustache:render(templates.item, {
        revision = escape_html(item.revision),
        -- Always the SAME directory currently being browsed
        -- (context.request_href), just pinned at this entry's own
        -- revision -- unlike a changed-path's own link, which may point
        -- elsewhere in the repo entirely and therefore needs repo_root.
        -- No repo_root plumbing needed for this one.
        revision_href = escape_html(context.request_href .. "?p=" .. item.revision),
        author = escape_html(item.author),
        date = escape_html(item.date),
        date_lang = context.date_lang and escape_html(context.date_lang) or nil,
        -- nil (not "") when blank -- whitespace-only counts as blank too
        -- (%s* matches newlines/tabs/spaces), not just a literal empty
        -- string. A plain Lua nil is unambiguously falsy to every mustache
        -- implementation (unlike an empty string, which some
        -- implementations treat as truthy, being neither false/nil/an
        -- empty list), so log-item.mustache can key {{^message}} directly
        -- off this same field for the "no message" styling -- no separate
        -- boolean flag needed. {{{message}}}'s own interpolation already
        -- renders nothing for a nil value, same as it would for "".
        message = (item.message:match("^%s*$") == nil) and escape_html(item.message) or nil,
        changed_paths = changed_paths,
        -- nil (not false) when unset -- same reasoning as "message" above:
        -- a plain Lua nil is unambiguously falsy to mustache, so
        -- log-item.mustache can key {{#own_change}}/{{#descendant_change}}
        -- directly off these fields.
        own_change = own_change or nil,
        descendant_change = descendant_change or nil
    })
end

function output_filter(r)
    local bucket_count = 0
    local element_count = 0
    local rendered_count = 0
    local pending_output = {}
    -- Revision of the last <S:log-item> actually rendered -- the anchor
    -- for the "load more" sentinel's own next "?p=" pin (see
    -- build_more_href), updated as items stream through EndElement below.
    local last_revision = nil

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

    -- Trusted as-is, unlike svn-index.lua's own request_href (which
    -- unconditionally force-appends "/" because its output_filter ONLY
    -- ever runs against directory-listing XML). This filter also serves
    -- file targets (the per-file history icon and "?history=" deep link,
    -- both built in svn-index.lua) -- force-appending here would turn
    -- ".../file.txt" into the non-existent ".../file.txt/", corrupting
    -- revision_href (render_log_item) and build_more_href below. Every
    -- caller of this filter is responsible for sending the correctly
    -- shaped URL itself: directories with their own trailing "/", files
    -- without. own_relative_path below (its own ":gsub("/$", "")") already
    -- strips any trailing slash before comparing against changed-path
    -- text either way, so this doesn't change own_change/descendant_change
    -- classification at all.
    local request_href = url_path(tostring(r.unparsed_uri or r.uri or ""))

    -- The repo-root URL svn-index.lua appended onto the History link as
    -- "&repo_root=..." -- this filter has no other way to know where the
    -- repo root sits in the URL space (only svn-index.lua sees
    -- mod_dav_svn's own <index base="..." path="..."> attributes;
    -- log-report XML carries no such info). Absent for an older cached
    -- History link -- changed-path links simply render as plain, unlinked
    -- text in that case.
    local repo_root = parse_query_param(r.args, "repo_root")

    -- Mirrors input_filter's own "more=1" read: only changes which limit
    -- resolve_log_limit consults below (to know the ceiling this
    -- request's own <S:limit> was actually sent with), never anything
    -- about rendering shape -- the log.mustache preamble/postamble wrapper
    -- is emitted unconditionally, on every request alike.
    local more_flag = parse_query_param(r.args, "more") == "1"
    local resolved_limit = tonumber(resolve_log_limit(r.subprocess_env, more_flag))

    -- SVN_INDEX_QUERY_FILE: the same env var svn-index.lua already reads
    -- for its own file-entry links (locked-in decision: reused, not a
    -- separate knob) -- applied only to file node-kind changed-path
    -- entries (see build_changed_path_href), mirroring svn-index.lua's
    -- own ENTRY_CONTEXT_BUILDERS.file scoping.
    local query_file_params = r.subprocess_env and r.subprocess_env.SVN_INDEX_QUERY_FILE

    -- SVN_LOG_DATE_LANG: an optional BCP-47 language tag (e.g. "sv")
    -- passed straight through as <wa-format-date>'s own "lang" attribute.
    -- Omitted entirely when unset/empty, so <wa-format-date> falls back
    -- to the browser/document's own locale (locked-in decision: not
    -- hardcoded).
    local date_lang = r.subprocess_env and r.subprocess_env.SVN_LOG_DATE_LANG

    if date_lang == "" then
        date_lang = nil
    end

    -- The browsed folder's own repo-root-relative path, normalized the
    -- same way build_changed_path_href already normalizes every
    -- changed-path entry (percent-encoded, no leading "/") -- lets
    -- render_log_item compare against each changed_paths[i].path directly
    -- without a decode step. nil whenever it can't be derived: repo_root
    -- absent (stale History link, same case build_changed_path_href
    -- already degrades for), or not actually a prefix of request_href
    -- (mismatched/stale link -- request_href is this request's own URL
    -- path, it can only fail to start with repo_root if the two disagree
    -- about where the repo root sits).
    --
    -- Browsing the repo root itself makes this "" (request_href ==
    -- repo_root) -- mod_dav_svn represents the root itself in
    -- changed-paths as "/", which strips via the exact same
    -- cp.path:gsub("^/", "") render_log_item already applies to every
    -- other changed-path to "" too, so the exact-match comparison there
    -- handles this case with no special-casing here.
    local own_relative_path = nil

    if repo_root and repo_root ~= "" and request_href:sub(1, #repo_root) == repo_root then
        own_relative_path = request_href:sub(#repo_root + 1):gsub("/$", "")
    end

    local render_context = {
        request_href = request_href,
        repo_root = repo_root,
        query_file_params = query_file_params,
        date_lang = date_lang,
        own_relative_path = own_relative_path
    }

    -- The preamble carries exactly one piece of data: whether this
    -- request's own target is a file or a directory (request_href never
    -- carries a trailing slash for a file, always does for a directory --
    -- see this filter's own comment on request_href, and the contract
    -- svn-index.lua's callers now follow to produce it). Rendered via
    -- lustache (unlike the postamble below, which stays a raw string --
    -- its own svn_log_more insertion happens via a *separate*
    -- lustache:render call further down, not here) so log.mustache's own
    -- "{{#is_file}}" can mark ".svn-log" accordingly -- lets
    -- page.mustache hide the "Folder only" toggle via CSS for file
    -- history, where it would have no visible effect (every entry is
    -- already an own-change for a file -- see render_log_item's own
    -- own_change/descendant_change comment).
    local preamble_html = lustache:render(templates.preamble, { is_file = not request_href:match("/$") })
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
                -- copyfrom-path/copyfrom-rev are only ever present on
                -- added-path/replaced-path per the confirmed log-report
                -- schema, but read unconditionally here -- nil/absent on
                -- modified-path/deleted-path, with no special-casing
                -- needed here (only in rendering, which decides whether
                -- to show a "from" indicator).
                local entry = {
                    action = CHANGED_PATH_ACTIONS[name],
                    path = "",
                    node_kind = attr["node-kind"],
                    copyfrom_path = attr["copyfrom-path"],
                    copyfrom_rev = attr["copyfrom-rev"]
                }
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
                pending_output[#pending_output + 1] = render_log_item(templates, item, render_context)
                last_revision = item.revision
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

    -- The postamble itself, unlike the streamed items above it, is a
    -- small fragment fully known at this point -- rendered through
    -- lustache once here, exactly like svn-index.lua's own
    -- page-header/page-subheader/page-footer are pre-rendered into named
    -- context keys and resolved via a single lustache:render call (see its
    -- own "context[\"page-header\"] = lustache:render(...)" convention).
    -- log.mustache's own postamble region carries a literal
    -- "{{{svn_log_more}}}" placeholder (right before its closing "</div>")
    -- for exactly this: left absent from postamble_context, it simply
    -- interpolates to nothing, same as a missing page-header does today.
    local postamble_context = {}

    -- A "load more" sentinel is only worth appending when this batch was
    -- actually full (rendered_count == resolved_limit): per
    -- build_log_report_body's own rationale comment above, mod_dav_svn
    -- stops the backward walk as soon as the limit is reached, so
    -- returning FEWER entries than that is a definitive signal the walk
    -- already reached end-revision=0 on its own -- no further history
    -- exists, and a follow-up fetch would only ever come back empty.
    -- last_revision <= 0 is the same "nothing older exists" case reached a
    -- different way (this batch's own last entry already IS the very
    -- first revision) -- checked defensively even though a full batch
    -- reaching revision 0 exactly would already fail the rendered_count
    -- check above in practice (walking to end-revision=0 means the walk
    -- stopped on its own, so rendered_count < resolved_limit almost
    -- always holds too in that case).
    if rendered_count > 0 and rendered_count == resolved_limit then
        local last_revision_num = tonumber(last_revision)

        if last_revision_num and last_revision_num > 0 then
            local more_href = build_more_href(request_href, tostring(last_revision_num - 1), repo_root)

            postamble_context.svn_log_more = lustache:render(templates.more, {
                more_href = escape_html(more_href)
            })
        end
    end

    final_parts[#final_parts + 1] = lustache:render(postamble_html, postamble_context)

    coroutine.yield(table.concat(final_parts))

    r:info(string.format(
        "SVN log listing transformed: buckets=%d elements=%d entries=%d",
        bucket_count,
        element_count,
        rendered_count
    ))
end
