module WbDav

using Dates
using TimeZones
using UUIDs
using EzXML
using HTTP
using HTTP.StatusCodes: OK, CREATED, NO_CONTENT, MULTI_STATUS, NOT_MODIFIED
using HTTP.StatusCodes: NOT_FOUND, FORBIDDEN, METHOD_NOT_ALLOWED, CONFLICT, LOCKED, FAILED_DEPENDENCY
using URIs: URI, uristring

include("data.jl")

const ALL_DAV_PROPS = [:getcontentlength, :getcontenttype, :getlastmodified, :resourcetype,
                       :getcontenttype, :creationdate]

# lockdiscovery
# supportedlock -> lockentry -> [lockscope -> exclusive], 

mutable struct Application
    root::Node{FolderData}
end

function serve()
    root = Root()
    app = Application(root)
    try
        HTTP.serve(app, "0.0.0.0", 8008; reuseaddr=true)
    catch exc
        if exc isa InterruptException
            println("[InterruptException]")
        else
            rethrow(exc)
        end
    end
end

function (app::Application)(request::HTTP.Request)
    println("* ", request.method, ' ', request.target)

    response = something(handle(request, app), HTTP.Response(NOT_FOUND))
    if isnothing(response.request)
        response.request = request
        if !HTTP.hasheader(response, "DAV")
            HTTP.setheader(response, HTTP.Header("DAV", "1,2"))
        end
    end

    return response
end

function splitpath(request::HTTP.Request)::Vector{AbstractString}
    splitpath(request.target)
end

function splitpath(target::AbstractString)::Vector{AbstractString}
    path = URI(target).path
    filter(!isempty, split(path, "/"))
end

function mkhref(request::HTTP.Request, path::AbstractString="")::URI
    host = HTTP.header(request, "Host", "localhost")
    URI("http://" * host * "/" * lstrip(path, '/'))
end

function mkhref(request::HTTP.Request, path::Vector{AbstractString})::URI
    mkhref(request, join(path, '/'))
end

function traverse(node::Node, request::HTTP.Request)::Union{Node,Nothing}
    traverse(node, splitpath(request))
end

function traverse(node::Node, pathparts::Vector{S})::Union{Node,Nothing} where {S <: AbstractString}
    for name in pathparts
        node = findfirst(name, node)
        isnothing(node) && break
    end
    return node
end

handle(request::HTTP.Request, app::Application) = handle(Val(Symbol(request.method)), request::HTTP.Request, app)
handle(request::HTTP.Request, node::Node) = handle(Val(Symbol(request.method)), request::HTTP.Request, node)
handle(request::HTTP.Request, node::Nothing) = HTTP.Response(NOT_FOUND)

function handle(::Any, request::HTTP.Request, app::Application)
    println("!!! Method Not Allowed: ", request.method)
    return HTTP.Response(METHOD_NOT_ALLOWED)
end

function handle(::Any, request::HTTP.Request, node::Node)
    println("!!! Method Not Allowed: ", request.method)
    return HTTP.Response(METHOD_NOT_ALLOWED)
end

function handle(::Val{:OPTIONS}, request::HTTP.Request, app::Application)
    # "Allow" => "GET, HEAD, PUT, PROPFIND, PROPPATCH, MKCOL, DELETE, MOVE, COPY, LOCK, UNLOCK"
    return HTTP.Response(OK, [
        "Content-Type" => "text/xml; charset=utf-8"
        "Allow" => "GET, PUT, PROPFIND, MKCOL, DELETE, LOCK, UNLOCK"
    ])
end

function handle(::Val{:HEAD}, request::HTTP.Request, app::Application)
    node = traverse(app.root, request)
    isnothing(node) && return HTTP.Response(NOT_FOUND)
    ctype = something(getdavproperty(node, :getcontenttype), "application/octet-stream")
    mtime = something(getdavproperty(node, :getlastmodified), "Thu, 01 Jan 1970 00:00:00 GMT")
    return HTTP.Response(OK, ["Content-Type" => ctype, "Last-Modified" => mtime])
