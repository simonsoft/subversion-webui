# subversion-webui
Subversion Web Styling


## Installation

Tested on Ubuntu 24.04

```
# TODO: Confirm if all are needed.
sudo apt install     lua5.3     liblua5.3-dev     luarocks     libexpat1-dev

sudo luarocks --lua-version=5.3 install luaexpat
```


## Apache httpd conf

```
LuaOutputFilter SVN_XML_LISTING \
        "/srv/cms/admin/apache/svn-list.lua" \
        output_filter

<Location /svn>

    # Keep in order to generate XML
    SVNIndexXSLT "whatever.xsl"

    FilterDeclare SVN_XML_LISTING

    FilterProvider SVN_XML_LISTING SVN_XML_LISTING \
        "%{REQUEST_METHOD} == 'GET' \
            && %{CONTENT_TYPE} =~ m#^(?:text|application)/xml(?:;|$)# \
            && %{REQUEST_URI} =~ m#/$#"

    FilterProtocol SVN_XML_LISTING "change=yes;byteranges=no"
    # TODO: Restore compression
    FilterChain SVN_XML_LISTING


</Location>
```