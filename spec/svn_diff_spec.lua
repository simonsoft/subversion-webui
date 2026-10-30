-- Exercises mod-lua/svn-diff.lua's own pure functions directly: it's a
-- plain module returning a table (no request_rec, no lustache), dofile()d
-- the same way svn-log.lua itself loads it. The request/response plumbing
-- around it -- input_filter's file-revs-report body, output_filter's diff
-- branch and diff.mustache -- is covered in svn_log_spec.lua instead.
--
-- Every file-revs-report response below was captured from a real
-- mod_dav_svn 1.14 server (Apache 2.4, Ubuntu 24.04) against a scratch
-- repository built for the purpose, so the svndiff deltas are genuine
-- server output, not hand-assembled approximations of it.
local function spec_dir()
    local source = debug.getinfo(1, "S").source:match("^@(.*)$")
    return source:match("(.*/)") or "./"
end

local ROOT = spec_dir() .. "../"

local svn_diff = dofile(ROOT .. "mod-lua/svn-diff.lua")

-- r1: "line one\nline two\nline three\n"; r2 changes line two and appends
-- "line four". Neither revision has any versioned properties.
local README_R2 = [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/readme.txt" rev="1">
<S:rev-prop name="svn:log">r1 initial</S:rev-prop>
<S:rev-prop name="svn:author">root</S:rev-prop>
<S:rev-prop name="svn:date">2026-10-29T23:35:08.751209Z</S:rev-prop>
<S:txdelta>U1ZOAAAAHQEdnWxpbmUgb25lCmxpbmUgdHdvCmxpbmUgdGhyZWUK</S:txdelta></S:file-rev>
<S:file-rev path="/trunk/readme.txt" rev="2">
<S:rev-prop name="svn:date">2026-10-29T23:35:08.786192Z</S:rev-prop>
<S:rev-prop name="svn:log">r2 text + prop</S:rev-prop>
<S:rev-prop name="svn:author">root</S:rev-prop>
<S:txdelta>U1ZOAAAdLQMfDgCfMiBjaGFuZ2VkCmxpbmUgdGhyZWUKbGluZSBmb3VyCg==</S:txdelta></S:file-rev>
</S:file-revs-report>
]]

-- A property-only change: r3 sets cms:status from "draft" to "released",
-- so the second file-rev carries no <S:txdelta> at all.
local DOC_R3 = [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/doc.xml" rev="2">
<S:rev-prop name="svn:author">root</S:rev-prop>
<S:set-prop name="svn:mime-type">application/xml</S:set-prop>
<S:set-prop name="cms:status">draft</S:set-prop>
<S:txdelta>U1ZOAAAARwJHgEc8P3htbCB2ZXJzaW9uPSIxLjAiPz4KPGRvYz4KICA8cD5IZWxsbyB0aGVyZTwvcD4KICA8cD5Xb3JsZDwvcD4KPC9kb2M+Cg==</S:txdelta></S:file-rev>
<S:file-rev path="/trunk/doc.xml" rev="3">
<S:rev-prop name="svn:author">root</S:rev-prop>
<S:set-prop name="cms:status">released</S:set-prop>
</S:file-rev>
</S:file-revs-report>
]]

-- r11 rewrites a paragraph, drops the file's final newline, removes
-- cms:status and adds a two-line cms:notes.
local DOC_R11 = [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/doc.xml" rev="3">
<S:set-prop name="svn:mime-type">application/xml</S:set-prop>
<S:set-prop name="cms:status">released</S:set-prop>
<S:txdelta>U1ZOAAAARwJHgEc8P3htbCB2ZXJzaW9uPSIxLjAiPz4KPGRvYz4KICA8cD5IZWxsbyB0aGVyZTwvcD4KICA8cD5Xb3JsZDwvcD4KPC9kb2M+Cg==</S:txdelta></S:file-rev>
<S:file-rev path="/trunk/doc.xml" rev="11">
<S:remove-prop name="cms:status"/>
<S:set-prop name="cms:notes">first line
second line</S:set-prop>
<S:txdelta>U1ZOAABHgQQEWCwAgFgsIHRoaXMgaXMgYSBsb25nIHBhcmFncmFwaCBhYm91dCB0aGUgQ01TIGFuZCBpdHMgaGlzdG9yeSB2aWV3LjwvcD4KICA8cD5Xb3JsZDwvcD4KPC9kb2M+</S:txdelta></S:file-rev>
</S:file-revs-report>
]]

