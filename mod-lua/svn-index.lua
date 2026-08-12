local lxp = require "lxp"
local lustache = require "lustache"

-- Resolve the repo root next to this script, regardless of the current
-- working directory or the absolute path Apache was configured with
-- (LuaOutputFilter takes an absolute path to this file).
local function script_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source and source:match("(.*[/\\])") or "./"
end

local function template_dir(template_type)
    return script_dir() .. "../templates/" .. template_type .. "/"
end

local DEFAULT_TEMPLATE_TYPE = "simple"
local SVNINDEX_TAG = "{{{svn_index}}}"

local function read_file(path)
    local file, err = io.open(path, "r")

    if not file then
        error("failed to open template file '" .. path .. "': " .. tostring(err))
    end

    local content = file:read("*a")
    file:close()

    return content
end

-- Loads "<name>.mustache" from a template type's directory, unless a
-- "<name>.custom.mustache" sits alongside it -- in which case that's loaded
-- instead. Lets a site override a single template file without forking the
-- whole set, and without editing a file this repo itself tracks.
local function read_template(dir, name)
    local custom_path = dir .. name .. ".custom.mustache"
    local custom_file = io.open(custom_path, "r")

    if custom_file then
        custom_file:close()
        return read_file(custom_path)
    end

    return read_file(dir .. name .. ".mustache")
end

-- Strips developer-facing "why" comments from the page template, so that
-- documentation meant for someone editing this file doesn't also go out
-- over the wire on every page load (see SVN_INDEX_STRIP_COMMENTS below).
-- Run in load_template_set on the whole page, before split_page_template
-- divides it into preamble/postamble -- not after, so a comment can't end
-- up straddling that split point, half-stripped. The source file on disk
-- stays untouched either way.
--
-- Block comments (JS and CSS both use /* */ here) are stripped globally;
-- "//" line comments are scoped to the literal bare "<script>...</script>"
-- block only, since the two earlier "<script src=\"https://...\">" tags in
-- <head> contain "//" as part of their URL and must survive untouched.
local function strip_wire_comments(html)
    html = html:gsub("/%*.-%*/", "")
    html = html:gsub("<!%-%-.-%-%->", "")

    html = html:gsub("(<script>)(.-)(</script>)", function(open, body, close)
        return open .. body:gsub("//[^\n]*", "") .. close
    end)

    -- Collapses the runs of now-empty lines a removed comment block leaves
    -- behind (a single gsub, since "%s*" here is greedy and backtracks to
    -- swallow an entire run of blank lines at once, however long).
    html = html:gsub("\n%s*\n", "\n")

    return html
end

-- SVN_INDEX_STRIP_COMMENTS: on (the default) unless explicitly set to one
-- of "0"/"false"/"off"/"no" (case-insensitive). Lets an admin turn
-- strip_wire_comments off to get readable page source while debugging.
local function strip_comments_enabled(r)
    local value = r.subprocess_env and r.subprocess_env.SVN_INDEX_STRIP_COMMENTS

    if value == nil or value == "" then
        return true
    end

    value = value:lower()

    return not (value == "0" or value == "false" or value == "off" or value == "no")
end

-- The page template must contain the literal "{{{svn_index}}}" tag exactly
-- once. It is used as a split point, not rendered by lustache as a whole:
-- the preamble (through the opening <ul>) is rendered as soon as the
-- <index> attributes are known, the entries are streamed in verbatim as
-- they are parsed, and the postamble (footer onward) is rendered once the
-- <svn>/<index> element has been fully closed.
local function split_page_template(page, template_type)
    local marker_start, marker_end = page:find(SVNINDEX_TAG, 1, true)

    if not marker_start then
        error("template '" .. template_type .. "/page.mustache' is missing the required '"
              .. SVNINDEX_TAG .. "' placeholder")
    end

    return page:sub(1, marker_start - 1), page:sub(marker_end + 1)
end

