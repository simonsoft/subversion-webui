-- The History dialog's per-file diff (see README.md's "Diff" section).
--
-- Not a filter of its own: svn-log.lua's input_filter/output_filter
-- dispatch here whenever a request carries "diff=1", so a deployment that
-- already has History configured needs no extra Apache config at all (the
-- SVN_LOG_HTML FilterProvider condition -- REPORT, XML response,
-- HX-Request -- already matches this request too). svn-log.lua dofile()s
-- this file and uses the table it returns. Everything in here is plain Lua
-- over strings and tables -- no request_rec, no lustache, no template
-- loading -- so spec/svn_diff_spec.lua can exercise it directly.
--
-- The data source is mod_dav_svn's file-revs-report (the same REPORT
-- "svn blame" uses), requested on "<file>?p=N" with start-revision N-1 and
-- end-revision N (see svn-log.lua's build_file_revs_report_body).
-- Confirmed against a real mod_dav_svn 1.14 server, it answers with at
-- most two <S:file-rev> elements:
--
--   1. The file as it was at N-1 -- the newest revision <= N-1 where it
--      last changed, followed back through copies and renames (a file
--      modified inside a branch copied in the same commit, or renamed and
--      modified in one commit, resolves to its real predecessor). Its
--      <S:set-prop> list is the full property set (a delta against "no
--      properties"), and its <S:txdelta> the full content (a delta
--      against the empty file).
--   2. The file at N: <S:set-prop>/<S:remove-prop> for just what changed,
--      and a <S:txdelta> against (1) -- absent entirely when only
--      properties changed (svn 1.9+).
--
-- A file added in N without history yields only (2), as a delta against
-- nothing. Path-based authz applies exactly as it does for browsing:
-- mod_dav_svn runs svn_repos_get_file_revs2 with its own authz callback.
--
-- Each <S:txdelta> is base64-encoded svndiff. A browser never lists
-- "svndiff1"/"svndiff2" in Accept-Encoding, so mod_dav_svn always answers
-- this app's requests with the uncompressed svndiff0 format (confirmed
-- against mod_dav_svn's own repos.c: no svndiff encoding preference means
-- version 0) -- no zlib/LZ4 decoder is needed here.

local lxp = require "lxp"

local M = {}

-- Lines of unchanged context kept around each change, like "diff -u".
local DIFF_CONTEXT_LINES = 3

-- Default for SVN_DIFF_MAX_BYTES: the largest content (per side) a diff
-- is computed for.
M.DEFAULT_MAX_BYTES = 1048576

-- Upper bound on the line diff's own work (see diff_sequences): roughly
-- the number of diagonals explored, summed over every edit distance
-- tried. Plenty for any realistic edit of a file under the size cap; a
-- pathological input (two unrelated files with no common lines left in
-- the middle) stops early and degrades to "everything in this region
-- changed" instead of tying up the worker -- still a correct diff, just
-- not a minimal one (the template flags it as "approximate").
local LINE_DIFF_BUDGET = 5000000

-- Same, for the within-line highlighting of one changed line pair, which
-- simply falls back to no highlighting when exceeded.
local TOKEN_DIFF_BUDGET = 200000

-- Within-line highlighting is skipped for lines longer than this (bytes)
-- -- e.g. minified or single-line XML, where marking words in a
-- megabyte-long line is neither cheap nor readable.
local TOKEN_DIFF_MAX_LINE = 10000

-- Within-line highlighting stops (the remaining changed lines are shown
-- without it) once this many bytes of changed lines have been
-- highlighted in one diff -- it's per-pair work on top of the line diff,
-- and a diff that large is read for its lines, not its words.
local TOKEN_DIFF_TOTAL_BYTES = 262144

-- A changed line pair only gets within-line highlighting when at least
-- this fraction of the longer line is unchanged -- otherwise the whole
-- line is the change, and marking nearly every word just adds noise.
local TOKEN_DIFF_MIN_COMMON = 0.4

-- Duplicated from svn-index.lua/svn-log.lua (no shared module exists for
-- these two -- this file only returns the diff-specific functions).
local function escape_html(value)
    value = tostring(value or "")

    return (value:gsub("&", "&amp;")
                 :gsub("<", "&lt;")
                 :gsub(">", "&gt;")
                 :gsub('"', "&quot;")
                 :gsub("'", "&#39;"))
end

-- ---------------------------------------------------------------------
-- base64 and svndiff0 decoding
-- ---------------------------------------------------------------------

local BASE64_VALUES = {}

do
    local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    for i = 1, #alphabet do
        BASE64_VALUES[alphabet:byte(i)] = i - 1
    end
end

