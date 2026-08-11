# subversion-webui
Subversion Web Styling


## Installation

Tested on Ubuntu 24.04

```
# TODO: Confirm if all are needed.
sudo apt install     lua5.3     liblua5.3-dev     luarocks     libexpat1-dev

sudo luarocks --lua-version=5.3 install luaexpat
sudo luarocks --lua-version=5.3 install lustache
```

Deploy the whole repository (not just `mod-lua/`) to `/opt/subversion-webui`,
since `mod-lua/svn-index.lua` resolves its page/entry templates from
`templates/<type>/` relative to its own location:

```
sudo git clone <repo-url> /opt/subversion-webui
```

or, from a local checkout:

```
sudo cp -r . /opt/subversion-webui
```


## Apache httpd conf

`svn-index.lua` picks a template type from the `SVN_INDEX_TEMPLATE`
environment variable (see `templates/`), defaulting to `simple` when unset.
`simple` is a plain, dependency-free listing with full-page navigation
links; `htmx` is the same look with [htmx](https://htmx.org)-driven
in-place directory expansion instead of full page loads; `htmx-remix` is
`htmx` with [Remix Icon](https://remixicon.com) icons in place of list
bullets; `wa-page` wraps the listing in a Web Awesome `<wa-page>` shell
(and also uses htmx).
Set it per-`<Location>` with Apache's `SetEnv` to opt into a different one,
e.g. `wa-page`:

```
LuaOutputFilter SVN_XML_INDEX \
        "/opt/subversion-webui/mod-lua/svn-index.lua" \
        output_filter

<Location /svn>

    # Keep in order to generate XML
    SVNIndexXSLT "whatever.xsl"

    FilterDeclare SVN_XML_INDEX

    FilterProvider SVN_XML_INDEX SVN_XML_INDEX \
        "%{REQUEST_METHOD} == 'GET' \
            && %{CONTENT_TYPE} =~ m#^(?:text|application)/xml(?:;|$)# \
            && %{REQUEST_URI} =~ m#/$#"

    FilterProtocol SVN_XML_INDEX "change=yes;byteranges=no"
    FilterChain SVN_XML_INDEX

    # Selects mod-lua's page template (templates/<type>/). Defaults to
    # "simple" when unset; e.g. set to "wa-page" for the Web Awesome
    # <wa-page> shell instead.
    # SetEnv SVN_INDEX_TEMPLATE simple

</Location>
```

For serving XML responses (e.g. `SVNIndexXSLT` output) to browsers that
have dropped native client-side XSLT support, see
[README-xslt-polyfill.md](README-xslt-polyfill.md) for an independent
output filter that polyfills it instead.

### History (wa-page skin only)

`wa-page` adds a "History" link to the page header that issues a real HTTP
`REPORT` request (svn's log-report) against the directory currently being
browsed, rendered as a basic log table in place of the directory listing.
This needs two additional filters on the same `<Location /svn>` block used
above -- an input filter that synthesizes the log-report request body, and
an output filter that renders its XML response as HTML:

```
LuaInputFilter SVN_LOG_REPORT_BODY \
        "/opt/subversion-webui/mod-lua/svn-log.lua" \
        input_filter

LuaOutputFilter SVN_LOG_HTML \
        "/opt/subversion-webui/mod-lua/svn-log.lua" \
        output_filter

<Location /svn>

    # ... existing SVNIndexXSLT / SVN_XML_INDEX filter config from above ...

    SetInputFilter SVN_LOG_REPORT_BODY

    FilterDeclare SVN_LOG_HTML

    FilterProvider SVN_LOG_HTML SVN_LOG_HTML \
        "%{REQUEST_METHOD} == 'REPORT' \
            && %{CONTENT_TYPE} =~ m#^(?:text|application)/xml(?:;|$)# \
            && %{REQUEST_URI} =~ m#/$#"

    FilterProtocol SVN_LOG_HTML "change=yes;byteranges=no"
    FilterChain SVN_LOG_HTML

    # Maximum number of log entries returned by the History link.
    # Defaults to 50 when unset.
    # SetEnv SVN_LOG_LIMIT 50

</Location>
```

`SetInputFilter` (unlike `FilterDeclare`/`FilterProvider`) has no per-request
condition syntax, so it activates on every request under this `Location` --
including real `svn` client traffic, which also uses `REPORT` for its own
protocol purposes (update-report, etc.) against the exact same URL space.
`SVN_LOG_REPORT_BODY`'s `input_filter` guards against this itself: it only
ever acts on a `REPORT` request whose `Content-Type` is *exactly*
`application/x-www-form-urlencoded` -- the History link explicitly sends
that via `hx-headers` (see `page.mustache`), and nothing else in this app
or in real `svn` client traffic ever does. This is deliberately an
allow-list, not a deny-list on XML: real `svn` clients always declare
`Content-Type: text/xml` on a REPORT body (a DeltaV/WebDAV convention,
confirmed against Subversion's own `libsvn_ra_serf` source), but a
misbehaving or non-standard client that fails to set that -- or sets
something else entirely -- must still pass through untouched rather than
being silently treated as this app's own. Every request that isn't
*exactly* the History link's own declared Content-Type, real svn-client
REPORT traffic included, passes through unmodified.

This feature is wired into the `wa-page` template only; `SVN_INDEX_TEMPLATE`
must be set to `wa-page` for the History link to appear (see above) -- the
other three templates have no `log.mustache`/`log-item.mustache` files and
are unaffected by this filter pair being installed (they simply never send a
non-XML-content-typed `REPORT` request).

### Apache httpd transfer

The transfer will be chunked unless returned in a single brigade. This is already the case with mod_dav_svn regardless of additional filter. However, if deflate or other compression filter is enabled, the compressed response might fit into the compression filter's buffer and then become a regular transfer with Content-Length header.


## Running tests

Tests use [busted](https://lunarmodules.github.io/busted/) and run against the real `luaexpat`/`lustache` dependencies (only the Apache request object and the bucket-streaming protocol are mocked). The mocked request object's `regex()` method (standing in for mod_lua's own built-in `r:regex()`, used by `SVN_INDEX_HIDE_DIR` -- see below) is backed by `lrexlib-pcre2`, a test-only dependency: production never needs it, since `r:regex()` is provided by mod_lua itself.

```
sudo apt install libpcre2-dev

luarocks install busted
luarocks install lrexlib-pcre2

busted spec/
```