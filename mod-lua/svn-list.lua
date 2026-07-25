local lxp = require "lxp"

local HTML_HEADER = [[
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Repository</title>
<style>
body {
    margin: 2rem auto;
    padding: 0 1rem;
    font-family: system-ui, sans-serif;
}

ul {
    padding-left: 1.5rem;
    line-height: 1.7;
}

.dir > a {
    font-weight: 600;
}

footer {
    margin-top: 2rem;
    color: #666;
    font-size: 0.9rem;
}
</style>
</head>
<body>
<h1>Repository</h1>
<ul>
]]

local function escape_html(value)
    value = tostring(value or "")

    return (value:gsub("&", "&amp;")
                 :gsub("<", "&lt;")
                 :gsub(">", "&gt;")
                 :gsub('"', "&quot;")
                 :gsub("'", "&#39;"))
end

local function render_entry(element, attr)
    if element == "updir" then
        return string.format(
            '<li class="updir"><a href="%s">../</a></li>\n',
            escape_html(attr.href or "../")
        )
    end

    if element == "file" then
        local name = attr.name or attr.href or ""
        local href = attr.href or "#"

        return string.format(
            '<li class="file"><a href="%s">%s</a></li>\n',
            escape_html(href),
            escape_html(name)
        )
    end

    if element == "dir" then
        local name = attr.name or attr.href or ""
        local href = attr.href or "#"

        name = name:gsub("/$", "")

        return string.format(
            '<li class="dir"><a href="%s">%s/</a></li>\n',
            escape_html(href),
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

    local parser = lxp.new({
        StartElement = function(_, name, attr)
            element_count = element_count + 1

            r:debug(string.format(
                "SVN XML element #%d: name=%s",
                element_count,
                tostring(name)
            ))

            if name == "index" then
                index.rev = attr.rev or ""
                index.path = attr.path or ""
                index.base = attr.base or ""

                r:debug(string.format(
                    "SVN index metadata: rev=%s path=%s base=%s",
                    index.rev,
                    index.path,
                    index.base
                ))

                return
            end

            local html = render_entry(name, attr)

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

    -- Emit the HTML prefix and suspend until the first input bucket arrives.
    coroutine.yield(HTML_HEADER)

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

        local output = table.concat(pending_output)

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

    local footer = string.format(
        [[
</ul>
<footer>
<p>Repository: %s · Path: %s · Revision: %s</p>
</footer>
</body>
</html>
]],
        escape_html(index.base),
        escape_html(index.path),
        escape_html(index.rev)
    )

    coroutine.yield(footer)

    r:info(string.format(
        "SVN listing transformed: buckets=%d input-bytes=%d elements=%d entries=%d elapsed=%.6fs",
        bucket_count,
        byte_count,
        element_count,
        rendered_count,
        os.clock() - started_at
    ))
end

