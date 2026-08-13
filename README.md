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

    # The wa-page shell's page.mustache carries extensive developer-facing
    # comments explaining its own htmx/CSS behavior. These are stripped
    # from the served page by default so they aren't shipped to every
    # browser -- set to "0"/"false"/"off"/"no" to serve the page template
    # uncommented (e.g. to read its source via "View Page Source" while
    # debugging).
    # SetEnv SVN_INDEX_STRIP_COMMENTS 0

</Location>
```

For serving XML responses (e.g. `SVNIndexXSLT` output) to browsers that
have dropped native client-side XSLT support, see
[README-xslt-polyfill.md](README-xslt-polyfill.md) for an independent
output filter that polyfills it instead.

### Customizing templates

Every `.mustache` file under a `templates/<type>/` directory can be
overridden without editing (or forking) the shipped file: if a
`name.custom.mustache` sits alongside `name.mustache` in that same
directory, it's loaded instead. This works for every template file
(`page`, `dir`, `file`, `repo`, `updir`, `page-head-end`, and, for
`wa-page`, `log`/`log-item`) in all four template types.

Each template type also ships an empty `page-head-end.mustache`, rendered
with the exact same variable context as `page.mustache` and inserted just
before `</head>` — a place to add site-specific `<meta>`/`<link>`/`<script>`
tags (analytics, extra CSS, etc.) via `page-head-end.mustache` or
`page-head-end.custom.mustache`, without touching `page.mustache` itself.

`wa-page` additionally splits its `<header>`, breadcrumb subheader, and
`<footer>` out into their own `page-header.mustache`, `page-subheader.mustache`,
and `page-footer.mustache` files (each rendered the same way, and each
overridable via a `.custom.mustache` sibling). Unlike `page-head-end`, these
three are optional per template type — only `wa-page` ships them; the other
skins simply don't define that region, and it renders as empty.

For example, `wa-page`'s header background color is exposed as the
`--svn-header-bg` CSS custom property (defaulting to Web Awesome's own
brand color) — override it by adding this to
`templates/wa-page/page-head-end.mustache` (or the `.custom.mustache`
variant):

```html
<style>
:root {
    --svn-header-bg: #2c3e50;
}
</style>
```

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

    # Maximum number of log entries returned by the History link's initial
    # fetch. Defaults to 50 when unset.
    # SetEnv SVN_LOG_LIMIT 50

    # Maximum number of log entries returned by each continuous-scroll
    # "load more" batch, once the dialog's list is scrolled to its own
    # bottom (independent of SVN_LOG_LIMIT above, which only governs the
    # initial fetch). Defaults to whatever SVN_LOG_LIMIT itself resolves to
    # when unset -- i.e. a uniform page size everywhere.
    # SetEnv SVN_LOG_LIMIT_SCROLL 50

    # Locale for the date shown on each log entry (BCP-47 language tag,
    # e.g. "sv"). Omitted/unset falls back to the browser's own locale.
    # SetEnv SVN_LOG_DATE_LANG sv

</Location>
```

`SetInputFilter` (unlike `FilterDeclare`/`FilterProvider`) has no per-request
condition syntax, so it activates on every request under this `Location` --
including real `svn` client traffic, which also uses `REPORT` for its own
protocol purposes (update-report, etc.) against the exact same URL space.
`SVN_LOG_REPORT_BODY`'s `input_filter` guards against this itself: it only
ever acts on a `REPORT` request whose `Content-Type` is form-encoded --
htmx v4's own default for the History link's request (no `hx-vals`/form
ancestor to serialize; confirmed to be
`application/x-www-form-urlencoded;charset=UTF-8`), and nothing else in
this app or in real `svn` client traffic ever sends. This is deliberately an
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

`SVN_INDEX_QUERY_FILE` (see above) is now also consulted by the History
log's own output filter -- the same literal query-string fragment is
appended to a changed-path's link when it refers to a file (never a
directory), exactly mirroring how it's already applied to `svn-index.lua`'s
own file-entry links. Existing deployments that already set
`SVN_INDEX_QUERY_FILE` get this behavior automatically, with no config
change needed.

The History dialog scrolls continuously: once its own internal list is
scrolled to the bottom, a "load more" batch is fetched and appended
automatically via htmx, reusing the exact same `REPORT`-interception
mechanism as the initial fetch. Each batch's own size is `SVN_LOG_LIMIT`
(initial fetch) or `SVN_LOG_LIMIT_SCROLL` (every subsequent batch) -- so the
total amount of history reachable this way is effectively unbounded,
without changing the bounded cost of any single request. Scrolling stops on
its own, with no further requests, once a batch comes back smaller than its
own limit (the repository's actual history has been exhausted).

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

### Browser smoke test (History dialog, optional)

The tests above run `output_filter` against the real `luaexpat`/`lustache`
dependencies, but everything downstream of its own HTML string -- whether
the real Web Awesome custom elements (`<wa-details>`, `<wa-dialog>`,
`<wa-format-date>`) actually behave as documented once loaded in a real
browser, and whether the CSS two-line clamp on each entry's collapsed
preview actually clamps to the correct pixel height -- is outside what a
pure-Lua `busted` test can verify at all. `smoketest/` is a separate,
optional, Puppeteer-driven check that renders the real `svn-log.lua`
output through a real browser to cover exactly that gap.

It is entirely independent of `busted spec/`: not run as part of it, adds
no Node.js dependency to the rest of the repo, and isn't required for
ordinary development -- `busted spec/` remains the primary, fast test loop.

Prerequisites:

- Node.js >=20.
- A `lua5.3` interpreter on `PATH` (already required for `busted spec/`
  above); override with `LUA_BIN=lua` (or similar) if it's named
  differently on your system.
- Outbound network access to `ka-f.webawesome.com` and `cdn.jsdelivr.net`
  -- the same CDN hosts `templates/wa-page/page.mustache` itself loads Web
  Awesome/htmx from. This cannot run fully offline.
- `npm install` downloads Puppeteer's own bundled Chromium (roughly
  200MB) on first run, cached under `smoketest/.cache/puppeteer` (see
  `.puppeteerrc.cjs`) rather than the shared `~/.cache/puppeteer`.

```
cd smoketest
npm install
npm test
```

Screenshots and the generated harness page are written to
`smoketest/output/` (gitignored) for manual inspection.

If `npm install`/Puppeteer's launch fails citing a permissions problem in
its cache directory, this is almost always a stale/root-owned
`~/.cache/puppeteer` left over from some unrelated earlier install on that
machine -- `.puppeteerrc.cjs` avoids this by pointing `cacheDirectory` at
a project-local path instead, so a fresh clone shouldn't hit it. If it
does anyway, delete `smoketest/.cache/` and re-run `npm install`.