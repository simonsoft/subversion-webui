local lxp = require "lxp"
local lustache = require "lustache"

-- Resolve template.mustache next to this script, regardless of the
-- current working directory or the absolute path Apache was configured
-- with (LuaOutputFilter takes an absolute path to this file).
local function script_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source and source:match("(.*[/\\])") or "./"
end

local TEMPLATE_PATH = script_dir() .. "svn-index.mustache"

-- The template must contain the literal "{{{svn_index}}}" tag exactly once.
-- It is used as a split point, not rendered by lustache as a whole: the
-- preamble (through the opening <ul>) is rendered as soon as the <index>
-- attributes are known, the entries are streamed in verbatim as they are
-- parsed, and the postamble (footer onward) is rendered once the <svn>/
-- <index> element has been fully closed.
local template_file = assert(io.open(TEMPLATE_PATH, "r"))
local TEMPLATE = template_file:read("*a")
template_file:close()

local SVNINDEX_TAG = "{{{svn_index}}}"

local marker_start, marker_end = TEMPLATE:find(SVNINDEX_TAG, 1, true)

if not marker_start then
    error("template is missing the required '" .. SVNINDEX_TAG .. "' placeholder")
end

local PREAMBLE_TEMPLATE = TEMPLATE:sub(1, marker_start - 1)
local POSTAMBLE_TEMPLATE = TEMPLATE:sub(marker_end + 1)

local function escape_html(value)
    value = tostring(value or "")

    return (value:gsub("&", "&amp;")
                 :gsub("<", "&lt;")
                 :gsub(">", "&gt;")
                 :gsub('"', "&quot;")
                 :gsub("'", "&#39;"))
end

-- attr.href is always relative to the directory currently being listed
-- (e.g. "dita/"). That resolves fine for the top-level page, but once a
-- directory's entries are inserted into the DOM as a nested <li> via htmx,
-- a relative href/hx-get on them would still resolve against the top-level
-- document's URL rather than the directory they actually belong to -- so
-- expansion would only work one level deep. base_href (the request's own
-- r.uri, which is correct per-fragment since each expansion is a genuine
-- HTTP request to its own directory) anchors every entry to an absolute
-- path instead, so it works regardless of nesting depth.
local function render_entry(element, attr, base_href)
    if element == "updir" then
        return string.format(
            '<li class="updir"><a href="%s">../</a></li>\n',
            escape_html(base_href .. (attr.href or "../"))
        )
    end

    if element == "file" then
        local name = attr.name or attr.href or ""
        local href = escape_html(base_href .. (attr.href or "#"))

        return string.format(
            '<li class="file"><a href="%s">%s</a></li>\n',
            href,
            escape_html(name)
        )
    end

    if element == "dir" then
        local name = attr.name or attr.href or ""
        local href = escape_html(base_href .. (attr.href or "#"))

        name = name:gsub("/$", "")

        -- "closest li" targets the entry's own <li>, and hx-select picks the
        -- child directory's own listing out of the (otherwise full-page)
        -- response so it can be nested inline as an accordion; "click once"
        -- stops a second click from fetching and appending it again.
        return string.format(
            '<li class="dir"><a href="%s" hx-get="%s" hx-target="closest li" hx-swap="beforeend" hx-select=".svn-index" hx-trigger="click once">%s/</a></li>\n',
            href,
            href,
            escape_html(name)
        )
    end

    return nil
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

    -- Anchors every entry's href to this directory's own URL (see the note
    -- above render_entry) instead of leaving them relative.
    local base_href = tostring(r.uri or "")

    if base_href ~= "" and not base_href:match("/$") then
        base_href = base_href .. "/"
    end

    r:info(string.format(
        "SVN listing filter entered: method=%s uri=%s content-type=%s",
        tostring(r.method),
        tostring(r.uri),
        tostring(r.content_type)
    ))

    -- Set these before emitting any transformed response content.
    r.content_type = "text/html; charset=utf-8"

    -- The transformed body has a different length.
    r.headers_out["Content-Length"] = nil

    -- The original entity validator no longer describes the transformed body.
    r.headers_out["ETag"] = nil

    local function template_context()
        return {
            base = index.base,
            path = index.path,
            rev = index.rev,
            svn_version = svn.version,
            svn_href = svn.href
        }
    end

    local function render_preamble()
        return lustache:render(PREAMBLE_TEMPLATE, template_context())
    end

    local function render_postamble()
        return lustache:render(POSTAMBLE_TEMPLATE, template_context())
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

            local html = render_entry(name, attr, base_href)

            if html then
                rendered_count = rendered_count + 1
                pending_output[#pending_output + 1] = html

                r:debug(string.format(
                    "Rendered SVN entry #%d: type=%s name=%s href=%s",
                    rendered_count,
                    tostring(name),
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