-- Cache of already-loaded template sets, keyed by template type. Populated
-- lazily so a worker that only ever serves one type never reads the other
-- type's files, but still avoids re-reading a type's files on every request
-- (subject to Apache's LuaCodeCache directive being "on").
local template_cache = {}

-- strip_comments decides whether strip_wire_comments runs on the page
-- template before it's split (see SVN_INDEX_STRIP_COMMENTS below). Not
-- part of the cache key: env is expected static for a worker's lifetime
-- (one Apache <Location> config), so whichever value first populates a
-- given template_type's cache entry sticks for the rest of that worker's
-- life -- same tradeoff load_template_set already makes for template_type
-- itself.
local function load_template_set(template_type, strip_comments)
    local cached = template_cache[template_type]

    if cached then
        return cached
    end

    if not template_type:match("^[%w%-]+$") then
        error("invalid template type '" .. tostring(template_type) .. "'")
    end

    local dir = template_dir(template_type)
    local page = read_template(dir, "page")

    if strip_comments then
        page = strip_wire_comments(page)
    end

    local preamble, postamble = split_page_template(page, template_type)

    local set = {
        preamble = preamble,
        postamble = postamble,
        page_head_end = read_template(dir, "page-head-end"),
        entries = {
            updir = read_template(dir, "updir"),
            file = read_template(dir, "file"),
            dir = read_template(dir, "dir"),
            repo = read_template(dir, "repo")
        }
    }

    template_cache[template_type] = set

    return set
end

local function escape_html(value)
    value = tostring(value or "")

    return (value:gsub("&", "&amp;")
                 :gsub("<", "&lt;")
                 :gsub(">", "&gt;")
                 :gsub('"', "&quot;")
                 :gsub("'", "&#39;"))
end

-- Strips a full URL (e.g. htmx's "HX-Current-URL" request header, which
-- mirrors the browser's own location.href) down to just its path, for
-- comparing against this filter's own path-only hrefs -- drops the
-- scheme://host[:port] prefix and any trailing query string/fragment.
local function url_path(url)
    local path = url:match("^%a[%w+.-]*://[^/]*(/.*)$") or url

    return path:match("^([^?#]*)")
end

-- Extracts the value of `key` from a query string. Works uniformly whether
-- `str` is a bare query string (r.args, no leading "?"), a path-plus-query
-- value (hx_href, e.g. "/svn/demo3/lang/?p=10"), or a full URL
-- (HX-Current-URL) -- if there's a "?", only what follows it is treated as
-- the query. mod_lua's own r:parseargs() only ever parses the *current
-- request's* own r.args, which covers just one of the three call sites
-- this is used from (the other two are a request header value and a
-- string this filter builds itself) -- using one hand-rolled mechanism
-- uniformly, rather than mixing that in for just the one case it covers,
-- keeps this simpler and testable without a real Apache request object.
local function parse_query_param(str, key)
    if not str then
        return nil
    end

    -- "?" is a Lua pattern magic character (a quantifier) outside a
    -- character class -- must be escaped as "%?", confirmed via a quick
    -- interpreter check: the unescaped form silently returns nil (no
    -- error, just never matches) rather than failing loudly.
    local query = (str:match("%?(.*)$") or str):match("^([^#]*)")

    for pair in query:gmatch("[^&]+") do
        local k, v = pair:match("^([^=]+)=(.*)$")
        if k == key then
            return v
        end
    end

    return nil
end

-- Merges an extra literal query-string fragment (SVN_INDEX_QUERY_FILE,
-- see ENTRY_CONTEXT_BUILDERS.file) onto an href that may or may not
-- already have its own query (e.g. a simultaneous "?p=REV" revision pin).
local function append_query(href, extra_query)
    if not extra_query or extra_query == "" then
        return href
    end

    return href .. (href:find("?", 1, true) and "&" or "?") .. extra_query
end

-- htmx resolves the "HX-Target" request header to "<tagname>#<id>" when the
-- swap target has an id, or just "<tagname>" when it doesn't (confirmed via
-- a real browser). Every template here gives an id only to the element
-- meant to receive a full "navigate to a new folder" swap; in-place
-- expansion targets (hx-target="this") are deliberately never given one.
-- Checking for the presence of "#" rather than hardcoding a specific
-- "<tagname>#<id>" string keeps this independent of which template is
-- active or what its swap target happens to be named.
local function is_named_swap_target(hx_target)
    return hx_target ~= nil and hx_target:find("#", 1, true) ~= nil
end

-- Builds the breadcrumb trail for a request inside a repository (has_base):
-- one crumb for the repo root (`base`, marked "is_repo") followed by one
-- per `path` segment (each marked "is_dir"), every one carrying an
-- "hx_href" for htmx expansion (dir.mustache-style: swaps main content in
-- place rather than a real page navigation). The final crumb (the current
-- location) is marked `last` so the template can render it unlinked --
-- clicking it would just re-fetch what's already showing. On the
-- SVNParentPath "Collection of Repositories" listing (not has_base), `path`
-- is just a label ("Collection of Repositories"), not a real path, so it's
-- rendered as a single unlinked crumb (neither "is_repo" nor "is_dir", so
-- the template gives it no icon either). Also returns the total segment
-- count, and an absolute "repo_parent_path" -- one level further up than
-- the repo root (the Collection-of-Repositories listing itself), or this
-- same request's own URL when already there.
--
-- repo_parent_path is deliberately absolute, never a relative "../../.."
-- built from a bare segment count: the page header (where
-- repo_parent_path is used, see page.mustache's "Start" link) is only
-- ever rendered on the initial full page load -- it's never part of any
-- htmx-selected swap fragment, so it's never re-rendered afterward. Once
-- the user navigates via htmx (which updates the browser's address bar
-- via history.pushState, see "HX-Push-Url" below), a relative multi-hop
-- href in that stale header would resolve against the browser's
-- *current* location at click time, not the depth it was actually
-- computed for -- landing somewhere wrong (or, for a relative "" on the
-- Collection listing, just self-linking back to wherever the user
-- currently is instead of going home). An absolute path has no such
-- dependency on the browser's current location.
local function compute_breadcrumbs(path, base, has_base, request_href, revision_suffix)
    if not has_base then
        return { { name = escape_html(path), last = true } }, 0, escape_html(request_href)
    end

    local segments = {}

    for segment in path:gmatch("[^/]+") do
        segments[#segments + 1] = segment
    end

    local total = #segments

    -- Every crumb's own "hx_href" is built from request_href's own segments
    -- (the same URL-encoded coordinate space every other hx_href in this
    -- file already uses -- see the note above render_entry) rather than by
    -- re-deriving it from `path`'s own text: sidesteps any mismatch
    -- between mod_dav_svn's XML `path` attribute and the request URI's own
    -- percent-encoding for segments containing spaces/Unicode/reserved
    -- characters. `total` is used only as a segment *count* here, never
    -- compared character-for-character against request_href.
    local request_segments = {}

    for segment in request_href:gmatch("[^/]+") do
        request_segments[#request_segments + 1] = segment
    end

    local repo_root_segment_count = #request_segments - total

    local function href_through(extra_segment_count)
        return "/" .. table.concat(request_segments, "/", 1, repo_root_segment_count + extra_segment_count)
               .. "/" .. revision_suffix
    end

    local breadcrumbs = {
        { name = escape_html(base), hx_href = escape_html(href_through(0)), is_repo = true, last = total == 0 }
    }

    for i, segment in ipairs(segments) do
        breadcrumbs[#breadcrumbs + 1] = {
            name = escape_html(segment),
            hx_href = escape_html(href_through(i)),
            is_dir = true,
            last = i == total
        }
    end

    -- One level above the repo root itself (repo_root_segment_count - 1
    -- segments) -- guarded against the Location prefix being the server
    -- root (repo_root_segment_count == 1, e.g. SVNParentPath mounted
    -- directly at "/"), where table.concat's own upper bound would
    -- otherwise fall below its lower bound and produce a bare "/" anyway,
    -- but spelled out explicitly rather than relying on that fallthrough.
    -- Deliberately never carries revision_suffix (confirmed with the user
    -- for the old relative version -- "Start" always resets to HEAD).
    local repo_parent_path = repo_root_segment_count > 1
        and "/" .. table.concat(request_segments, "/", 1, repo_root_segment_count - 1) .. "/"
        or "/"

    return breadcrumbs, total, escape_html(repo_parent_path)
end

-- attr.href is always relative to the directory currently being listed
-- (e.g. "dita/"). That's no good for the rendered <a href> once a
-- directory's entries are inserted into the DOM as a nested <li> via htmx:
-- relative URLs resolve against the top-level document's URL regardless of
-- where in the DOM the link sits, not against the directory the entry
-- actually belongs to -- so a plain click (or hx-get, which has the exact
-- same problem) on a twice-nested entry would resolve one level too
-- shallow. request_href (this request's own URL, which is correct
-- per-fragment since each expansion is a genuine HTTP request to its own
-- directory) anchors both href and hx_href to an absolute path, so both
-- work regardless of nesting depth. The original relative value is kept
-- available to templates as `href` in case it's ever needed, but the
-- rendered anchor's href attribute should use the absolute `hx_href`.
local ENTRY_CONTEXT_BUILDERS = {
    updir = function(attr, request_href)
        local href = attr.href or "../"

        return {
            href = escape_html(href),
            hx_href = escape_html(request_href .. href)
        }
    end,

    -- query_file_params (SVN_INDEX_QUERY_FILE) is applied only to file
    -- entries' own links (confirmed with the user) -- dir/updir/repo never
    -- receive it.
    file = function(attr, request_href, query_file_params)
        local href = attr.href or "#"
        local hx_href = append_query(request_href .. href, query_file_params)

        return {
            name = escape_html(attr.name or attr.href or ""),
            href = escape_html(href),
            hx_href = escape_html(hx_href)
        }
    end,

    -- nav_target_path/nav_target_revision (the path and "?p=" revision
    -- portions of htmx's "HX-Current-URL" request header, only ever
    -- computed for nav's own requests -- see the "nav_target_path" comment
    -- in output_filter()) are nil for every other request, so
    -- "is_target_any" is naturally false/omitted everywhere else,
    -- including every "repo" entry (aliased below): a repo's own hx_href
    -- is never a prefix match unless the request is literally for the
    -- Collection-of-Repositories page itself, which compares against a
    -- *shorter* path that can't "start with" a longer one.
    -- hide_dir_pattern (SVN_INDEX_HIDE_DIR, see output_filter) is only
    -- ever meant for ordinary directories -- this same function also runs
    -- for "repo" entries via the alias below, so "navhidden" ends up
    -- computed (but unused) there too: repo.mustache deliberately never
    -- references it, so a repo name matching the pattern has no visible
    -- effect.
    dir = function(attr, request_href, query_file_params, nav_target_path, nav_target_revision, r, hide_dir_pattern)
        local name = (attr.name or attr.href or ""):gsub("/$", "")
        local href = attr.href or "#"

        -- "is_target_any" below is a prefix check that relies on every
        -- directory href ending in "/" (before any "?p=REV" revision-pin
        -- suffix mod_dav_svn may have attached) to avoid false-matching a
        -- sibling with a shared prefix (e.g. "trunk" vs "trunk-extra") --
        -- warn loudly if mod_dav_svn ever emits one without it, since that
        -- assumption would otherwise fail silently.
        if url_path(href):sub(-1) ~= "/" then
            r:warn("svn-index: dir href does not end with '/': " .. tostring(href))
        end

        local hx_href = request_href .. href
        local hx_href_path = url_path(hx_href)
        local hx_href_revision = parse_query_param(hx_href, "p")

        -- Path and revision-pin must independently agree for this entry to
        -- be considered on the path to nav_target_path -- they can't be
        -- folded into a single whole-string comparison: an ancestor's own
        -- hx_href (".../trunk/?p=10") is never a string-prefix of a deeper
        -- target's own path (".../trunk/arbortext/", nav_target_path is
        -- already query-free) even with the query included on both sides,
        -- since they diverge exactly where one has "?p=10" and the other
        -- continues with "arbortext/". Revision compared via plain
        -- equality -- nil == nil (both unpinned, i.e. both HEAD) counts as
        -- a match.
        local same_revision = hx_href_revision == nav_target_revision

        -- Three mutually-informing views of the same relationship between
        -- this entry and nav_target_path: "is_target_any" (a strict
        -- ancestor of the target, or the target itself -- i.e. "should
        -- this be walked open at all"), "is_target_leaf" (an exact match
        -- -- i.e. "is this the one nav's current selection points at"),
        -- and "is_target_ancestor" (on the path but not the target itself
        -- -- i.e. "should this be opened, but isn't itself the selection").
        local is_target_any = nav_target_path and same_revision
            and nav_target_path:sub(1, #hx_href_path) == hx_href_path
        local is_target_leaf = nav_target_path and same_revision
            and nav_target_path == hx_href_path
        local is_target_ancestor = is_target_any and not is_target_leaf

        -- r:regex() returns a *table* (truthy) on match, `false` on no
        -- match -- normalized to a plain boolean here (rather than handing
        -- lustache that raw table) since lustache treats a table-valued
        -- mustache section specially (iterating it as a list, or using it
        -- as a sub-context) instead of the simple render-once-if-truthy
        -- behavior every other boolean field here relies on.
        local navhidden = hide_dir_pattern ~= nil and r:regex(name, hide_dir_pattern) ~= false

        return {
            name = escape_html(name),
            href = escape_html(href),
            hx_href = escape_html(hx_href),
            is_target_any = is_target_any,
            is_target_leaf = is_target_leaf,
            is_target_ancestor = is_target_ancestor,
            navhidden = navhidden
        }
    end
}

-- A <dir> on the SVNParentPath "Collection of Repositories" listing (see
-- the has_base note above) is itself a repository root rather than an
-- ordinary subdirectory, but the XML shape mod_dav_svn emits for it is
-- identical -- so it's rendered with the "repo" entry template using the
-- same context shape as "dir".
ENTRY_CONTEXT_BUILDERS.repo = ENTRY_CONTEXT_BUILDERS.dir

local function render_entry(element, attr, request_href, templates, query_file_params, nav_target_path, nav_target_revision, r, hide_dir_pattern)
    local build_context = ENTRY_CONTEXT_BUILDERS[element]
    local entry_template = templates.entries[element]

    if not build_context or not entry_template then
        return nil
    end

    return lustache:render(entry_template, build_context(attr, request_href, query_file_params, nav_target_path, nav_target_revision, r, hide_dir_pattern))
end

function output_filter(r)
    local started_at = os.clock()

    local bucket_count = 0
    local byte_count = 0
    local element_count = 0
    local rendered_count = 0

    local pending_output = {}

    local index = {
        rev = "",
        path = "",
        base = ""
    }
    local index_seen = false

    local svn = {
        version = "",
        href = "http://subversion.apache.org/"
    }

    local preamble_sent = false

    local template_type = (r.subprocess_env and r.subprocess_env.SVN_INDEX_TEMPLATE) or ""

    if template_type == "" then
        template_type = DEFAULT_TEMPLATE_TYPE
    end

    local templates = load_template_set(template_type, strip_comments_enabled(r))

    -- Anchors every entry's href to this directory's own URL (see the note
    -- above render_entry) instead of leaving them relative. Built from
    -- "r.unparsed_uri" (the raw request URI as the client actually sent
    -- it, still percent-encoded), not "r.uri" (Apache's own *decoded*
    -- parsed path) -- confirmed via a real browser that mod_dav_svn's own
    -- XML "href" attribute is percent-encoded (e.g. "140%20Securing/"), so
    -- concatenating a decoded "r.uri" prefix onto one of those silently
    -- produced a broken, inconsistently-encoded URL (literal spaces mixed
    -- with "%20" in the very same hx_href) for any directory whose name
    -- needs encoding.
    local request_href = url_path(tostring(r.unparsed_uri or r.uri or ""))

    if request_href ~= "" and not request_href:match("/$") then
        request_href = request_href .. "/"
    end

    -- mod_dav_svn's own "?p=REV" revision-pin convention. Ordinary entries
    -- need no help from this at all -- mod_dav_svn's own <dir>/<file>/
    -- <repo>/<updir> href XML attribute already includes "?p=10" itself
    -- when pinned, and request_href .. href (see ENTRY_CONTEXT_BUILDERS)
    -- carries that forward automatically. This is only for URLs built here
    -- from scratch, with no XML href to inherit the pin from: breadcrumbs,
    -- nav_root_path (reuses breadcrumbs[1]), and HX-Push-Url.
    local revision_pinned = parse_query_param(r.args, "p")
    local revision_suffix = revision_pinned and ("?p=" .. revision_pinned) or ""

    -- SVN_INDEX_QUERY_FILE: despite the name, this is the literal extra
    -- query-string fragment itself (e.g. "view=details&this=that"), not a
    -- file path -- applied only to file.mustache's own link (confirmed
    -- with the user), never to dir/breadcrumb/nav links.
    local query_file_params = r.subprocess_env and r.subprocess_env.SVN_INDEX_QUERY_FILE

    -- SVN_INDEX_HIDE_DIR: a PCRE regex, tested against each *directory*
    -- entry's own name (never repo entries -- see
    -- ENTRY_CONTEXT_BUILDERS.dir) via mod_lua's own built-in r:regex() --
    -- no extra Lua library needed. Matches are tagged "navhidden" -- hidden
    -- via CSS in the nav tree only, revealed by the same "Show folders"
    -- wa-switch that already reveals directories in the main content panel
    -- (see templates/wa-page/page.mustache). r:regex() itself never raises
    -- on a malformed pattern -- confirmed against mod_lua's own C source
    -- (lua_ap_regex in modules/lua/lua_request.c): it returns `false` for
    -- *both* "no match" and "pattern failed to compile", distinguishable
    -- only via a second return value (an error string) present solely in
    -- the latter case. Checked once here, against an empty string, purely
    -- to log one warning per request instead of silently (and repeatedly,
    -- once per entry) matching nothing.
    local hide_dir_pattern = r.subprocess_env and r.subprocess_env.SVN_INDEX_HIDE_DIR

    if hide_dir_pattern and hide_dir_pattern ~= "" then
        local _, compile_err = r:regex("", hide_dir_pattern)

        if compile_err then
            r:warn("svn-index: invalid SVN_INDEX_HIDE_DIR pattern, ignoring: " .. tostring(hide_dir_pattern) .. " (" .. tostring(compile_err) .. ")")
            hide_dir_pattern = nil
        end
    end

    r:info(string.format(
        "SVN listing filter entered: method=%s uri=%s content-type=%s template=%s",
        tostring(r.method),
        tostring(r.uri),
        tostring(r.content_type),
        template_type
    ))

    -- htmx sends this on every request as the browser's currently-displayed
    -- URL at request time -- logged only when present (a plain, non-htmx
    -- request never sends it) to help correlate a listing request with
    -- where the user was actually browsing from.
    if r.headers_in and r.headers_in["HX-Current-URL"] then
        r:info("HX-Current-URL: " .. tostring(r.headers_in["HX-Current-URL"]))
    end

    -- Powers nav's auto-expand-to-current-folder: since location.href never
    -- actually changes during nav's own background fetches (only real page
    -- loads do that), every request in the chain sees the same
    -- HX-Current-URL -- the one real target the whole cascade is walking
    -- toward -- so each one can independently decide, from this alone,
    -- whether any of its own entries sit on the path to it (see
    -- "is_target_any" in ENTRY_CONTEXT_BUILDERS.dir). Excluded for main's own
    -- content-swap request (a named swap target, the same distinction
    -- HX-Push-Url below also uses) -- otherwise, browsing several
    -- levels deep via main and then clicking a *shallower* ancestor's
    -- label in nav would see HX-Current-URL still pointing at the deeper
    -- (pre-navigation) URL and could wrongly mark one of main's own,
    -- supposedly-always-flat entries as on the path.
    local nav_target_path = nil
    local nav_target_revision = nil

    if r.headers_in and r.headers_in["HX-Current-URL"] and not is_named_swap_target(r.headers_in["HX-Target"]) then
        nav_target_path = url_path(r.headers_in["HX-Current-URL"])
        nav_target_revision = parse_query_param(r.headers_in["HX-Current-URL"], "p")
    end

    -- Set these before emitting any transformed response content.
    r.content_type = "text/html; charset=utf-8"

    -- The transformed body has a different length.
    r.headers_out["Content-Length"] = nil

    -- The original entity validator no longer describes the transformed
    -- body -- cleared unconditionally here; a new one for the transformed
    -- body itself may be re-set below, once the revision is known (see the
    -- "index" branch of the StartElement handler).
    r.headers_out["ETag"] = nil

    -- Only a main-content-swap request (dir.mustache's label, targeting a
    -- named element such as wa-page's "#svn-index") represents an actual
    -- "navigate to a new folder" -- the nav tree's own in-place lazy
    -- expansion (hx-target="this", an element with no id) never changes
    -- what main is showing, so it must not push a new URL. Returning this
    -- as a response header, rather than "hx-push-url" on the template,
    -- keeps the decision here where the true swap target (from the
    -- incoming request) is actually known. (The breadcrumb itself doesn't
    -- need this: dir.mustache's label carries its own
    -- hx-select-oob="#breadcrumb" directly, so only that specific
    -- element's own requests ever pull the breadcrumb along -- nav's own
    -- lazy-load fetch is a different element entirely and never has that
    -- attribute. "#breadcrumb" is the wrapping div, not just
    -- <wa-breadcrumb> itself, so the revision badge (a sibling inside that
    -- same div) rides along with it as one conceptual unit. Scoped to that
    -- div, not the whole "#subheader", so this swap leaves the "Show
    -- folders" wa-switch's own state alone.)
    if r.headers_in and is_named_swap_target(r.headers_in["HX-Target"]) then
        r.headers_out["HX-Push-Url"] = request_href .. revision_suffix
    end

    -- mod_dav_svn omits the "base" attribute entirely (rather than emitting
    -- it empty) on the special "Collection of Repositories" listing served
    -- from an SVNParentPath -- that's the only case where <index> lacks a
    -- base, so its absence is what distinguishes browsing a single
    -- repository (where svn's own default title/heading is "{base} -
    -- Revision {rev}: {path}") from listing the parent path (where svn's
    -- default is just "{path}", unprefixed). Confirmed against a real
    -- server that "rev" is NOT necessarily omitted alongside it (mod_dav_svn
    -- can still emit e.g. rev="0" there) -- "base", not "rev", is the only
    -- reliable signal, which is why every other "has_base"-gated decision
    -- in this file (including the ETag guard below) keys off it alone.
    local function template_context()
        local has_base = index.base ~= ""
        local breadcrumbs, segment_count, repo_parent_path = compute_breadcrumbs(index.path, index.base, has_base, request_href, revision_suffix)

        -- repo_root: the repo root's own absolute, query-string-free URL,
        -- passed through on history_href so svn-log.lua's output_filter
        -- (which never sees mod_dav_svn's own <index base="..."
        -- path="..."> attributes -- only svn-index.lua does) can anchor
        -- changed-path links to a real URL. breadcrumbs[1].hx_href already
        -- carries THIS request's own revision_suffix baked in (see
        -- href_through() above) -- stripped back off here, since repo_root
        -- itself must be revision-suffix-free: each log entry re-adds its
        -- own "?p=REV" using its own revision, not necessarily this
        -- request's.
        --
        -- Known, acceptable limitation (matching this codebase's existing
        -- precision level -- e.g. SVN_INDEX_QUERY_FILE's own values are
        -- also never percent-encoded): not percent-encoded as a
        -- query-string value here, so a literal "&"/"#" inside a
        -- repository name would corrupt it. Extremely unlikely in
        -- practice, not worth solving now.
        local repo_root = has_base and breadcrumbs[1].hx_href:match("^([^?]*)") or nil

        -- Built raw (unescaped) first, then escape_html'd exactly once at
        -- the very end -- matching every other href in this file -- rather
        -- than escaping the base href and concatenating a raw repo_root
        -- onto it afterward, which would leave repo_root's own value
        -- unescaped.
        local history_href_raw = request_href .. revision_suffix

        if repo_root then
            history_href_raw = append_query(history_href_raw, "repo_root=" .. repo_root)
        end

        local context = {
            base = index.base,
            path = index.path,
            rev = index.rev,
            has_base = has_base,
            svn_version = svn.version,
            svn_href = svn.href,
            breadcrumbs = breadcrumbs,
            repo_parent_path = repo_parent_path,
            -- "Up" (page.mustache's hardcoded href="../") preserves the pin
            -- only when staying inside the same repository -- from the
            -- repo root itself (zero path segments), "Up" instead exits to
            -- the Collection-of-Repositories listing, which has no
            -- revision concept at all, so the pin is dropped there.
            revision_suffix_up = escape_html(segment_count > 0 and revision_suffix or ""),
            -- Only truthy when actually pinned -- lets the template show
            -- the revision badge conditionally, and never show a "?p="
            -- artifact while at HEAD.
            revision_pinned = revision_pinned and escape_html(revision_pinned) or nil,
            -- The "History" link's target (see page.mustache): a REPORT
            -- request against this same directory. Distinguished from
            -- ordinary svn-client REPORT traffic against the same URL space
            -- by Content-Type, not by anything in the URL (see svn-log.lua's
            -- input_filter's own is_form_encoded_content_type check) -- so
            -- this is just request_href plus the same revision-pin suffix
            -- every other link here carries forward.
            --
            -- Unlike "Start" (a fixed, request-independent destination) or
            -- "Up" (a relative href that re-resolves against wherever the
            -- browser currently is, per the comment above
            -- compute_breadcrumbs), this is both absolute AND
            -- request-specific -- so, also unlike either of those, it goes
            -- stale after an htmx-driven navigation that doesn't reload the
            -- page. page.mustache's header cluster carries an id
            -- ("#header-left") specifically so the breadcrumb/dir.mustache
            -- navigation links can pull a freshly-rendered one out of their
            -- own full-page response via hx-select-oob, the same way they
            -- already do for "#breadcrumb"/"#footer".
            history_href = escape_html(history_href_raw),
            -- nav starts at the repo root (breadcrumbs[1] is that crumb --
            -- lustache can't reach it directly as {{breadcrumbs.1.hx_href}},
            -- since breadcrumbs is an integer-indexed array, not
            -- string-keyed), falling back to today's "." on the
            -- Collection-of-Repositories listing (no repo to root at).
            nav_root_path = has_base and breadcrumbs[1].hx_href or "."
        }

        -- Rendered with this same context (minus itself) so site-supplied
        -- head content can reference any of the fields above (e.g. `path`
        -- or `base` in a page-specific <title>/<meta> override).
        context["page-head-end"] = lustache:render(templates.page_head_end, context)

        return context
    end

    local function render_preamble()
        return lustache:render(templates.preamble, template_context())
    end

    local function render_postamble()
        return lustache:render(templates.postamble, template_context())
    end

    local parser = lxp.new({
        StartElement = function(_, name, attr)
            element_count = element_count + 1

            r:debug(string.format(
                "SVN XML element #%d: name=%s",
                element_count,
                tostring(name)
            ))

            if name == "svn" then
                svn.version = attr.version or ""
                svn.href = attr.href or svn.href

                r:debug(string.format(
                    "SVN module metadata: version=%s href=%s",
                    svn.version,
                    svn.href
                ))

                return
            end

            if name == "index" then
                index.rev = attr.rev or ""
                index.path = attr.path or ""
                index.base = attr.base or ""
                index_seen = true

                -- A new entity validator for the *transformed* body
                -- (mirrors mod_dav_svn's own ETag convention, minus the
                -- path component -- HTTP already scopes ETag validation to
                -- the requested URL itself). Weak (W/), since this is a
                -- semantically-equivalent rendering of the underlying
                -- revision, not a byte-precise one. Only set when this
                -- response is provably a pure function of (repo, path,
                -- revision): omitted for nav's own root/lazy-expansion
                -- fetches (nav_target_path truthy -- see the comment above
                -- it), whose expanded/selected markers can differ for the
                -- identical URL+revision depending on the browser's
                -- current HX-Current-URL; also omitted on the Collection-
                -- of-Repositories listing, which has no revision concept
                -- at all -- gated on "index.base ~= \"\"" (the same
                -- has_base signal template_context() already relies on),
                -- NOT "index.rev ~= \"\"": confirmed against a real server
                -- that mod_dav_svn still emits a "rev" attribute (e.g.
                -- "0") on the Collection-of-Repositories listing even
                -- though it omits "base" there, so index.rev alone isn't a
                -- reliable signal for "is this a real repository". index.rev
                -- is mod_dav_svn's own trusted XML output (always a plain
                -- integer), not client-supplied, so no separate escaping is
                -- needed for the header value.
                if index.base ~= "" and not nav_target_path then
                    r.headers_out["ETag"] = 'W/"' .. index.rev .. '-lua"'
                end

                r:debug(string.format(
                    "SVN index metadata: rev=%s path=%s base=%s",
                    index.rev,
                    index.path,
                    index.base
                ))

                return
            end

            -- <index> is always parsed before any entry (it's their parent
            -- element), so index.base is already known here: on the
            -- SVNParentPath "Collection of Repositories" listing (no base)
            -- every <dir> is a repository root, not an ordinary
            -- subdirectory -- render it with the "repo" template instead.
            local element = name

            if element == "dir" and index.base == "" then
                element = "repo"
            end

            local html = render_entry(element, attr, request_href, templates, query_file_params, nav_target_path, nav_target_revision, r, hide_dir_pattern)

            if html then
                rendered_count = rendered_count + 1
                pending_output[#pending_output + 1] = html

                r:debug(string.format(
                    "Rendered SVN entry #%d: type=%s name=%s href=%s",
                    rendered_count,
                    tostring(element),
                    tostring(attr.name or ""),
                    tostring(attr.href or "")
                ))
            end
        end
    })

    if not parser then
        r:err("Failed to create LuaExpat parser")
        return
    end

    -- mod_lua only fetches the first input chunk into `bucket` after the
    -- coroutine yields once; without this, `bucket` is still nil on the
    -- very first pass and the loop below never runs at all.
    coroutine.yield("")

    while bucket do
        bucket_count = bucket_count + 1
        byte_count = byte_count + #bucket
        pending_output = {}

        r:debug(string.format(
            "SVN XML bucket #%d: %d bytes",
            bucket_count,
            #bucket
        ))

        local ok, err, line, column = parser:parse(bucket)

        if not ok then
            r:err(string.format(
                "SVN XML parse error in bucket #%d at line %s, column %s: %s",
                bucket_count,
                tostring(line),
                tostring(column),
                tostring(err)
            ))

            parser:close()
            return
        end

        local output_parts = {}

        -- The <svn>/<index> attributes are always the first thing parsed,
        -- so by the time we know about them we haven't emitted anything
        -- for this response yet: fold the rendered preamble into this same
        -- yield rather than yielding it separately, keeping one yield per
        -- input bucket just like before.
        if not preamble_sent and index_seen then
            output_parts[#output_parts + 1] = render_preamble()
            preamble_sent = true
        end

        output_parts[#output_parts + 1] = table.concat(pending_output)

        local output = table.concat(output_parts)

        r:debug(string.format(
            "SVN XML bucket #%d produced %d HTML bytes",
            bucket_count,
            #output
        ))

        coroutine.yield(output)
    end

    pending_output = {}

    local ok, err, line, column = parser:parse()

    if not ok then
        r:err(string.format(
            "SVN XML finalization error at line %s, column %s: %s",
            tostring(line),
            tostring(column),
            tostring(err)
        ))

        parser:close()
        return
    end

    parser:close()

    local final_parts = {}

    -- Defensive fallback: an empty or malformed response body would
    -- otherwise never get a preamble at all. Folded into the same final
    -- yield as the postamble, keeping a single yield here as before.
    if not preamble_sent then
        final_parts[#final_parts + 1] = render_preamble()
        preamble_sent = true
    end

    final_parts[#final_parts + 1] = render_postamble()

    coroutine.yield(table.concat(final_parts))

    r:info(string.format(
        "SVN listing transformed: buckets=%d input-bytes=%d elements=%d entries=%d svn-version=%s elapsed=%.6fs",
        bucket_count,
        byte_count,
        element_count,
        rendered_count,
        svn.version,
        os.clock() - started_at
    ))
end