-- r4 copies /trunk to /branches/b1 and modifies the copy's readme.txt in
-- the same commit: the old side is followed back through the copy to
-- /trunk/readme.txt as of r2 (its last change before r4).
local BRANCH_R4 = [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/readme.txt" rev="2">
<S:txdelta>U1ZOAAAALQEtrWxpbmUgb25lCmxpbmUgMiBjaGFuZ2VkCmxpbmUgdGhyZWUKbGluZSBmb3VyCg==</S:txdelta></S:file-rev>
<S:file-rev path="/branches/b1/readme.txt" rev="4">
<S:txdelta>U1ZOAAAtKgULCQCLFhdicmFuY2ggZWRpdA==</S:txdelta></S:file-rev>
</S:file-revs-report>
]]

-- r7 adds new.txt without history: a single file-rev, delta against
-- nothing.
local ADDED_R7 = [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/new.txt" rev="7">
<S:txdelta>U1ZOAAAACgEKimJyYW5kIG5ldwo=</S:txdelta></S:file-rev>
</S:file-revs-report>
]]

-- r10 changes a Latin-1 encoded file ("caf\xe9 one" -> "caf\xe9 two").
local LATIN1_R10 = [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/latin1.txt" rev="9">
<S:txdelta>U1ZOAAAACQEJiWNhZukgb25lCg==</S:txdelta></S:file-rev>
<S:file-rev path="/trunk/latin1.txt" rev="10">
<S:txdelta>U1ZOAAAJCQMEBQCEdHdvCg==</S:txdelta></S:file-rev>
</S:file-revs-report>
]]

-- r13 adds a property whose value holds control characters, which
-- mod_dav_svn sends base64-encoded (with a trailing line break).
local BINARY_PROP_R13 = [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/README.txt" rev="5">
<S:txdelta>U1ZOAAAANwE3t2xpbmUgb25lCmxpbmUgMiBjaGFuZ2VkCmxpbmUgdGhyZWUKbGluZSBmb3VyCmxpbmUgZml2ZQo=</S:txdelta></S:file-rev>
<S:file-rev path="/trunk/README.txt" rev="13">
<S:set-prop name="cms:blob" encoding="base64">YmluAQJ2YWx1ZQ==
</S:set-prop>
</S:file-rev>
</S:file-revs-report>
]]

-- The error document mod_dav_svn sends (status 500, still text/xml) for
-- a file-revs-report against a directory.
local ERROR_DOC = [[<?xml version="1.0" encoding="utf-8"?>
<D:error xmlns:D="DAV:" xmlns:m="http://apache.org/dav/xmlns" xmlns:C="svn:">
<C:error/>
<m:human-readable errcode="160017">
'/trunk' is not a file in revision 2
</m:human-readable>
</D:error>
]]

-- Hand-built, unlike the captures above: a binary file whose second
-- revision's delta must never even be kept.
local BINARY_FILE = [[<?xml version="1.0" encoding="utf-8"?>
<S:file-revs-report xmlns:S="svn:" xmlns:D="DAV:">
<S:file-rev path="/trunk/image.png" rev="1">
<S:set-prop name="svn:mime-type">application/octet-stream</S:set-prop>
<S:txdelta>U1ZOAAAAAwEDg2FiYw==</S:txdelta></S:file-rev>
<S:file-rev path="/trunk/image.png" rev="6">
<S:txdelta>U1ZOAAAAAwEDg3h5eg==</S:txdelta></S:file-rev>
</S:file-revs-report>
]]

