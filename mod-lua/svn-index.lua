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

-- attr.href is always relative to the directory currently being listed
-- (e.g. "dita/"). That's no good for the rendered <a href> once a
-- directory's entries are inserted into the DOM as a nested <li> via htmx:
-- relative URLs resolve against the top-level document's URL regardless of
-- where in the DOM the link sits, not against the directory the entry
-- actually belongs to -- so a plain click (or hx-get, which has the exact
-- same problem) on a twice-nested entry would resolve one level too
-- shallow. base_href (the request's own r.uri, which is correct
-- per-fragment since each expansion is a genuine HTTP request to its own
-- directory) anchors both href and hx_href to an absolute path, so both
-- work regardless of nesting depth. The original relative value is kept
-- available to templates as `href` in case it's ever needed, but the
-- rendered anchor's href attribute should use the absolute `hx_href`.
local ENTRY_CONTEXT_BUILDERS = {
    updir = function(attr, base_href)
        local href = attr.href or "../"

        return {
            href = escape_html(href),
            hx_href = escape_html(base_href .. href)
        }
    end,

    file = function(attr, base_href)
        local href = attr.href or "#"

        return {
            name = escape_html(attr.name or attr.href or ""),
            href = escape_html(href),
            hx_href = escape_html(base_href .. href)
        }
    end,

    dir = function(attr, base_href)
        local name = (attr.name or attr.href or ""):gsub("/$", "")
        local href = attr.href or "#"

        return {
            name = escape_html(name),
            href = escape_html(href),
            hx_href = escape_html(base_href .. href)
        }
    end
}

-- A <dir> on the SVNParentPath "Collection of Repositories" listing (see
-- the has_base note above) is itself a repository root rather than an
-- ordinary subdirectory, but the XML shape mod_dav_svn emits for it is
-- identical -- so it's rendered with the "repo" entry template using the
-- same context shape as "dir".
ENTRY_CONTEXT_BUILDERS.repo = ENTRY_CONTEXT_BUILDERS.dir

local function render_entry(element, attr, base_href, templates)
    local build_context = ENTRY_CONTEXT_BUILDERS[element]
    local entry_template = templates.entries[element]

    if not build_context or not entry_template then
        return nil
    end

    return lustache:render(entry_template, build_context(attr, base_href))
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
    -- above render_entry) instead of leaving them relative.
    local base_href = tostring(r.uri or "")

    if base_href ~= "" and not base_href:match("/$") then
        base_href = base_href .. "/"
    end

    r:info(string.format(
        "SVN listing filter entered: method=%s uri=%s content-type=%s template=%s",
        tostring(r.method),
        tostring(r.uri),
        tostring(r.content_type),
        template_type
    ))

    -- Set these before emitting any transformed response content.
    r.content_type = "text/html; charset=utf-8"

    -- The transformed body has a different length.
    r.headers_out["Content-Length"] = nil

    -- The original entity validator no longer describes the transformed body.
    r.headers_out["ETag"] = nil

    -- mod_dav_svn omits the rev/base attributes entirely (rather than
    -- emitting them empty) on the special "Collection of Repositories"
    -- listing served from an SVNParentPath -- that's the only case where
    -- <index> lacks a base, so its absence is what distinguishes browsing a
    -- single repository (where svn's own default title/heading is
    -- "{base} - Revision {rev}: {path}") from listing the parent path
    -- (where svn's default is just "{path}", unprefixed).
    local function template_context()
        return {
            base = index.base,
            path = index.path,
            rev = index.rev,
            has_base = index.base ~= "",
            svn_version = svn.version,
            svn_href = svn.href
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

            local html = render_entry(element, attr, base_href, templates)

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
