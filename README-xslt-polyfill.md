# XSLT client-side polyfill

Browsers are removing native support for `XSLTProcessor` / `<?xml-stylesheet
type="text/xsl" ...?>`, which breaks any XML response that still relies on
client-side XSLT for styling -- e.g. `mod_dav_svn`'s own `SVNIndexXSLT`
directive, or a legacy `.xsl` stylesheet you don't want to port.

`mod-lua/xslt-polyfill.lua` is an independent Apache mod_lua output filter
that keeps such responses working by inserting one `<script>` line into the
XML, loading Google's [xslt_polyfill](https://github.com/mfreed7/xslt_polyfill)
which re-implements `XSLTProcessor` in JavaScript and performs the
transform in the browser instead of the (removed) native engine.

It is unrelated to `svn-index.lua` (the server-side HTML listing renderer
also in this repo) and can be enabled independently of it. Because it works
by locating the root element's opening tag rather than parsing any
particular schema, it can be applied to **any** XML response the server
returns, not just SVN directory listings.

## How it works

Given an XML document like mod_dav_svn's `SVNIndexXSLT` output:

```xml
<?xml version="1.0" encoding="utf-8"?>
<?xml-stylesheet type="text/xsl" href="/svn.xsl"?>
<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<index rev="242" path="/" base="demo1">
...
</index>
</svn>
```

the filter inserts the polyfill's `<script>` tag as the first child of the
root element:

```xml
<?xml version="1.0" encoding="utf-8"?>
<?xml-stylesheet type="text/xsl" href="/svn.xsl"?>
<svn version="1.14.1 (r1886195)" href="http://subversion.apache.org/">
<script src="/static/xslt-polyfill.min.js" xmlns="http://www.w3.org/1999/xhtml"></script>
<index rev="242" path="/" base="demo1">
...
</index>
</svn>
```

This is exactly the placement xslt_polyfill's own "automatic
transformation" mode documents: once loaded, it scans the document for the
`<?xml-stylesheet?>` processing instruction, fetches the referenced `.xsl`,
and performs the transform client-side. The `xmlns="http://www.w3.org/1999/xhtml"`
attribute is required -- without it the `<script>` element is parsed as a
plain (inert) XML element rather than as XHTML script.

The filter never touches `Content-Type` (the response must keep being
served as XML for a browser to run its stylesheet PI at all, and for the
polyfill's scanner to find it) and clears `Content-Length`/`ETag` since the
body length changes.

Only the prologue -- the XML declaration, any PIs/comments/doctype, and the
root element's own opening tag -- is buffered while the filter looks for
the insertion point; everything after that streams straight through
unbuffered, so a large response body (many log entries, a big directory
listing, ...) never sits in memory. If the root element's opening tag
hasn't closed within 64KB, the filter gives up and passes the response
through unmodified rather than buffering indefinitely.

## Downloading the polyfill

`xslt_polyfill` doesn't cut versioned releases; track the built file
directly off its `main` branch:

```
sudo curl -o /opt/subversion-webui/static/xslt-polyfill.min.js \
    https://raw.githubusercontent.com/mfreed7/xslt_polyfill/main/xslt-polyfill.min.js
```

Serve that file as a static asset from Apache (an `Alias`/`ScriptAlias`-free
`Directory`, or anywhere else convenient) at whatever URL path you'll point
`XSLT_POLYFILL_URL` at below.

## Apache httpd conf

```
Alias /static/xslt-polyfill.min.js /opt/subversion-webui/static/xslt-polyfill.min.js

LuaOutputFilter XSLT_POLYFILL \
        "/opt/subversion-webui/mod-lua/xslt-polyfill.lua" \
        output_filter

<Location /svn>

    # Keep in order to generate XML with a stylesheet PI for the polyfill
    # to find. Point this at your own legacy .xsl if you have one.
    SVNIndexXSLT "whatever.xsl"

    FilterDeclare XSLT_POLYFILL

    FilterProvider XSLT_POLYFILL XSLT_POLYFILL \
        "%{REQUEST_METHOD} == 'GET' \
            && %{CONTENT_TYPE} =~ m#^(?:text|application)/xml(?:;|$)#"

    FilterProtocol XSLT_POLYFILL "change=yes;byteranges=no"
    FilterChain XSLT_POLYFILL

    # Path to the downloaded polyfill JS, typically served from this same
    # host (see "Downloading the polyfill" above). The filter is a no-op
    # (response passed through unmodified) when this is unset.
    SetEnv XSLT_POLYFILL_URL /static/xslt-polyfill.min.js

</Location>
```

Nothing here is specific to `/svn` or to `SVNIndexXSLT` -- the same
`FilterDeclare`/`FilterProvider`/`FilterChain`/`SetEnv` block works on any
`<Location>` or `<Directory>` whose responses are XML with their own
`<?xml-stylesheet?>` PI.

Note the `%{REQUEST_URI} =~ m#/$#` condition used for `svn-index.lua`'s
filter (see the main [README](README.md)) is deliberately omitted above:
that one only fires on directory listings, whereas this filter has no such
restriction and should match every matching XML response, listings and
single files alike.

If you want the styled, client-side-transformed listing (this filter)
rather than the server-rendered HTML listing (`svn-index.lua`), don't
declare both filters on the same `<Location>` -- run one or the other.

## Testing without a real browser rollout

As of this writing, Chrome still ships native XSLT behind a flag rather
than having removed it outright. To exercise the polyfill path instead of
the native implementation for testing, disable native XSLT and confirm the
polyfill picks up the slack:

```
chrome://flags/#xslt  ->  Disabled
```

## Running tests

Same `busted` setup as the rest of the repo:

```
busted spec/xslt_polyfill_spec.lua
```
