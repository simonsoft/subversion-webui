-- Apache mod_lua output filter that patches a single <script> element into
-- an XML response so the client-side XSLT polyfill
-- (https://github.com/mfreed7/xslt_polyfill) can pick up the response's own
-- <?xml-stylesheet?> processing instruction and perform the transform in
-- the browser. Browsers are dropping native XSLTProcessor support, so an
-- XML response that relies on a server-side stylesheet association (e.g.
-- mod_dav_svn's SVNIndexXSLT) stops being transformed client-side without
-- this.
--
-- Unlike svn-index.lua, this filter knows nothing about SVN's XML shape:
-- it works on any well-formed XML document by locating the '>' that closes
-- the root element's opening tag and inserting the polyfill <script> tag
-- immediately after it, as the root element's first child -- the exact
-- placement https://github.com/mfreed7/xslt_polyfill's own "automatic
-- transformation" usage documents. That makes it usable on any XML
-- endpoint, not just the svn-index listing. See README-xslt-polyfill.md
-- for the full Apache config.
--
-- Configure via the XSLT_POLYFILL_URL environment variable (Apache
-- SetEnv), typically a path on this host serving the downloaded
-- xslt-polyfill.min.js. The response passes through unmodified if it's
-- unset.

local POLYFILL_ENV_VAR = "XSLT_POLYFILL_URL"

-- Generous for any real XML declaration/PI/comment/root-tag, tiny next to
-- a response body. Guards against buffering forever on a pathological (or
-- malicious) response whose root element never closes.
local MAX_PROLOGUE_BYTES = 65536

local function escape_attr(value)
    return (tostring(value or ""):gsub('"', "&quot;"))
end

local function polyfill_script_tag(url)
    return '<script src="' .. escape_attr(url) ..
           '" xmlns="http://www.w3.org/1999/xhtml"></script>'
end

-- Returns the byte offset just after the '>' that closes the root
-- element's opening tag, skipping any leading XML declaration, processing
-- instructions (e.g. <?xml-stylesheet?>), comments and doctype. Returns
-- nil -- leaving the body untouched -- if the root element is self-closing
-- (no room for a child) or its start tag can't be found at all (empty or
-- malformed body).
local function find_insertion_point(xml)
    local pos = 1

    while true do
        local lt = xml:find("<", pos, true)

        if not lt then
            return nil
        end

        if xml:sub(lt, lt + 1) == "<?" then
            local close = xml:find("?>", lt + 2, true)

            if not close then
                return nil
            end

            pos = close + 2
        elseif xml:sub(lt, lt + 3) == "<!--" then
            local close = xml:find("-->", lt + 4, true)

            if not close then
                return nil
            end

            pos = close + 3
        elseif xml:sub(lt, lt + 1) == "<!" then
            -- e.g. <!DOCTYPE ...>. Doesn't account for an internal subset
            -- containing '>', which mod_dav_svn (and every other XML
            -- source this filter is meant for) never emits.
            local close = xml:find(">", lt + 2, true)

            if not close then
                return nil
            end

            pos = close + 1
        else
            -- The root element's own opening tag: walk it character by
            -- character so a '>' inside a quoted attribute value isn't
            -- mistaken for the tag's end.
            local i = lt + 1
            local quote = nil

            while i <= #xml do
                local c = xml:sub(i, i)

                if quote then
                    if c == quote then
                        quote = nil
                    end
                elseif c == '"' or c == "'" then
                    quote = c
                elseif c == "/" and xml:sub(i + 1, i + 1) == ">" then
                    return nil -- self-closing root, no child slot
                elseif c == ">" then
                    return i + 1
                end

                i = i + 1
            end

            return nil
        end
    end
end

function output_filter(r)
    local started_at = os.clock()
    local bucket_count = 0

    local polyfill_url = r.subprocess_env and r.subprocess_env[POLYFILL_ENV_VAR]

    -- Once resolved (spliced, or given up), every remaining bucket is
    -- passed straight through with no buffering and no further scanning
    -- -- this is what keeps a large response body from ever sitting in
    -- memory. Passing through from the very start when the polyfill URL
    -- is unset needs no buffering at all either.
    local resolved = not polyfill_url or polyfill_url == ""
    local buffer = ""

    if resolved then
        r:debug(POLYFILL_ENV_VAR .. " is not set; passing XML response through unmodified")
    end

    coroutine.yield("")

    while bucket do
        bucket_count = bucket_count + 1

        if resolved then
            coroutine.yield(bucket)
        else
            buffer = buffer .. bucket

            -- The insertion point can only be found once the root
            -- element's opening tag has arrived in full, so this keeps
            -- retrying find_insertion_point on the growing buffer as more
            -- of it arrives, rather than waiting for the whole body.
            local insert_at = find_insertion_point(buffer)

            if insert_at then
                local spliced = buffer:sub(1, insert_at - 1) ..
                                 polyfill_script_tag(polyfill_url) ..
                                 buffer:sub(insert_at)

                -- The transformed body has a different length; the
                -- original entity validator no longer describes it
                -- either.
                r.headers_out["Content-Length"] = nil
                r.headers_out["ETag"] = nil

                r:info(string.format(
                    "XSLT polyfill injected: url=%s buckets=%d prologue-bytes=%d elapsed=%.6fs",
                    polyfill_url, bucket_count, #buffer, os.clock() - started_at
                ))

                resolved = true
                buffer = ""
                coroutine.yield(spliced)
            elseif #buffer > MAX_PROLOGUE_BYTES then
                r:warn(string.format(
                    "XSLT polyfill: root element start tag not found within %d bytes (buckets=%d); giving up, response left unmodified",
                    MAX_PROLOGUE_BYTES, bucket_count
                ))

                resolved = true

                local unmodified = buffer
                buffer = ""
                coroutine.yield(unmodified)
            else
                -- Not enough data yet; keep accumulating on the next
                -- bucket.
                coroutine.yield("")
            end
        end
    end

    if not resolved and buffer ~= "" then
        r:debug("XSLT polyfill: no root element start tag found; response left unmodified")
        coroutine.yield(buffer)
    end
end