-- Feeds `xml` to a fresh parser in `chunk_size`-byte pieces (default:
-- deliberately small and odd, so element and base64 boundaries land
-- mid-chunk), then builds the template context.
local function render_context(xml, opts, chunk_size)
    opts = opts or {}
    chunk_size = chunk_size or 37

    local max_bytes = opts.max_bytes or svn_diff.DEFAULT_MAX_BYTES
    local parser = svn_diff.new_file_revs_parser(max_bytes * 4 // 3 + 4096)

    for i = 1, #xml, chunk_size do
        parser.feed(xml:sub(i, i + chunk_size - 1))
    end

    local parsed, parse_error = parser.finish()

    return svn_diff.build_context(parsed, {
        end_revision = opts.end_revision,
        max_bytes = max_bytes,
        parse_error = parse_error,
        href_for = opts.href_for
    }), parsed
end

-- Flattens a line entry's segments back into "text with [marked] parts".
local function line_text(entry)
    local parts = {}

    for _, segment in ipairs(entry.segments) do
        parts[#parts + 1] = segment.mark and ("[" .. segment.text .. "]") or segment.text
    end

    return table.concat(parts)
end

-- One "kind:old_no:new_no:text" string per line, for compact assertions.
local function describe_lines(lines)
    local out = {}

    for _, entry in ipairs(lines) do
        out[#out + 1] = string.format(
            "%s:%s:%s:%s", entry.kind, tostring(entry.old_no or ""), tostring(entry.new_no or ""), line_text(entry)
        )
    end

    return out
end

describe("svn-diff base64_decode", function()
    it("decodes every padding variant", function()
        assert.are.equal("abc", svn_diff.base64_decode("YWJj"))
        assert.are.equal("ab", svn_diff.base64_decode("YWI="))
        assert.are.equal("a", svn_diff.base64_decode("YQ=="))
        assert.are.equal("", svn_diff.base64_decode(""))
    end)

    it("ignores the line breaks mod_dav_svn wraps long base64 runs with", function()
        assert.are.equal("hello world", svn_diff.base64_decode("aGVsbG8g\nd29y\r\nbGQ=\n"))
    end)

    it("round-trips binary bytes, across its own internal batch boundary", function()
        local bytes = {}

        for i = 0, 9999 do
            bytes[#bytes + 1] = string.char(i % 256)
        end

        local original = table.concat(bytes)
        -- Encoded by hand here, independently of the decoder under test.
        local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        local encoded = original:gsub("..?.?", function(chunk)
            local a, b, c = chunk:byte(1, 3)
            local n = a * 65536 + (b or 0) * 256 + (c or 0)
            local chars = {}

            for shift = 3, 0, -1 do
                chars[#chars + 1] = alphabet:sub((n // 64 ^ shift) % 64 + 1, (n // 64 ^ shift) % 64 + 1)
            end

            local text = table.concat(chars)

            return #chunk == 3 and text or text:sub(1, #chunk + 1) .. string.rep("=", 3 - #chunk)
        end)

        assert.are.equal(original, svn_diff.base64_decode(encoded))
    end)
end)

describe("svn-diff svndiff_apply", function()
    it("applies a real new-data-only delta against the empty file", function()
        local delta = svn_diff.base64_decode("U1ZOAAAAHQEdnWxpbmUgb25lCmxpbmUgdHdvCmxpbmUgdGhyZWUK")

        assert.are.equal("line one\nline two\nline three\n", svn_diff.svndiff_apply(delta, ""))
    end)

    it("applies a real delta mixing source copies and new data", function()
        local delta = svn_diff.base64_decode("U1ZOAAAdLQMfDgCfMiBjaGFuZ2VkCmxpbmUgdGhyZWUKbGluZSBmb3VyCg==")

        assert.are.equal(
            "line one\nline 2 changed\nline three\nline four\n",
            svn_diff.svndiff_apply(delta, "line one\nline two\nline three\n")
        )
    end)

    it("expands an overlapping copy-from-target into a repeating run", function()
        -- One window: target length 8, two instructions (new data "ab",
        -- then copy 6 bytes from target offset 0), 2 bytes of new data.
        local delta = "SVN\0" .. "\0\0\8\3\2" .. "\130" .. "\70\0" .. "ab"

        assert.are.equal("abababab", svn_diff.svndiff_apply(delta, ""))
    end)

    it("reads a varint-encoded length when an instruction's own six bits are zero", function()
        -- New data of length 200: the instruction byte is 0x80 (new data,
        -- length 0), then 200 as a varint (0x81 0x48).
        local data = string.rep("x", 200)
        local delta = "SVN\0" .. "\0\0\129\72\3\129\72" .. "\128\129\72" .. data

        assert.are.equal(data, svn_diff.svndiff_apply(delta, ""))
    end)

    it("refuses compressed svndiff versions, which this app never asks for", function()
        local text, err = svn_diff.svndiff_apply("SVN\1\0\0\0\0\0", "")

        assert.is_nil(text)
        assert.truthy(err:find("version 1", 1, true))
    end)

    it("reports a truncated window rather than reading past the end", function()
        local text, err = svn_diff.svndiff_apply("SVN\0\0\0\10\1\10\138abc", "")

        assert.is_nil(text)
        assert.truthy(err:find("truncated", 1, true))
    end)

    it("refuses a source copy reaching outside its own source view", function()
        -- Source view is 2 bytes, but the copy asks for 3.
        local text = svn_diff.svndiff_apply("SVN\0" .. "\0\2\3\2\0" .. "\3\0", "abcdef")

        assert.is_nil(text)
    end)

    it("stops with \"too_large\" once the target would pass max_bytes", function()
        local delta = svn_diff.base64_decode("U1ZOAAAAHQEdnWxpbmUgb25lCmxpbmUgdHdvCmxpbmUgdGhyZWUK")
        local text, err = svn_diff.svndiff_apply(delta, "", 10)

        assert.is_nil(text)
        assert.are.equal("too_large", err)
    end)
end)

describe("svn-diff is_text_mime_type", function()
    it("treats an unset svn:mime-type as text", function()
        assert.is_true(svn_diff.is_text_mime_type(nil))
    end)

    it("accepts text/*, XML and JSON types, with or without parameters", function()
        assert.is_true(svn_diff.is_text_mime_type("text/plain"))
        assert.is_true(svn_diff.is_text_mime_type("text/xml; charset=utf-8"))
        assert.is_true(svn_diff.is_text_mime_type("application/xml"))
        assert.is_true(svn_diff.is_text_mime_type("application/dita+xml"))
        assert.is_true(svn_diff.is_text_mime_type("image/svg+xml"))
        assert.is_true(svn_diff.is_text_mime_type("application/json"))
        assert.is_true(svn_diff.is_text_mime_type("Application/XML"))
    end)

    it("keeps Subversion's own two image exceptions", function()
        assert.is_true(svn_diff.is_text_mime_type("image/x-xbitmap"))
        assert.is_true(svn_diff.is_text_mime_type("image/x-xpixmap"))
    end)

    it("rejects everything else", function()
        assert.is_false(svn_diff.is_text_mime_type("application/octet-stream"))
        assert.is_false(svn_diff.is_text_mime_type("image/png"))
        assert.is_false(svn_diff.is_text_mime_type("application/pdf"))
        assert.is_false(svn_diff.is_text_mime_type("application/xml-dtd-ish"))
    end)
end)

describe("svn-diff is_binary_data", function()
    it("calls anything with a NUL in its first 1024 bytes binary", function()
        assert.is_true(svn_diff.is_binary_data("abc\0def"))
    end)

    it("ignores a NUL past the first 1024 bytes, as Subversion does", function()
        assert.is_false(svn_diff.is_binary_data(string.rep("a", 1024) .. "\0"))
    end)

    it("accepts plain and UTF-8 text", function()
        assert.is_false(svn_diff.is_binary_data("hello\n\tworld\r\n"))
        assert.is_false(svn_diff.is_binary_data("caf\195\169 \226\130\172 \240\159\152\128 plain words around them"))
        assert.is_false(svn_diff.is_binary_data(""))
        assert.is_false(svn_diff.is_binary_data("\239\187\191"))
    end)

    it("calls content binary once more than 85% of its bytes are outside the text ranges", function()
        assert.is_true(svn_diff.is_binary_data(string.rep("\200", 90) .. string.rep("a", 10)))
        assert.is_false(svn_diff.is_binary_data(string.rep("\200", 80) .. string.rep("a", 20)))
    end)
end)

describe("svn-diff diff_sequences", function()
    local function render_ops(ops)
        local out = {}

        for _, op in ipairs(ops) do
            out[#out + 1] = op[1] .. op[2]
        end

        return table.concat(out, " ")
    end

    it("finds a minimal diff", function()
        -- The classic Myers example: ABCABBA -> CBABAC, distance 5.
        local a = { "A", "B", "C", "A", "B", "B", "A" }
        local b = { "C", "B", "A", "B", "A", "C" }
        local ops = svn_diff.diff_sequences(a, b)
        local changed = 0

        for _, op in ipairs(ops) do
            if op[1] ~= "=" then
                changed = changed + op[2]
            end
        end

        assert.are.equal(5, changed)
    end)

    it("handles identical, empty and one-sided inputs", function()
        assert.are.equal("=3", render_ops(svn_diff.diff_sequences({ 1, 2, 3 }, { 1, 2, 3 })))
        assert.are.equal("", render_ops(svn_diff.diff_sequences({}, {})))
        assert.are.equal("+2", render_ops(svn_diff.diff_sequences({}, { 1, 2 })))
        assert.are.equal("-2", render_ops(svn_diff.diff_sequences({ 1, 2 }, {})))
    end)

    it("orders removed before added within each changed region", function()
        assert.are.equal("=1 -1 +1 =1", render_ops(svn_diff.diff_sequences({ 1, 2, 3 }, { 1, 9, 3 })))
    end)

    it("returns a valid, flagged diff when the budget runs out", function()
        local a, b = {}, {}

        for i = 1, 400 do
            a[i] = i % 7
            b[i] = (i * 3) % 7
        end

        local ops, exhausted = svn_diff.diff_sequences(a, b, 100)
        local ai, bi = 0, 0

        for _, op in ipairs(ops) do
            if op[1] == "=" then
                for _ = 1, op[2] do
                    ai, bi = ai + 1, bi + 1
                    assert.are.equal(a[ai], b[bi])
                end
            elseif op[1] == "-" then
                ai = ai + op[2]
            else
                bi = bi + op[2]
            end
        end

        assert.is_true(exhausted)
        assert.are.equal(#a, ai)
        assert.are.equal(#b, bi)
    end)
end)

describe("svn-diff diff_lines", function()
    it("numbers every line on its own side and counts what changed", function()
        local lines, added, removed = svn_diff.diff_lines("a\nb\nc\n", "a\nB\nc\nd\n")

        assert.are.same({
            "context:1:1:a",
            "removed:2::b",
            "added::2:B",
            "context:3:3:c",
            "added::4:d"
        }, describe_lines(lines))
        assert.are.equal(2, added)
        assert.are.equal(1, removed)
    end)

    it("shows a dropped final newline as a change to the last line, flagged on the side that lacks it", function()
        local lines = svn_diff.diff_lines("a\nb\n", "a\nb")

        assert.are.same({ "context:1:1:a", "removed:2::b", "added::2:b" }, describe_lines(lines))
        assert.is_nil(lines[2].no_newline)
        assert.is_true(lines[3].no_newline)
    end)

    it("marks the changed words of a similar line pair, folding the space between two changed words in", function()
        local lines = svn_diff.diff_lines(
            "this is a long paragraph about history\n",
            "this is a much longer paragraph about diffs\n"
        )

        assert.are.same({
            "removed:1::this is a [long] paragraph about [history]",
            "added::1:this is a [much longer] paragraph about [diffs]"
        }, describe_lines(lines))
    end)

    it("leaves a line pair unmarked when too little of it is shared", function()
        local lines = svn_diff.diff_lines("draft\n", "released\n")

        assert.are.same({ "removed:1::draft", "added::1:released" }, describe_lines(lines))
    end)

    it("never splits a UTF-8 character when marking words", function()
        local lines = svn_diff.diff_lines("the café is open today\n", "the cafés is open today\n")

        assert.are.equal("the [cafés] is open today", line_text(lines[2]))
    end)

    it("HTML-escapes line text", function()
        local lines = svn_diff.diff_lines("", "<p class=\"x\">&amp;</p>\n")

        assert.are.equal("&lt;p class=&quot;x&quot;&gt;&amp;amp;&lt;/p&gt;", line_text(lines[1]))
    end)

    it("hides a CRLF line's own CR from the displayed text", function()
        local lines = svn_diff.diff_lines("a\r\n", "b\r\n")

        assert.are.same({ "removed:1::a", "added::1:b" }, describe_lines(lines))
    end)
end)

describe("svn-diff build_hunks", function()
    local function body(n, changed)
        local lines = {}

        for i = 1, n do
            lines[i] = changed[i] or ("line " .. i)
        end

        return table.concat(lines, "\n") .. "\n"
    end

    it("keeps three lines of context around a change", function()
        local entries = svn_diff.diff_lines(body(20, {}), body(20, { [10] = "changed" }))
        local hunks = svn_diff.build_hunks(entries)

        assert.are.equal(1, #hunks)
        assert.are.equal("@@ -7,7 +7,7 @@", hunks[1].header)
        assert.are.equal(8, #hunks[1].lines)
    end)

    it("merges changes whose gap is no longer than both contexts together, and splits farther ones, exactly like diff -u", function()
        -- Expected headers taken from GNU "diff -u" on the same inputs:
        -- six unchanged lines between the changes merge, seven split.
        local merged = svn_diff.build_hunks((svn_diff.diff_lines(body(30, {}), body(30, { [5] = "x", [12] = "y" }))))
        local split = svn_diff.build_hunks((svn_diff.diff_lines(body(30, {}), body(30, { [5] = "x", [13] = "y" }))))

        assert.are.equal(1, #merged)
        assert.are.equal("@@ -2,14 +2,14 @@", merged[1].header)
        assert.are.equal(2, #split)
        assert.are.equal("@@ -2,7 +2,7 @@", split[1].header)
        assert.are.equal("@@ -10,7 +10,7 @@", split[2].header)
    end)

    it("numbers a pure insertion at the very top from line 0 on the old side, like diff -u", function()
        local hunks = svn_diff.build_hunks((svn_diff.diff_lines("", "new\n")))

        assert.are.equal("@@ -0,0 +1,1 @@", hunks[1].header)
    end)
end)

describe("svn-diff build_context", function()
    it("diffs a plain modification, with links for both sides", function()
        local context = render_context(README_R2, {
            end_revision = "2",
            href_for = function(path, rev) return path .. "?p=" .. rev end
        })

        assert.are.equal("readme.txt", context.label)
        assert.are.same({ path = "/trunk/readme.txt", rev = "1", href = "/trunk/readme.txt?p=1" }, context.old)
        assert.are.same({ path = "/trunk/readme.txt", rev = "2", href = "/trunk/readme.txt?p=2" }, context.new)
        assert.are.same({ added = 2, removed = 1 }, context.stats)
        assert.is_true(context.has_hunks)
        assert.are.same({
            "context:1:1:line one",
            "removed:2::line two",
            "added::2:line 2 changed",
            "context:3:3:line three",
            "added::4:line four"
        }, describe_lines(context.hunks[1].lines))
        assert.is_nil(context.props)
    end)

    it("parses the same regardless of how the response is split into buckets", function()
        for _, size in ipairs({ 1, 7, 64, 100000 }) do
            local context = render_context(README_R2, { end_revision = "2" }, size)

            assert.are.same({ added = 2, removed = 1 }, context.stats)
        end
    end)

    it("shows only the property change when the content didn't change", function()
        local context = render_context(DOC_R3, { end_revision = "3" })

        assert.is_true(context.content_unchanged)
        assert.is_nil(context.hunks)
        assert.are.equal(1, #context.props)
        assert.are.equal("cms:status", context.props[1].name)
        assert.are.equal("modified", context.props[1].status)
        assert.are.same({ "removed:1::draft", "added::1:released" }, describe_lines(context.props[1].lines))
    end)

    it("lists removed and added properties, multi-line values line by line, in name order", function()
        local context = render_context(DOC_R11, { end_revision = "11" })

        assert.are.equal("cms:notes", context.props[1].name)
        assert.are.equal("added", context.props[1].status)
        assert.are.same({ "added::1:first line", "added::2:second line" }, describe_lines(context.props[1].lines))
        assert.is_nil(context.props[1].lines[2].no_newline)
        assert.are.equal("cms:status", context.props[2].name)
        assert.are.equal("removed", context.props[2].status)
        -- application/xml counts as text here, unlike in svn diff itself.
        assert.is_true(context.has_hunks)
    end)

    it("follows a file back through a branch copy made in the same commit", function()
        local context = render_context(BRANCH_R4, { end_revision = "4" })

        assert.are.equal("/trunk/readme.txt", context.old.path)
        assert.are.equal("2", context.old.rev)
        assert.are.equal("/branches/b1/readme.txt", context.new.path)
        assert.are.same({ added = 1, removed = 1 }, context.stats)
    end)

    it("diffs a file added without history against nothing", function()
        local context = render_context(ADDED_R7, { end_revision = "7" })

        assert.is_true(context.added)
        assert.is_nil(context.old)
        assert.are.same({ "added::1:brand new" }, describe_lines(context.hunks[1].lines))
    end)

    it("reports binary content from svn:mime-type, without keeping its delta", function()
        local context, parsed = render_context(BINARY_FILE, { end_revision = "6" })

        assert.are.same({ mime_type = "application/octet-stream" }, context.content_binary)
        assert.is_nil(context.has_hunks)
        assert.is_nil(parsed.revs[2].delta)
        assert.are.equal("binary", parsed.revs[2].delta_skipped)
    end)

    it("reports content that isn't valid UTF-8 instead of showing it", function()
        local context = render_context(LATIN1_R10, { end_revision = "10" })

        assert.is_true(context.content_not_utf8)
        assert.is_nil(context.has_hunks)
    end)

    it("reports content larger than max_bytes instead of diffing it", function()
        local context = render_context(README_R2, { end_revision = "2", max_bytes = 20 })

        assert.are.same({ limit = 20 }, context.content_too_large)
        assert.is_nil(context.has_hunks)
    end)

    it("summarizes a base64-encoded property value holding control characters", function()
        local context = render_context(BINARY_PROP_R13, { end_revision = "13" })

        assert.is_true(context.content_unchanged)
        assert.are.same({ "added::1:(binary value, 10 bytes)" }, describe_lines(context.props[1].lines))
    end)

    it("shows mod_dav_svn's own error message from an error document", function()
        local context = render_context(ERROR_DOC, { end_revision = "2" })

        assert.are.same({ message = "&#39;/trunk&#39; is not a file in revision 2" }, context.error)
        assert.is_nil(context.summary)
    end)

    it("shows a parse error for a response cut short, rather than a partial diff", function()
        local context = render_context(README_R2:sub(1, 600), { end_revision = "2" })

        assert.truthy(context.error.message:find("Unexpected response from the server", 1, true))
        assert.is_nil(context.has_hunks)
    end)

    it("says so when the file didn't change in the requested revision at all", function()
        local context = render_context(ADDED_R7, { end_revision = "9" })

        assert.is_true(context.unchanged)
        assert.is_nil(context.has_hunks)
    end)
end)
