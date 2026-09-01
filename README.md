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

`wa-page` also ships seven further named slots as empty placeholder files,
the same "optional, empty by default, override via `.custom.mustache`"
pattern as `page-head-end`: `page-skip-to-content.mustache`,
`page-banner.mustache`, `page-navigation-header.mustache`,
`page-navigation-footer.mustache`, `page-main-header.mustache`,
`page-main-footer.mustache`, and `page-aside.mustache` — corresponding to
wa-page's `skip-to-content`, `banner`, `navigation-header`,
`navigation-footer`, `main-header`, `main-footer`, and `aside` slots. Fill
one in (or add its `.custom.mustache` sibling) to add banner content, a
sticky aside, or custom nav-drawer/main-content header and footer regions
without touching `page.mustache`. Two other wa-page slots, `menu` and
`navigation-toggle`/`navigation-toggle-icon`, aren't exposed this way:
`menu` replaces the built-in `navigation` region entirely rather than
adding to it, and this skin already provides a custom nav toggle via the
`data-toggle-nav` attribute on the icon in `page-header.mustache`.

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
            && %{req_novary:HX-Request} == 'true'"

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

`SVN_LOG_HTML`'s own `FilterProvider` condition checks the `HX-Request`
header (via `req_novary`, so this dispatch-only check doesn't add
`HX-Request` to the response's `Vary` header) rather than the request URI's
shape, because History requests now target both directories *and*
individual files (see "File history" below) -- a directory-only signal like
"URI ends in `/`" can no longer distinguish this app's own REPORT traffic
from a real `svn` client's REPORT traffic against a file (both would lack a
trailing slash), whereas `HX-Request: true` is sent on every request htmx
issues and never by a real `svn` client. `REQUEST_METHOD`/`CONTENT_TYPE`
stay as defense-in-depth alongside it.

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

### File history

Individual files, not just directories, can also show History -- two entry
points, both built on the same `SVN_LOG_HTML`/`SVN_LOG_REPORT_BODY` filter
pair above (no new REPORT-handling logic, just new places that link to it):

- **A "History" icon** next to every file in the directory listing (see
  `file.mustache`), opening the same `#svn-history-dialog` the page-level
  "History" link uses, scoped to that one file.
- **A `?history` (or `?history=<filename>`) query parameter** on the
  directory's own index page URL. Bare (`?history`, or `?history=` with an
  empty value) auto-opens History for the *browsed directory itself* -- the
  same target the page-level "History" link's own click already opens, just
  triggered automatically on page load instead. Given a value
  (`?history=<filename>`), `filename` must instead be a *direct child* of
  the directory being browsed (a single path segment, validated
  server-side; rejected if it contains `/`, `%2f`/`%2F`, or is `.`/`..`/
  empty), and History opens for that file. Either way, the page loads with
  history already fetched and the dialog opened automatically, via a
  declarative `hx-trigger="load"` on `#svn-history-content` -- no extra
  request, no bootstrap script. Revision pinning reuses the existing
  `?p=<rev>` param.

All three (the icon, and both `?history` forms) require `SVN_LOG_HTML`'s
`FilterProvider` condition above (the `HX-Request` check) -- a deployment
that upgrades `svn-index.lua`/`svn-log.lua` without also updating that
Apache snippet will still work for a plain directory browse, but History
links/deep-links will silently get raw XML back instead of rendered HTML.

#### Sample: a `/log.html` redirect into file history

`?history=<filename>` (above) needs the file's *parent directory's own URL*
up front -- fine for a link generated from inside the app itself, less
convenient as a stable, shareable URL when all you have is a repo name and a
file's full repo-relative path (`base`/`target`, in the sense the rest of
this README uses those words).

This repo doesn't ship a handler for that shape -- it's a fairly
site-specific choice (URL, param names, how `base` maps to a mount point)
not worth carrying as tested, maintained code for every deployment. The
sample below is a starting point, using `mod_rewrite` (no Lua, no extra
file) rather than a Lua content handler: it redirects (HTTP 302)
`/log.html?base=<repo>&target=<repo-relative-path>&torev=<revision>` to the
corresponding directory's own index page with `?history=<filename>&p=<torev>`.
Copy it into your Apache config and adjust to taste:

