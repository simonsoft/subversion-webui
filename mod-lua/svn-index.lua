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

local function load_template_set(template_type)
    local cached = template_cache[template_type]

    if cached then
        return cached
    end

    if not template_type:match("^[%w%-]+$") then
        error("invalid template type '" .. tostring(template_type) .. "'")
    end

    local dir = template_dir(template_type)
    local preamble, postamble = split_page_template(read_file(dir .. "page.mustache"), template_type)

    local set = {
        preamble = preamble,
        postamble = postamble,
        entries = {
            updir = read_file(dir .. "updir.mustache"),
            file = read_file(dir .. "file.mustache"),
            dir = read_file(dir .. "dir.mustache"),
            repo = read_file(dir .. "repo.mustache")
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
-- count, reused by the caller to compute `root_href` (one level further up
-- than the repo root).
local function compute_breadcrumbs(path, base, has_base, request_href)
    if not has_base then
        return { { name = escape_html(path), last = true } }, 0
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
        return "/" .. table.concat(request_segments, "/", 1, repo_root_segment_count + extra_segment_count) .. "/"
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

    return breadcrumbs, total
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

    file = function(attr, request_href)
        local href = attr.href or "#"

        return {
            name = escape_html(attr.name or attr.href or ""),
            href = escape_html(href),
            hx_href = escape_html(request_href .. href)
        }
    end,

    -- nav_target_path (the path portion of htmx's "HX-Current-URL" request
    -- header, only ever computed for nav's own requests -- see the
    -- "nav_target_path" comment in output_filter()) is nil for every other
    -- request, so "is_target_any" is naturally false/omitted everywhere
    -- else, including every "repo" entry (aliased below): a repo's own
    -- hx_href is never a prefix match unless the request is literally for
    -- the Collection-of-Repositories page itself, which compares against a
    -- *shorter* path that can't "start with" a longer one.
    dir = function(attr, request_href, nav_target_path, r)
        local name = (attr.name or attr.href or ""):gsub("/$", "")
        local href = attr.href or "#"

        -- "is_target_any" below is a prefix check that relies on every
        -- directory href ending in "/" to avoid false-matching a sibling
        -- with a shared prefix (e.g. "trunk" vs "trunk-extra") -- warn
        -- loudly if mod_dav_svn ever emits one without it, since that
        -- assumption would otherwise fail silently.
        if href:sub(-1) ~= "/" then
            r:warn("svn-index: dir href does not end with '/': " .. tostring(href))
        end

        local hx_href = request_href .. href

        -- Three mutually-informing views of the same relationship between
        -- this entry and nav_target_path: "is_target_any" (a strict
        -- ancestor of the target, or the target itself -- i.e. "should
        -- this be walked open at all"), "is_target_leaf" (an exact match
        -- -- i.e. "is this the one nav's current selection points at"),
        -- and "is_target_ancestor" (on the path but not the target itself
        -- -- i.e. "should this be opened, but isn't itself the selection").
        local is_target_any = nav_target_path and nav_target_path:sub(1, #hx_href) == hx_href
        local is_target_leaf = nav_target_path == hx_href
        local is_target_ancestor = is_target_any and not is_target_leaf

        return {
            name = escape_html(name),
            href = escape_html(href),
            hx_href = escape_html(hx_href),
            is_target_any = is_target_any,
            is_target_leaf = is_target_leaf,
            is_target_ancestor = is_target_ancestor
        }
    end
}

-- A <dir> on the SVNParentPath "Collection of Repositories" listing (see
-- the has_base note above) is itself a repository root rather than an
-- ordinary subdirectory, but the XML shape mod_dav_svn emits for it is
-- identical -- so it's rendered with the "repo" entry template using the
-- same context shape as "dir".
ENTRY_CONTEXT_BUILDERS.repo = ENTRY_CONTEXT_BUILDERS.dir

local function render_entry(element, attr, request_href, templates, nav_target_path, r)
    local build_context = ENTRY_CONTEXT_BUILDERS[element]
    local entry_template = templates.entries[element]

    if not build_context or not entry_template then
        return nil
    end

    return lustache:render(entry_template, build_context(attr, request_href, nav_target_path, r))
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

    local templates = load_template_set(template_type)

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

    if r.headers_in and r.headers_in["HX-Current-URL"] and not is_named_swap_target(r.headers_in["HX-Target"]) then
        nav_target_path = url_path(r.headers_in["HX-Current-URL"])
    end

    -- Set these before emitting any transformed response content.
    r.content_type = "text/html; charset=utf-8"

    -- The transformed body has a different length.
    r.headers_out["Content-Length"] = nil

    -- The original entity validator no longer describes the transformed body.
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
    -- hx-select-oob="#subheader" directly, so only that specific element's
    -- own requests ever pull the breadcrumb along -- nav's own lazy-load
    -- fetch is a different element entirely and never has that attribute.)
    if r.headers_in and is_named_swap_target(r.headers_in["HX-Target"]) then
        r.headers_out["HX-Push-Url"] = request_href
    end

    -- mod_dav_svn omits the rev/base attributes entirely (rather than
    -- emitting them empty) on the special "Collection of Repositories"
    -- listing served from an SVNParentPath -- that's the only case where
    -- <index> lacks a base, so its absence is what distinguishes browsing a
    -- single repository (where svn's own default title/heading is
    -- "{base} - Revision {rev}: {path}") from listing the parent path
    -- (where svn's default is just "{path}", unprefixed).
    local function template_context()
        local has_base = index.base ~= ""
        local breadcrumbs, segment_count = compute_breadcrumbs(index.path, index.base, has_base, request_href)

        return {
            base = index.base,
            path = index.path,
            rev = index.rev,
            has_base = has_base,
            svn_version = svn.version,
            svn_href = svn.href,
            breadcrumbs = breadcrumbs,
            root_href = has_base and escape_html(string.rep("../", segment_count + 1)) or "",
            -- nav starts at the repo root (breadcrumbs[1] is that crumb --
            -- lustache can't reach it directly as {{breadcrumbs.1.hx_href}},
            -- since breadcrumbs is an integer-indexed array, not
            -- string-keyed), falling back to today's "." on the
            -- Collection-of-Repositories listing (no repo to root at).
            nav_root_path = has_base and breadcrumbs[1].hx_href or "."
        }
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

            local html = render_entry(element, attr, request_href, templates, nav_target_path, r)

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