end

function handle(::Val{:PROPFIND}, request::HTTP.Request, app::Application)
    node = traverse(app.root, request)
    handle(request, node)
end

function handle(::Val{:PROPFIND}, request::HTTP.Request, node::Node)
    depth = parse(Int, HTTP.header(request, "Depth", "0"))
    reqdoc = parsexml(request.body)

    if isnothing(findfirst("/d:propfind/d:allprop", reqdoc.root, ["d" => "DAV:"]))
        props = map(Symbol ∘ nodename, findall("/d:propfind/d:prop/*", reqdoc.root, ["d" => "DAV:"]))
        # props = findall("/d:propfind/d:prop/*", doc.root, ["d" => "DAV:"]) .|> nodename .|> Symbol
    else
        props = copy(ALL_DAV_PROPS)
    end

    @show depth
    @show props

    doc = XMLDocument()
    root = ElementNode("multistatus")
    link!(root, AttributeNode("xmlns", "DAV:"))
    link!(root, AttributeNode("xmlns:props", "http://apache.org/dav/props/"))
    setroot!(doc, root)

    for rspnode in mkpropfind(mkhref(request, request.target), node, props, depth)
        link!(root, rspnode)
    end

    io = IOBuffer()
    print(io, doc)
    HTTP.Response(MULTI_STATUS, ["Content-Type" => "text/xml"], String(take!(io)))
end

function handle(::Val{:GET}, request::HTTP.Request, app::Application)
    node = traverse(app.root, request)
    handle(request, node)
end

function handle(::Val{:GET}, request::HTTP.Request, node::Node{FolderData})
    doc = HTMLDocument()
    html = setroot!(doc, ElementNode("html"))
    head = addelement!(html, "head")
    body = addelement!(html, "body")

    addelement!(head, "title", "Index of " * request.target)
    addelement!(body, "h1", "Index of " * request.target)

    p = addelement!(body, "p")

    visit(node) do child 
        a = addelement!(p, "a", child.name)
        link!(a, AttributeNode("href", rstrip(request.target, '/') * "/" * child.name))
        addelement!(p, "br")
        nothing
    end

    io = IOBuffer()
    print(io, doc)
    HTTP.Response(OK, ["Content-Type" => "text/html"], String(take!(io)))
end

function handle(::Val{:GET}, request::HTTP.Request, node::Node{ContentData,CommonMeta})
    ctype = something(getdavproperty(node, :getcontenttype), "application/octet-stream")
    mtime = something(getdavproperty(node, :getlastmodified), "Thu, 01 Jan 1970 00:00:00 GMT")
    headers = ["Content-Type" => ctype, "Last-Modified" => mtime]

    let ifmodified::Union{String,ZonedDateTime} = HTTP.header(request, "If-Modified-Since")
        if !isempty(ifmodified)
            ifmodified = ZonedDataTime(ifmodified, dateformat"e, dd u yyyy HH:MM:SS Z")
            ifmodified.utc_datetime == node.meta.mtime && return HTTP.Response(NOT_MODIFIED, headers)
        end
    end

    HTTP.Response(OK, headers, node.content)
end

function handle(::Val{:MKCOL}, request::HTTP.Request, app::Application)
    reqpath = splitpath(request)
    basepath = first(reqpath, length(reqpath)-1)
    basenode = traverse(app.root, basepath)

    isnothing(basenode) && return HTTP.Response(CONFLICT)
    !isfolder(basenode) && return HTTP.Response(FORBIDDEN)

    name = last(reqpath)
    child = findfirst(name, basenode)

    !isnothing(child) && return HTTP.Response(METHOD_NOT_ALLOWED)

    push!(basenode, Node{FolderData}(name))
    return HTTP.Response(CREATED)
end