```apache
RewriteEngine On

# int:escape/int:unescape are httpd's own built-in RewriteMap functions
# (ap_escape_uri/ap_unescape_url under the hood -- no separate module,
# nothing to install) -- must be declared at server/virtual-host level,
# same as RewriteEngine, not inside a <Location> block.
RewriteMap escape int:escape
RewriteMap unescape int:unescape

# Rejects a "base" containing an embedded "/" or "%2f"/"%2F" -- otherwise
# an attacker could inject extra path structure (or a traversal) into the
# redirect target. Falls through to a plain 403 rather than redirecting.
RewriteCond %{QUERY_STRING} (?:^|&)base=[^&]*(?:/|%2[Ff])
RewriteRule ^/log\.html$ - [F]

# Decodes "target" fully -- including any "%2F"-encoded path separators,
# the shape every "target" example elsewhere in this README uses -- into
# an env var. int:unescape is ap_unescape_url (the same function backing
# r:parseargs()), so "%2F" becomes a real "/" the same way any other
# "%XX" sequence becomes its real character.
RewriteCond %{QUERY_STRING} (?:^|&)target=([^&]*)
RewriteRule ^/log\.html$ - [E=LOG_TARGET:${unescape:%1}]

# Rejects a decoded target containing a "/../", "../", or "/.." traversal
# segment.
RewriteCond %{ENV:LOG_TARGET} (^|/)\.\.(/|$)
RewriteRule ^/log\.html$ - [F]

# Splits the now fully-decoded target at its LAST "/": everything through
# it is the parent directory path, everything after it is the filename.
# LOG_TARGET_SPLIT marks that this succeeded -- required by the final
# rules below so a "target" that's missing entirely, or present but with
# no "/" in it at all, produces no redirect at all (matching a missing
# "target"), rather than one built from stale/empty LOG_PARENT/
# LOG_FILENAME values left over from nothing actually having matched.
RewriteCond %{ENV:LOG_TARGET} ^(.*)/([^/]*)$
RewriteRule ^/log\.html$ - [E=LOG_PARENT:%1,E=LOG_FILENAME:%2,E=LOG_TARGET_SPLIT:1]

# torev present and a plain non-negative integer: redirect with "&p=".
# ${escape:...} re-encodes anything that still needs it (a space in the
# filename, say) -- confirmed against ap_escape_uri's own source comment
# that, on Unix, it deliberately leaves "/" alone as a path separator, so
# this doesn't turn LOG_PARENT's own real "/" characters back into "%2F".
RewriteCond %{ENV:LOG_TARGET_SPLIT} ^1$
RewriteCond %{QUERY_STRING} (?:^|&)base=([^&]+)
RewriteCond %{QUERY_STRING} (?:^|&)torev=([0-9]+)
RewriteRule ^/log\.html$ /svn/%1${escape:%{ENV:LOG_PARENT}}/?history=${escape:%{ENV:LOG_FILENAME}}&p=%2 [R=302,L,NE]

# torev absent (or present but not a plain non-negative integer, which is
# silently dropped here rather than rejected): redirect without "&p=".
RewriteCond %{ENV:LOG_TARGET_SPLIT} ^1$
RewriteCond %{QUERY_STRING} (?:^|&)base=([^&]+)
RewriteRule ^/log\.html$ /svn/%1${escape:%{ENV:LOG_PARENT}}/?history=${escape:%{ENV:LOG_FILENAME}} [R=302,L,NE]
```

("`/svn`" is hardcoded here as the `<Location /svn>` mount point -- adjust
both rules if yours differs; there's no equivalent of the Lua sample's
`SVN_LOCATION_PREFIX` env var to make this configurable without a Lua
handler.)

A directory-shaped `target` (trailing `/`) naturally produces an empty
`?history=` value here (nothing after the last `/`) -- which, per the
bare-`?history` behavior above, auto-opens History for that directory
itself rather than doing nothing, with no extra rule needed for it.

Caveats worth knowing before relying on this, none of which apply to a Lua
`LuaMapHandler`-based content handler (the same registration mechanism
`LuaInputFilter`/`LuaOutputFilter` above use, just for a plain request/
response instead of a filter -- see mod_lua's own docs for
`LuaMapHandler`), if you'd rather have them covered:

- **The `${mapname:key}` lookups inside `[E=...]` flag values (the
  `LOG_TARGET`/`LOG_PARENT`/`LOG_FILENAME` rules above) aren't something
  this repo could verify against a real server.** Apache's own docs
  confirm `[E=VAR:VAL]` supports `%N`/`$N` backreferences in `VAL`, but
  don't explicitly document a `${...}` map lookup inside `VAL` the way
  this relies on -- architecturally it's the same interpolation pass
  `mod_rewrite` already applies to every other right-hand-side string, so
  it's expected to work, but test this against your own Apache before
  relying on it in production, the same way you'd test any Apache config
  this repo can't cover with `busted`/`smoketest`.
- **A malformed `torev` is silently dropped**, not rejected -- the request
  still redirects, just without a revision pin, rather than a 400.

### Lock status (wa-page skin only)

`wa-page` shows a lock icon (owner/comment/date, in a native tooltip) next
to every currently-locked file in the directory listing, fetched via
`mod_dav_svn`'s own `get-locks-report` REPORT -- one request per directory
view, covering every locked file directly under it in a single round trip,
rather than a per-file check. This needs a second REPORT-handling filter
pair on the same `<Location /svn>` block used by `SVN_XML_INDEX`/`SVN_LOG_*`
above:

```
LuaInputFilter SVN_LOCKS_REPORT_BODY \
        "/opt/subversion-webui/mod-lua/svn-locks.lua" \
        input_filter

LuaOutputFilter SVN_LOCKS_HTML \
        "/opt/subversion-webui/mod-lua/svn-locks.lua" \
        output_filter

<Location /svn>

    # ... existing SVNIndexXSLT / SVN_XML_INDEX / SVN_LOG_* filter config from above ...

    SetInputFilter SVN_LOG_REPORT_BODY;SVN_LOCKS_REPORT_BODY

    FilterDeclare SVN_LOCKS_HTML

    FilterProvider SVN_LOCKS_HTML SVN_LOCKS_HTML \
        "%{REQUEST_METHOD} == 'REPORT' \
            && %{CONTENT_TYPE} =~ m#^(?:text|application)/xml(?:;|$)# \
            && %{req_novary:HX-Request} == 'true' \
            && %{req_novary:HX-Svn-Report} == 'locks'"

    FilterProtocol SVN_LOCKS_HTML "change=yes;byteranges=no"
    FilterChain SVN_LOCKS_HTML

</Location>
```

`SetInputFilter` takes a semicolon-separated filter list -- both
`SVN_LOG_REPORT_BODY` and `SVN_LOCKS_REPORT_BODY` run unconditionally on
every request under this `Location`, same as `SVN_LOG_REPORT_BODY` alone
already did (see "History" above). Since a plain "REPORT + form-encoded"
check can no longer tell the two apart on its own, the triggering element
now also sends an `HX-Svn-Report: locks` header (see `page.mustache`'s own
`fetchLocks()`) that each filter's own `input_filter` checks for -- exactly
one of the two ever positively claims a given request (`svn-log.lua`'s own
gate now excludes `HX-Svn-Report == 'locks'`; `svn-locks.lua`'s requires it),
so chain order between the two doesn't matter. `SVN_LOCKS_HTML`'s own
`FilterProvider` condition adds the same `HX-Svn-Report` check on the output
side, so it doesn't also try to process `SVN_LOG_HTML`'s own response (and
vice versa) when both dynamic filters are chained onto this same `Location`.

Unlike the History link, there is no dedicated on-page trigger element:
`page.mustache`'s own inline script fetches lock status once on initial
page load and again on every htmx-driven directory navigation (via the same
`htmx:after:history:push` event nav's own `[selected]`-highlight resync
already listens for), targeting each file's own placeholder
(`file.mustache`'s `#lock-<path_id>`, `path_id` from `svn-index.lua`) via
htmx out-of-band swaps. A file that isn't currently locked simply has no
matching fragment in the response and stays untouched.

This feature is wired into the `wa-page` template only, the same way
History is -- the other three templates have no `lock-badge.mustache` file
and never send the `HX-Svn-Report: locks` request in the first place.

**Not independently verified against a live `mod_dav_svn` server in this
repo.** `svn-log.lua`'s own `log-report` request/response shapes were
confirmed against a real server (see its own comments); `get-locks-report`'s
shape here instead mirrors the documented SVN DeltaV custom-report
convention (`svn_lock_t`'s own fields: path, owner, comment, creation date).
Test this against your own server before relying on it in production.

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