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
    # TODO: Restore compression
    FilterChain SVN_XML_INDEX

    # Selects mod-lua's page template (templates/<type>/). Defaults to
    # "simple" when unset; e.g. set to "wa-page" for the Web Awesome
    # <wa-page> shell instead.
    # SetEnv SVN_INDEX_TEMPLATE simple

</Location>
```


## Running tests

Tests use [busted](https://lunarmodules.github.io/busted/) and run against the real `luaexpat`/`lustache` dependencies (only the Apache request object and the bucket-streaming protocol are mocked).

```
luarocks install busted

busted spec/
```