function handle(::Val{:LOCK}, request::HTTP.Request, app::Application)
    depth::Int = let depth = HTTP.header(request, "Depth", "0")
        if all(isdigit, depth)
            parse(Int, depth)
        elseif depth == "infinity"
            typemax(Int)
        elseif !(depth isa Int)
            0
        end
    end

    # @todo: Timeout -> Infinite, Second-Infinite, Second-1800
    # @todo: lockinfo -> lockscope, locktype, owner

    reqpath = splitpath(request)
    basepath = first(reqpath, length(reqpath)-1)
    basenode = traverse(app.root, basepath)
    isnothing(basenode) && return HTTP.Response(FAILED_DEPENDENCY)

    name = last(reqpath)
    node = findfirst(name, basenode)

    if isnothing(node)
        islocked(basenode) && return HTTP.Response(LOCKED)
        node = Node{ContentData}(name)
        push!(basenode, node)
    else
        islocked(node) && return HTTP.Response(LOCKED)
    end

    token::String = lock(node, depth).token
    @show token

    doc = XMLDocument()
    root = ElementNode("prop")
    link!(root, AttributeNode("xmlns", "DAV:"))
    setroot!(doc, root)

    let lockdiscovery = addelement!(root, "lockdiscovery")
        let activelock = addelement!(lockdiscovery, "activelock")
            addelement!(activelock, "depth", string(depth))
            addelement!(addelement!(activelock, "locktype"), "write")
            addelement!(addelement!(activelock, "lockscope"), "exclusive")
            addelement!(addelement!(activelock, "locktoken"), "href", token)
            addelement!(addelement!(activelock, "lockroot"), "href", abspath(node))
            addelement!(activelock, "timeout", "Second-Infinite")
        end
    end

    io = IOBuffer()
    print(io, doc)

    HTTP.Response(OK,
        ["Content-Type" => "text/xml",
         "Lock-Token" => string('<', token, '>')],
        String(take!(io))
    )
end

function handle(::Val{:UNLOCK}, request::HTTP.Request, app::Application)
    # > UNLOCK
    # Content-Type: text/xml; charset="utf-8"
    # Lock-token: <xxx>
    # Depth: 0 ?

    node = traverse(app.root, request)
    @show node
    isnothing(node) && return HTTP.Response(CONFLICT)

    token = parsetoken(request, "Lock-Token")
    @show token
    isnothing(token) && return HTTP.Response(CONFLICT)

    lock = unlock(node, token)
    @show lock
    isnothing(lock) && return HTTP.Response(CONFLICT)

    HTTP.Response(NO_CONTENT)
end

function handle(::Val{:PUT}, request::HTTP.Request, app::Application)
    reqpath = splitpath(request)
    basepath = first(reqpath, length(reqpath)-1)

    basenode = traverse(app.root, basepath)
    isnothing(basenode) && return HTTP.Response(FAILED_DEPENDENCY)

    name = last(reqpath)
    child = findfirst(name, basenode)
    token = parsetoken(request)

    if isnothing(child)
        !checkwrite(basenode, token) && return HTTP.Response(LOCKED)
        push!(basenode, Node{ContentData}(name, request.body))
    else
        !checkwrite(child, token) && return HTTP.Response(LOCKED)
        child.content = request.body
        touch(child)
    end

    return HTTP.Response(CREATED, ["Location" => string(mkhref(request, reqpath))])
end

function handle(::Val{:MOVE}, request::HTTP.Request, app::Application)
    throw("not implemented yet")

    node = traverse(app.root, request)
    isnothing(node) && return HTTP.Response(NOT_FOUND)

    token = parsetoken(request)
    overwrite = HTTP.header(request, "overwrite") == "T"
    
    # destpath::Union{String,Nothing} = HTTP.header(request, "Destination", nothing)
    # isnothing(destpath) && 
    # destpath = splitpath()

    # reqpath = splitpath(request)
    # basepath = first(reqpath, length(reqpath)-1)

    # basenode = traverse(app.root, basepath)
    # isnothing(basenode) && return HTTP.Response(FAILED_DEPENDENCY)

    HTTP.Response(NO_CONTENT)