-- Plain Lua rather than mod_lua's own r:base64_decode, so this stays
-- testable without a request_rec. mod_dav_svn line-wraps long base64
-- runs, so every non-alphabet byte (newlines included) is dropped first.
-- Bytes are collected into a numeric buffer and flushed through
-- string.char in batches -- one tiny string per 3 bytes would cost far
-- more on a megabyte of content.
function M.base64_decode(encoded)
    local clean = encoded:gsub("[^%w%+/]", "")
    local pieces = {}
    local buffer = {}
    local count = 0
    local len = #clean

    for i = 1, len - 3, 4 do
        local a, b, c, d = clean:byte(i, i + 3)
        local n = BASE64_VALUES[a] * 262144 + BASE64_VALUES[b] * 4096
                  + BASE64_VALUES[c] * 64 + BASE64_VALUES[d]

        buffer[count + 1] = n // 65536
        buffer[count + 2] = (n // 256) % 256
        buffer[count + 3] = n % 256
        count = count + 3

        if count >= 3000 then
            pieces[#pieces + 1] = string.char(table.unpack(buffer, 1, count))
            count = 0
        end
    end

    -- 2 or 3 leftover characters (the "=" padding was stripped above)
    -- carry 1 or 2 final bytes. A single leftover character carries no
    -- whole byte and is invalid base64 anyway -- ignored.
    local tail = len % 4

    if tail >= 2 then
        local a, b, c = clean:byte(len - tail + 1, len)
        local n = BASE64_VALUES[a] * 262144 + BASE64_VALUES[b] * 4096 + (c and BASE64_VALUES[c] * 64 or 0)

        buffer[count + 1] = n // 65536
        count = count + 1

        if tail == 3 then
            buffer[count + 1] = (n // 256) % 256
            count = count + 1
        end
    end

    if count > 0 then
        pieces[#pieces + 1] = string.char(table.unpack(buffer, 1, count))
    end

    return table.concat(pieces)
end

-- svndiff's variable-length integers: 7 bits per byte, most significant
-- group first, high bit set on every byte but the last.
local function read_varint(data, pos)
    local value = 0

    while true do
        local byte = data:byte(pos)

        if not byte then
            return nil, pos
        end

        pos = pos + 1
        value = value * 128 + byte % 128

        if byte < 128 then
            return value, pos
        end
    end
end

-- Applies an svndiff0 delta (already base64-decoded) to `source`,
-- returning the target text -- or nil plus a reason ("too_large" when the
-- target would exceed max_bytes, otherwise a description of what's wrong
-- with the stream). Format per Subversion's own notes/svndiff: "SVN\0",
-- then windows of five varints (source view offset/length, target view
-- length, instructions length, new data length), the instructions, and
-- the new data. Each instruction's top two bits select copy-from-source,
-- copy-from-target or copy-from-new-data, its low six bits carry the
-- length (or 0, with the length following as a varint), and a copy from
-- source/target is followed by its offset.
function M.svndiff_apply(delta, source, max_bytes)
    if delta:sub(1, 3) ~= "SVN" or #delta < 4 then
        return nil, "not an svndiff stream"
    end

    local version = delta:byte(4)

    if version ~= 0 then
        return nil, "unsupported svndiff version " .. tostring(version)
    end

    local windows = {}
    local total = 0
    local pos = 5
    local len = #delta

    while pos <= len do
        local sview_offset, sview_len, tview_len, ins_len, new_len

        sview_offset, pos = read_varint(delta, pos)
        sview_len, pos = read_varint(delta, pos)
        tview_len, pos = read_varint(delta, pos)
        ins_len, pos = read_varint(delta, pos)
        new_len, pos = read_varint(delta, pos)

        if not new_len or pos + ins_len + new_len - 1 > len then
            return nil, "truncated svndiff window"
        end

        total = total + tview_len

        if max_bytes and total > max_bytes then
            return nil, "too_large"
        end

        local ins_end = pos + ins_len
        local new_pos = ins_end
        local pieces = {}
        local target_len = 0
        -- Flattened copy of `pieces`, rebuilt lazily -- only a
        -- copy-from-target needs random access into what's been written
        -- so far, and a window is at most 100 KB (svn's own
        -- SVN_DELTA_WINDOW_SIZE).
        local target_flat = ""

        while pos < ins_end do
            local byte = delta:byte(pos)
            local opcode = byte // 64
            local count = byte % 64
            local piece

            pos = pos + 1

            if count == 0 then
                count, pos = read_varint(delta, pos)
            end

            if opcode == 0 or opcode == 1 then
                local offset
                offset, pos = read_varint(delta, pos)

                if not count or not offset then
                    return nil, "truncated svndiff instruction"
                end

                if opcode == 0 then
                    if offset + count > sview_len then
                        return nil, "svndiff source copy outside its view"
                    end

                    piece = source:sub(sview_offset + offset + 1, sview_offset + offset + count)
                else
                    if #target_flat ~= target_len then
                        target_flat = table.concat(pieces)
                    end

                    if offset >= target_len then
                        return nil, "svndiff target copy outside the written target"
                    end

                    if offset + count <= target_len then
                        piece = target_flat:sub(offset + 1, offset + count)
                    else
                        -- An overlapping copy reads bytes it is itself
                        -- writing, so the copied run repeats with a period
                        -- of (written length - offset).
                        local run = target_flat:sub(offset + 1)
                        piece = run:rep(count // #run + 1):sub(1, count)
                    end
                end
            elseif opcode == 2 then
                if not count or new_pos + count > ins_end + new_len then
                    return nil, "svndiff new-data copy outside its section"
                end

                piece = delta:sub(new_pos, new_pos + count - 1)
                new_pos = new_pos + count
            else
                return nil, "invalid svndiff instruction"
            end

            pieces[#pieces + 1] = piece
            target_len = target_len + #piece
        end

        if target_len ~= tview_len then
            return nil, "svndiff window length mismatch"
        end

        windows[#windows + 1] = table.concat(pieces)
        pos = ins_end + new_len
    end

    return table.concat(windows)
end

-- ---------------------------------------------------------------------
-- Text or binary
-- ---------------------------------------------------------------------

-- Deliberately more lenient than Subversion's own svn_mime_type_is_binary
-- (libsvn_subr/validate.c), which treats anything outside "text/*" --
-- "application/xml" included -- as binary, and refuses to diff it. XML is
-- this app's main content, so XML and JSON types count as text here too.
-- svn's own two exceptions (image/x-xbitmap, image/x-xpixmap) are kept.
local TEXT_MIME_TYPES = {
    ["application/xml"] = true,
    ["application/json"] = true,
    ["application/javascript"] = true,
    ["application/x-javascript"] = true,
    ["application/ecmascript"] = true,
    ["image/x-xbitmap"] = true,
    ["image/x-xpixmap"] = true
}

-- nil (no svn:mime-type) counts as text: Subversion itself only sets
-- "application/octet-stream" on add/import when its content check says
-- binary, so an unset type normally means text -- is_binary_data below is
-- the safety net for the rest.
function M.is_text_mime_type(mime_type)
    if mime_type == nil then
        return true
    end

    local base = mime_type:lower():match("^%s*([^;%s]+)") or ""

    return base:match("^text/") ~= nil
        or TEXT_MIME_TYPES[base] == true
        or base:match("%+xml$") ~= nil
        or base:match("%+json$") ~= nil
end

-- A port of Subversion's own svn_io_is_binary_data (libsvn_subr/io.c),
-- the content check "svn add"/"svn import" use to decide whether to set
-- svn:mime-type=application/octet-stream: binary if the first 1024 bytes
-- contain a NUL, or if more than 85% of them fall outside 0x07-0x0D and
-- 0x20-0x7F. svn diff itself never looks at content -- only at
-- svn:mime-type -- so this is only consulted when that property is unset.
function M.is_binary_data(data)
    local len = math.min(#data, 1024)

    if len == 0 or (len == 3 and data:sub(1, 3) == "\239\187\191") then
        return false
    end

    local binary_count = 0

    for i = 1, len do
        local byte = data:byte(i)

        if byte == 0 then
            return true
        end

        if byte < 0x07 or (byte > 0x0D and byte < 0x20) or byte > 0x7F then
            binary_count = binary_count + 1
        end
    end

    return binary_count * 1000 // len > 850
end

-- ---------------------------------------------------------------------
-- Line diff (Myers' O(ND) algorithm, linear-space "middle snake" variant)
-- ---------------------------------------------------------------------

-- Appends one run to `ops`, merging it into the previous run when it has
-- the same kind ("=" unchanged, "-" removed, "+" added).
local function emit(ops, op, count)
    if count <= 0 then
        return
    end

    local last = ops[#ops]

    if last and last[1] == op then
        last[2] = last[2] + count
    else
        ops[#ops + 1] = { op, count }
    end
end

-- Finds the middle snake of a[ai+1..ai+n] vs b[bi+1..bi+m] -- the point
-- where a forward and a reverse shortest-edit search meet -- returning
-- the split point (x, y): "the first x elements of a against the first y
-- of b" and "the rest against the rest" can then be diffed independently.
-- Follows the same structure as Neil Fraser's diff-match-patch bisect
-- (itself Myers 1986, section 4b), with both V arrays shifted by one so
-- every index stays positive. Returns nil when no split is found or the
-- shared budget runs out (state.exhausted).
local function middle_snake(a, ai, n, b, bi, m, state)
    local max_d = (n + m + 1) // 2
    local v_offset = max_d + 1
    local v_size = 2 * max_d + 2
    local v1, v2 = {}, {}

    for i = 1, v_size do
        v1[i] = -1
        v2[i] = -1
    end

    v1[v_offset + 1] = 0
    v2[v_offset + 1] = 0

    local delta = n - m
    -- With an odd delta, the forward search is the one that can overlap
    -- the reverse search's previous step; with an even one, the reverse.
    local front = delta % 2 ~= 0
    local k1start, k1end, k2start, k2end = 0, 0, 0, 0

    for d = 0, max_d - 1 do
        state.budget = state.budget - (2 * d + 2)

        if state.budget < 0 then
            state.exhausted = true
            return nil
        end

        for k1 = -d + k1start, d - k1end, 2 do
            local k1_offset = v_offset + k1
            local x1

            if k1 == -d or (k1 ~= d and v1[k1_offset - 1] < v1[k1_offset + 1]) then
                x1 = v1[k1_offset + 1]
            else
                x1 = v1[k1_offset - 1] + 1
            end

            local y1 = x1 - k1

            while x1 < n and y1 < m and a[ai + x1 + 1] == b[bi + y1 + 1] do
                x1 = x1 + 1
                y1 = y1 + 1
            end

            v1[k1_offset] = x1

            if x1 > n then
                k1end = k1end + 2
            elseif y1 > m then
                k1start = k1start + 2
            elseif front then
                local k2_offset = v_offset + delta - k1

                if k2_offset >= 1 and k2_offset <= v_size and v2[k2_offset] ~= -1
                    and x1 >= n - v2[k2_offset] then
                    return x1, y1
                end
            end
        end

        for k2 = -d + k2start, d - k2end, 2 do
            local k2_offset = v_offset + k2
            local x2

            if k2 == -d or (k2 ~= d and v2[k2_offset - 1] < v2[k2_offset + 1]) then
                x2 = v2[k2_offset + 1]
            else
                x2 = v2[k2_offset - 1] + 1
            end

            local y2 = x2 - k2

            while x2 < n and y2 < m and a[ai + n - x2] == b[bi + m - y2] do
                x2 = x2 + 1
                y2 = y2 + 1
            end

            v2[k2_offset] = x2

            if x2 > n then
                k2end = k2end + 2
            elseif y2 > m then
                k2start = k2start + 2
            elseif not front then
                local k1_offset = v_offset + delta - k2

                if k1_offset >= 1 and k1_offset <= v_size and v1[k1_offset] ~= -1 then
                    local x1 = v1[k1_offset]

                    if x1 >= n - x2 then
                        return x1, x1 - (k1_offset - v_offset)
                    end
                end
            end
        end
    end

    return nil
end

-- Diffs a[ai+1..ai+n] against b[bi+1..bi+m], appending runs to `ops` in
-- order. Common prefix/suffix are peeled off first (cheap, and usually
-- most of a file), then the middle is split at its middle snake and each
-- half diffed in turn. A failed or degenerate split (one that would not
-- shrink the problem) falls back to "all removed, all added" for just
-- that region.
local function compare(a, ai, n, b, bi, m, ops, state)
    local prefix = 0

    while prefix < n and prefix < m and a[ai + prefix + 1] == b[bi + prefix + 1] do
        prefix = prefix + 1
    end

    emit(ops, "=", prefix)
    ai, n, bi, m = ai + prefix, n - prefix, bi + prefix, m - prefix

    local suffix = 0

    while suffix < n and suffix < m and a[ai + n - suffix] == b[bi + m - suffix] do
        suffix = suffix + 1
    end

    n, m = n - suffix, m - suffix

    if n == 0 or m == 0 then
        emit(ops, "-", n)
        emit(ops, "+", m)
    else
        local x, y

        if not state.exhausted then
            x, y = middle_snake(a, ai, n, b, bi, m, state)
        end

        if x and not ((x == 0 and y == 0) or (x == n and y == m)) then
            compare(a, ai, x, b, bi, y, ops, state)
            compare(a, ai + x, n - x, b, bi + y, m - y, ops, state)
        else
            emit(ops, "-", n)
            emit(ops, "+", m)
        end
    end

    emit(ops, "=", suffix)
end

-- Keeps only the elements of `values` that also occur somewhere in
-- `other`, plus each kept element's original index.
local function common_only(values, other)
    local present = {}

    for _, value in ipairs(other) do
        present[value] = true
    end

    local kept, original_index = {}, {}

    for i, value in ipairs(values) do
        if present[value] then
            kept[#kept + 1] = value
            original_index[#kept] = i
        end
    end

    return kept, original_index
end

-- Diffs two arrays of comparable values (line or token ids), returning
-- runs { {"=", count}, {"-", count}, {"+", count}, ... } plus whether the
-- budget ran out (the result is then still a valid diff, just possibly
-- not a minimal one).
--
-- Elements that occur only on one side can never be part of a common
-- subsequence, so -- like GNU diff's own discard_confusing_lines -- they
-- are set aside before the search and marked changed afterwards. The
-- result is the same minimal diff, but a rewritten region (all new lines)
-- costs nothing to search, instead of the search's worst case.
function M.diff_sequences(a, b, budget)
    local common_a, index_a = common_only(a, b)
    local common_b, index_b = common_only(b, a)
    local ops = {}
    local state = { budget = budget or LINE_DIFF_BUDGET, exhausted = false }

    compare(common_a, 0, #common_a, common_b, 0, #common_b, ops, state)

    -- Unchanged elements pair up in order on both sides, so walking both
    -- originals together -- removed before added within each gap --
    -- rebuilds the runs over the full arrays.
    local unchanged_a, unchanged_b = {}, {}
    local ai, bi = 0, 0

    for _, op in ipairs(ops) do
        if op[1] == "=" then
            for _ = 1, op[2] do
                ai, bi = ai + 1, bi + 1
                unchanged_a[index_a[ai]] = true
                unchanged_b[index_b[bi]] = true
            end
        elseif op[1] == "-" then
            ai = ai + op[2]
        else
            bi = bi + op[2]
        end
    end

    local result = {}
    local i, j = 1, 1

    while i <= #a or j <= #b do
        if i <= #a and not unchanged_a[i] then
            emit(result, "-", 1)
            i = i + 1
        elseif j <= #b and not unchanged_b[j] then
            emit(result, "+", 1)
            j = j + 1
        else
            emit(result, "=", 1)
            i, j = i + 1, j + 1
        end
    end

    return result, state.exhausted
end

-- Splits text into lines, without their "\n". The second result tells
-- whether the last line lacked a trailing newline.
local function split_lines(text)
    local lines = {}
    local pos = 1
    local len = #text

    while pos <= len do
        local newline = text:find("\n", pos, true)

        if not newline then
            lines[#lines + 1] = text:sub(pos)
            return lines, true
        end

        lines[#lines + 1] = text:sub(pos, newline - 1)
        pos = newline + 1
    end

    return lines, false
end

-- Words (letters, digits, and any non-ASCII byte -- so a UTF-8 sequence
-- is never split), runs of whitespace, and single punctuation characters
-- (so "<p>" against "<b>" marks just the letter).
local function tokenize(line)
    local tokens = {}
    local pos = 1
    local len = #line

    while pos <= len do
        local _, finish = line:find("^[%w\128-\255]+", pos)

        if not finish then
            _, finish = line:find("^%s+", pos)
        end

        finish = finish or pos
        tokens[#tokens + 1] = line:sub(pos, finish)
        pos = finish + 1
    end

    return tokens
end

local function plain_segments(text)
    return { { text = escape_html(text) } }
end

-- Splits a run of tokens into template segments, merging neighbours that
-- share the same "mark" state.
local function push_segment(segments, text, mark)
    local last = segments[#segments]

    if last and last.raw_mark == mark then
        last.raw = last.raw .. text
    else
        segments[#segments + 1] = { raw = text, raw_mark = mark }
    end
end

-- Escapes each segment for the template, after two cosmetic passes that
-- only move whitespace between marked and unmarked text (never change
-- what's shown): a whitespace-only unmarked segment between two marked
-- ones is folded in, so "much longer" replacing "long" reads as one
-- change rather than two words with a gap; and a mark's own leading and
-- trailing whitespace is moved out of it, so which of two equal spaces
-- the diff happened to pair up doesn't decide whether a mark visibly ends
-- in a space. A mark that is nothing but whitespace stays marked.
local function finish_segments(segments)
    local result = {}

    local function push(raw, mark)
        if raw == "" then
            return
        end

        local last = result[#result]

        if last and last.mark == mark then
            last.raw = last.raw .. raw
        else
            result[#result + 1] = { raw = raw, mark = mark }
        end
    end

    for i, segment in ipairs(segments) do
        local previous, following = segments[i - 1], segments[i + 1]

        if segment.raw_mark then
            local lead, core, trail = segment.raw:match("^(%s*)(.-)(%s*)$")

            if core == "" then
                push(segment.raw, true)
            else
                push(lead, false)
                push(core, true)
                push(trail, false)
            end
        elseif previous and previous.raw_mark and following and following.raw_mark
            and segment.raw:match("^%s+$") then
            push(segment.raw, true)
        else
            push(segment.raw, false)
        end
    end

    for _, segment in ipairs(result) do
        segment.text = escape_html(segment.raw)
        segment.mark = segment.mark or nil
        segment.raw = nil
    end

    return result
end

-- Within-line highlighting for one removed/added line pair: returns the
-- two lines' segment lists, or nil when the pair is too long, too
-- different (see TOKEN_DIFF_MIN_COMMON) or too costly to diff.
local function token_segments(old_text, new_text)
    if #old_text > TOKEN_DIFF_MAX_LINE or #new_text > TOKEN_DIFF_MAX_LINE then
        return nil
    end

    local old_tokens, new_tokens = tokenize(old_text), tokenize(new_text)
    local ids, next_id = {}, 0
    local a, b = {}, {}

    for i, token in ipairs(old_tokens) do
        if not ids[token] then
            next_id = next_id + 1
            ids[token] = next_id
        end

        a[i] = ids[token]
    end

    for i, token in ipairs(new_tokens) do
        if not ids[token] then
            next_id = next_id + 1
            ids[token] = next_id
        end

        b[i] = ids[token]
    end

    local ops, exhausted = M.diff_sequences(a, b, TOKEN_DIFF_BUDGET)

    if exhausted then
        return nil
    end

    local old_segments, new_segments = {}, {}
    local ai, bi = 0, 0
    local common = 0

    for _, op in ipairs(ops) do
        for _ = 1, op[2] do
            if op[1] == "=" then
                ai, bi = ai + 1, bi + 1
                common = common + #old_tokens[ai]
                push_segment(old_segments, old_tokens[ai], false)
                push_segment(new_segments, new_tokens[bi], false)
            elseif op[1] == "-" then
                ai = ai + 1
                push_segment(old_segments, old_tokens[ai], true)
            else
                bi = bi + 1
                push_segment(new_segments, new_tokens[bi], true)
            end
        end
    end

    if common < TOKEN_DIFF_MIN_COMMON * math.max(#old_text, #new_text) then
        return nil
    end

    return finish_segments(old_segments), finish_segments(new_segments)
end

-- A line as shown: any trailing "\r" (CRLF content) is dropped from the
-- displayed text, though it still counts when comparing lines.
local function display_text(line)
    return (line:gsub("\r$", ""))
end

local function line_entry(kind, old_no, new_no, line, no_newline)
    return {
        kind = kind,
        old_no = old_no,
        new_no = new_no,
        raw = display_text(line),
        no_newline = no_newline or nil
    }
end

-- Diffs two texts line by line, returning every line (unchanged ones
-- included) as a template-ready entry -- kind ("context"/"removed"/
-- "added"), old_no/new_no, HTML-escaped segments -- plus the added and
-- removed line counts and whether the diff is approximate. Within each
-- changed region, removed lines come first, then added ones, and the
-- k-th removed line is paired with the k-th added one for within-line
-- highlighting.
function M.diff_lines(old_text, new_text)
    local old_lines, old_no_newline = split_lines(old_text)
    local new_lines, new_no_newline = split_lines(new_text)
    local ids, next_id = {}, 0

    -- A last line without its "\n" must not compare equal to the same
    -- text with one, or adding/removing the final newline would show no
    -- change at all -- so its key gets a "\n" appended (never otherwise
    -- part of a line, so the key can't collide with a real one).
    local function to_ids(lines, no_newline)
        local out = {}

        for i, line in ipairs(lines) do
            local key = (no_newline and i == #lines) and line .. "\n" or line

            if not ids[key] then
                next_id = next_id + 1
                ids[key] = next_id
            end

            out[i] = ids[key]
        end

        return out
    end

    local ops, approximate = M.diff_sequences(
        to_ids(old_lines, old_no_newline), to_ids(new_lines, new_no_newline)
    )

    local entries = {}
    local added_count, removed_count = 0, 0
    local highlighted_bytes = 0
    local ai, bi = 0, 0
    local i = 1

    while i <= #ops do
        if ops[i][1] == "=" then
            for _ = 1, ops[i][2] do
                ai, bi = ai + 1, bi + 1
                entries[#entries + 1] = line_entry(
                    "context", ai, bi, new_lines[bi], new_no_newline and bi == #new_lines
                )
            end

            i = i + 1
        else
            local removed, added = {}, {}

            while i <= #ops and ops[i][1] ~= "=" do
                for _ = 1, ops[i][2] do
                    if ops[i][1] == "-" then
                        ai = ai + 1
                        removed[#removed + 1] = line_entry(
                            "removed", ai, nil, old_lines[ai], old_no_newline and ai == #old_lines
                        )
                    else
                        bi = bi + 1
                        added[#added + 1] = line_entry(
                            "added", nil, bi, new_lines[bi], new_no_newline and bi == #new_lines
                        )
                    end
                end

                i = i + 1
            end

            for k = 1, math.min(#removed, #added) do
                highlighted_bytes = highlighted_bytes + #removed[k].raw + #added[k].raw

                if highlighted_bytes > TOKEN_DIFF_TOTAL_BYTES then
                    break
                end

                removed[k].segments, added[k].segments = token_segments(removed[k].raw, added[k].raw)
            end

            for _, entry in ipairs(removed) do
                entries[#entries + 1] = entry
            end

            for _, entry in ipairs(added) do
                entries[#entries + 1] = entry
            end

            removed_count = removed_count + #removed
            added_count = added_count + #added
        end
    end

    for _, entry in ipairs(entries) do
        entry.segments = entry.segments or plain_segments(entry.raw)
        entry.raw = nil
    end

    return entries, added_count, removed_count, approximate
end

-- Groups diff_lines' entries into unified-diff hunks: every changed line
-- plus up to `context` unchanged lines on either side, with neighbouring
-- changes merged into one hunk when the unchanged gap between them is no
-- longer than both contexts together. Each hunk carries its own
-- "@@ -a,b +c,d @@" header.
function M.build_hunks(entries, context)
    context = context or DIFF_CONTEXT_LINES

    local hunks = {}
    local n = #entries
    local i = 1

    while i <= n do
        if entries[i].kind == "context" then
            i = i + 1
        else
            local first = math.max(1, i - context)
            local last_change = i
            local j = i + 1

            while j <= n do
                if entries[j].kind ~= "context" then
                    last_change = j
                elseif j - last_change > 2 * context then
                    break
                end

                j = j + 1
            end

            local last = math.min(n, last_change + context)
            local lines = {}
            local old_start, new_start, old_count, new_count = nil, nil, 0, 0

            for k = first, last do
                local entry = entries[k]

                lines[#lines + 1] = entry

                if entry.old_no then
                    old_start = old_start or entry.old_no
                    old_count = old_count + 1
                end

                if entry.new_no then
                    new_start = new_start or entry.new_no
                    new_count = new_count + 1
                end
            end

            -- A side with no lines in this hunk (a pure insertion or
            -- deletion) is numbered after the line just before it, the
            -- same convention "diff -u" uses -- 0 at the very top.
            local function preceding(field)
                for k = first - 1, 1, -1 do
                    if entries[k][field] then
                        return entries[k][field]
                    end
                end

                return 0
            end

            hunks[#hunks + 1] = {
                header = string.format(
                    "@@ -%d,%d +%d,%d @@",
                    old_start or preceding("old_no"), old_count,
                    new_start or preceding("new_no"), new_count
                ),
                lines = lines
            }

            i = last + 1
        end
    end

    return hunks
end

-- ---------------------------------------------------------------------
-- file-revs-report parsing
-- ---------------------------------------------------------------------

-- Copies a property table, applying one <S:file-rev>'s own changes on
-- top. Each file-rev's <S:set-prop>/<S:remove-prop> list is a delta
-- against the previous file-rev (the first one's against no properties
-- at all), so folding them in order gives each revision's full set.
local function apply_prop_changes(props, file_rev)
    local result = {}

    for name, value in pairs(props or {}) do
        result[name] = value
    end

    for name in pairs(file_rev.removed) do
        result[name] = nil
    end

    for name, value in pairs(file_rev.set) do
        result[name] = value
    end

    return result
end

-- A streaming parser for the file-revs-report response: feed() each
-- response bucket in turn, then finish(). Element names arrive with their
-- literal "S:" prefix, the same unconfigured way lxp.new is used
-- elsewhere in this app (no namespace-processing mode) -- which also
-- means mod_dav_svn's error document (<D:error> with an
-- <m:human-readable> message) parses fine and is picked up too.
--
-- Each file-rev's <S:txdelta> is only kept while it could still be shown:
-- once the properties seen so far say the content isn't text, or the
-- base64 grows past max_delta_chars, the rest is dropped as it streams in
-- (the file-rev is marked "binary" or "too_large") rather than buffered.
-- Properties always precede their file-rev's own <S:txdelta>
-- (mod_dav_svn's file_rev_handler emits them first).
function M.new_file_revs_parser(max_delta_chars)
    local result = { revs = {} }
    local current = nil
    local previous_props = {}
    local capture = nil
    local buffer, buffer_len = nil, 0

    local function start_capture(kind, extra)
        capture = extra or {}
        capture.kind = kind
        buffer, buffer_len = {}, 0
    end

    local parser = lxp.new({
        StartElement = function(_, name, attr)
            if name == "S:file-rev" then
                current = { path = attr.path or "", rev = attr.rev or "", revprops = {}, set = {}, removed = {} }
                result.revs[#result.revs + 1] = current
            elseif current and name == "S:rev-prop" and attr.name then
                start_capture("revprop", { name = attr.name, base64 = attr.encoding == "base64" })
            elseif current and name == "S:set-prop" and attr.name then
                start_capture("prop", { name = attr.name, base64 = attr.encoding == "base64" })
            elseif current and name == "S:remove-prop" and attr.name then
                current.removed[attr.name] = true
            elseif current and name == "S:txdelta" then
                current.props = apply_prop_changes(previous_props, current)

                if not M.is_text_mime_type(current.props["svn:mime-type"]) then
                    current.delta_skipped = "binary"
                else
                    start_capture("txdelta")
                end
            elseif name:match(":human%-readable$") then
                start_capture("error")
            end
        end,

        CharacterData = function(_, text)
            if not capture then
                return
            end

            buffer_len = buffer_len + #text

            if capture.kind == "txdelta" and max_delta_chars and buffer_len > max_delta_chars then
                current.delta_skipped = "too_large"
                capture = nil
                buffer = nil
                return
            end

            buffer[#buffer + 1] = text
        end,

        EndElement = function(_, name)
            if capture then
                local text = table.concat(buffer)

                if capture.kind == "revprop" and name == "S:rev-prop" then
                    current.revprops[capture.name] = capture.base64 and M.base64_decode(text) or text
                elseif capture.kind == "prop" and name == "S:set-prop" then
                    current.set[capture.name] = capture.base64 and M.base64_decode(text) or text
                elseif capture.kind == "txdelta" and name == "S:txdelta" then
                    current.delta = text
                elseif capture.kind == "error" then
                    result.error_message = text:match("^%s*(.-)%s*$")
                end

                capture, buffer = nil, nil
                return
            end

            if name == "S:file-rev" and current then
                current.props = current.props or apply_prop_changes(previous_props, current)
                previous_props = current.props
                current = nil
            end
        end
    })

    local object = { result = result }

    function object.feed(chunk)
        return parser:parse(chunk)
    end

    -- Returns the result table, plus a parse error message when the
    -- document was malformed or truncated (mod_dav_svn can fail mid-way
    -- through a 200 response). lxp's close() can raise rather than return
    -- on a malformed document, hence the pcall.
    function object.finish()
        local ok, err = parser:parse()
        local closed, close_err = pcall(function() parser:close() end)

        if not ok then
            return result, tostring(err)
        end

        if not closed then
            return result, tostring(close_err)
        end

        return result, nil
    end

    return object
end

-- ---------------------------------------------------------------------
-- Template context
-- ---------------------------------------------------------------------

local function basename(path)
    return path:match("([^/]+)/*$") or path
end

local PROP_STATUS = {
    added = { label = "added", icon = "plus" },
    removed = { label = "removed", icon = "minus" },
    modified = { label = "modified", icon = "pen" }
}

-- Property values are diffed line by line like content (svn:externals,
-- svn:mergeinfo and many custom properties are multi-line), with every
-- line kept -- no hunks; values are short. A value that isn't valid UTF-8,
-- or holds control characters other than tab/newline/CR (what makes
-- mod_dav_svn base64-encode a value in the first place -- confirmed
-- against a real server), is summarized instead of shown.
local function prop_value_text(value)
    if value == nil then
        return ""
    end

    if not utf8.len(value) or value:find("[%z\1-\8\11\12\14-\31\127]") then
        return string.format("(binary value, %d bytes)", #value)
    end

    return value
end

local function build_prop_changes(old_props, new_props)
    local names = {}
    local seen = {}

    for _, props in ipairs({ old_props, new_props }) do
        for name in pairs(props) do
            if not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end

    table.sort(names)

    local changes = {}

    for _, name in ipairs(names) do
        local old_value, new_value = old_props[name], new_props[name]

        if old_value ~= new_value then
            local status = (old_value == nil and "added") or (new_value == nil and "removed") or "modified"
            local lines = M.diff_lines(prop_value_text(old_value), prop_value_text(new_value))

            -- Property values normally have no trailing newline at all,
            -- so the content diff's "no newline at end of file" marker
            -- would only be noise here.
            for _, line in ipairs(lines) do
                line.no_newline = nil
            end

            changes[#changes + 1] = {
                name = escape_html(name),
                status = status,
                status_label = PROP_STATUS[status].label,
                icon = PROP_STATUS[status].icon,
                lines = lines
            }
        end
    end

    return changes
end

-- Decides what the content part of the diff shows, returning a table to
-- merge into the template context: exactly one of content_unchanged,
-- content_binary, content_too_large, content_not_utf8 or content_error,
-- or else hunks (plus the line counts and the "approximate" flag).
local function build_content(old_rev, new_rev, old_props, new_props, max_bytes)
    if old_rev and not new_rev.delta and not new_rev.delta_skipped then
        return { content_unchanged = true }
    end

    local old_mime, new_mime = old_props["svn:mime-type"], new_props["svn:mime-type"]

    if not M.is_text_mime_type(old_mime) or not M.is_text_mime_type(new_mime) then
        local mime = M.is_text_mime_type(new_mime) and old_mime or new_mime
        return { content_binary = { mime_type = escape_html(mime) } }
    end

    if (old_rev and old_rev.delta_skipped == "too_large") or new_rev.delta_skipped == "too_large" then
        return { content_too_large = { limit = max_bytes } }
    end

    -- No <S:txdelta> at all on a file-rev means "no difference from the
    -- previous one" -- for the first file-rev, from the empty file, i.e.
    -- the file was empty then.
    local old_text = ""

    if old_rev and old_rev.delta then
        local text, err = M.svndiff_apply(M.base64_decode(old_rev.delta), "", max_bytes)

        if not text then
            return err == "too_large" and { content_too_large = { limit = max_bytes } }
                or { content_error = { message = escape_html(err) } }
        end

        old_text = text
    end

    local new_text = ""

    if new_rev.delta then
        local text, err = M.svndiff_apply(M.base64_decode(new_rev.delta), old_text, max_bytes)

        if not text then
            return err == "too_large" and { content_too_large = { limit = max_bytes } }
                or { content_error = { message = escape_html(err) } }
        end

        new_text = text
    end

    if (old_mime == nil and M.is_binary_data(old_text)) or (new_mime == nil and M.is_binary_data(new_text)) then
        return { content_binary = { detected = true } }
    end

    if not utf8.len(old_text) or not utf8.len(new_text) then
        return { content_not_utf8 = true }
    end

    if old_text == new_text then
        return { content_unchanged = true }
    end

    local entries, added_count, removed_count, approximate = M.diff_lines(old_text, new_text)

    return {
        hunks = M.build_hunks(entries),
        stats = { added = added_count, removed = removed_count },
        approximate = approximate or nil
    }
end

-- Builds diff.mustache's whole context from a finished parse. opts:
--   end_revision  the "N" this diff was requested for (string)
--   max_bytes     SVN_DIFF_MAX_BYTES, resolved
--   href_for      function(path, rev) -> already-escaped href or nil, for
--                 the old/new path links in the summary line
--   parse_error   finish()'s own error, if any
--   date_lang     SVN_LOG_DATE_LANG, for the revision tooltips' dates
function M.build_context(parsed, opts)
    local revs = parsed.revs
    local href_for = opts.href_for or function() return nil end

    -- An error document, or a response cut short (mod_dav_svn can fail
    -- part-way through a 200 response), leaves nothing trustworthy to
    -- show but the reason.
    if #revs == 0 or opts.parse_error then
        local message = parsed.error_message
            or (opts.parse_error and "Unexpected response from the server: " .. opts.parse_error)
            or "No history found for this file."

        return { error = { message = escape_html(message) } }
    end

    local old_rev, new_rev

    if #revs >= 2 then
        old_rev, new_rev = revs[#revs - 1], revs[#revs]
    elseif opts.end_revision and revs[1].rev ~= opts.end_revision then
        -- The file didn't change in N at all (only reachable by a
        -- hand-made URL -- the History dialog never offers a diff then).
        old_rev, new_rev = revs[1], nil
    else
        new_rev = revs[1]
    end

    -- Each side's own commit -- for the old side, the one that last
    -- changed the file before N (r3 for a file untouched from r3 to r10,
    -- not r10) -- with its author, date and the first line of its log
    -- message, all of which file-revs-report already carries as
    -- rev-props (diff.mustache puts them in a tooltip on the revision
    -- badge). nil, not "", when absent, so diff.mustache can test each
    -- one directly.
    local function side(file_rev)
        local revprops = file_rev.revprops or {}
        local log = revprops["svn:log"] or ""
        local message = log:match("^%s*([^\n]-)%s*\n") or log:match("^%s*(.-)%s*$")

        return {
            path = escape_html(file_rev.path),
            rev = escape_html(file_rev.rev),
            href = href_for(file_rev.path, file_rev.rev),
            author = revprops["svn:author"] and escape_html(revprops["svn:author"]) or nil,
            date = revprops["svn:date"] and escape_html(revprops["svn:date"]) or nil,
            message = message ~= "" and escape_html(message) or nil
        }
    end

    local context = {
        label = escape_html(basename((new_rev or old_rev).path)),
        summary = true,
        new = side(new_rev or old_rev),
        date_lang = opts.date_lang and escape_html(opts.date_lang) or nil
    }

    if not new_rev then
        context.unchanged = true
        return context
    end

    if old_rev then
        context.old = side(old_rev)
        -- The path is only shown once when both sides share it.
        context.renamed = old_rev.path ~= new_rev.path or nil
    else
        context.added = true
    end

    local old_props = old_rev and old_rev.props or {}
    local new_props = new_rev.props or {}
    local prop_changes = build_prop_changes(old_props, new_props)

    if #prop_changes > 0 then
        context.props = prop_changes
    end

    local content = build_content(old_rev, new_rev, old_props, new_props, opts.max_bytes)

    for key, value in pairs(content) do
        context[key] = value
    end

    -- has_hunks lets diff.mustache wrap every hunk in one <table>
    -- (lustache has no "list is non-empty" test of its own short of
    -- iterating it).
    if content.hunks and #content.hunks == 0 then
        context.hunks = nil
        context.content_unchanged = true
    elseif content.hunks then
        context.has_hunks = true
    end

    return context
end

return M