end

function handle(::Val{:DELETE}, request::HTTP.Request, app::Application)
    node = traverse(app.root, request)
    isnothing(node) && return HTTP.Response(NOT_FOUND)
    token = parsetoken(request)
    !checkwrite(node, token) && return HTTP.Response(LOCKED)
    delete!(node)
    HTTP.Response(NO_CONTENT)
end

function parsetoken(request::HTTP.Request, key="If", pattern=r"<([^>]+)>\)?$")::Union{String,Nothing}
    token::String = HTTP.header(request, key)
    if isempty(token)
        nothing
    else
        let m = match(pattern, token)
            isnothing(m) ? nothing : m.captures[1]
        end
    end
end

mkstatusline(status=HTTP.StatusCodes.OK, version=HTTP.HTTPVersion(1, 1)) = string(
    "HTTP/", version.major, ".", version.minor, " ",
    status, " ", HTTP.statustext(status))

function mkpropfind(uri::URI, node::Node{FolderData}, props::Vector{Symbol}, depth=0)
    responses = EzXML.Node[]

    rspnode = ElementNode("response")
    push!(responses, rspnode)

    href = ElementNode("href")
    link!(href, TextNode(uristring(uri)))
    link!(rspnode, href)

    let propstat = addelement!(rspnode, "propstat")
        let prop = addelement!(propstat, "prop")
            props .|> (p) -> mkdavproperty(node, prop, p)
            addelement!(propstat, "status", mkstatusline(OK))
        end
    end

    if 0 < depth
        visit(node) do child
            append!(responses, mkpropfind(joinpath(uri, child.name), child, props, depth-1))
            nothing
        end
    end

    return responses
end

function mkpropfind(uri::URI, node::Node{ContentData}, props::Vector{Symbol}, depth=0)
    rspnode = ElementNode("response")
    link!(addelement!(rspnode, "href"), TextNode(uristring(uri)))

    let propstat = addelement!(rspnode, "propstat")
        let prop = addelement!(propstat, "prop")
            props .|> (p) -> mkdavproperty(node, prop, p)
            addelement!(propstat, "status", mkstatusline(OK))
        end
    end

    return [rspnode]
end

mkdavproperty(node::Any, parent::EzXML.Node, name::Symbol) = mkdavproperty(node, parent, Val(name))

function mkdavproperty(node::Any, parent::EzXML.Node, vname::Val{T}) where T
    value = getdavproperty(node, vname)
    if !isnothing(value)
        name = typeof(vname).parameters[1]
        addelement!(parent, string(name), string(value))
    end
end

function mkdavproperty(node::Node{FolderData}, parent::EzXML.Node, ::Val{:resourcetype})
    el = addelement!(parent, "resourcetype")
    isfolder(node) && addelement!(el, "collection")
end

getdavproperty(node::Any, name::Symbol) = getdavproperty(node, Val(name))
getdavproperty(node::Any, ::Val{S}) where S = nothing
getdavproperty(node::Node, vname::Val{S}) where S = getmetaproperty(node.meta, vname)

getdavproperty(node::Node{ContentData}, ::Val{:getcontentlength}) = length(node.content)
getdavproperty(node::Node{FolderData}, ::Val{:getcontenttype}) = "httpd/unix-directory"
getdavproperty(node::Node{ContentData}, ::Val{:getcontenttype}) = "application/octet-stream"

getmetaproperty(meta::AbstractMeta, ::Val{S}) where S = nothing
getmetaproperty(meta::CommonMeta, ::Val{:creationdate}) = Dates.format(meta.ctime, RFC1123Format) * " GMT"
getmetaproperty(meta::CommonMeta, ::Val{:getlastmodified}) = Dates.format(meta.mtime, RFC1123Format) * " GMT"
end
