abstract type AbstractData end
abstract type AbstractMeta end

mutable struct Node{NodeData <: AbstractData, NodeMeta <: AbstractMeta}
    parent::Union{Node,Nothing}
    next::Union{Node,Nothing}
    name::String
    data::NodeData
    meta::NodeMeta
end

mutable struct FolderData <: AbstractData
    first_child::Union{Node,Nothing}
end

FolderData() = FolderData(nothing)

mutable struct ContentData <: AbstractData
    content::Vector{UInt8}
end

mutable struct Lock
    depth::Integer
    token::String
end

mutable struct CommonMeta <: AbstractMeta
    ctime::DateTime
    mtime::DateTime
    lock::Union{Lock,Nothing}
end

CommonMeta() = (now = Dates.now(UTC); CommonMeta(now, now, nothing))

Node{NodeData}(parent::Union{Node,Nothing}, name::AbstractString, data::NodeData) where {NodeData<:AbstractData} =
    Node{NodeData,CommonMeta}(parent, nothing, String(name), data, CommonMeta())

Node{NodeData}(name::AbstractString) where {NodeData<:AbstractData} =
    Node{NodeData}(nothing, name, NodeData())

Root() = Node{FolderData}("root")

Node{ContentData}(name::AbstractString, content::Vector{UInt8}=UInt8[]) =
    Node{ContentData}(nothing, name, ContentData(content))

Node{ContentData}(name::AbstractString, content::String) =
    Node{ContentData}(name, Vector{UInt8}(content))

Node{ContentData}(name::AbstractString, content::Base.CodeUnits{UInt8, String}) =
    Node{ContentData}(name, convert(Vector{UInt8}, content))

Base.show(io::IO, node::Node) = print(io, "Node($(node.name))")
Base.show(io::IO, node::Node{FolderData}) = print(io, "Node{FolderData}($(node.name))")
Base.summary(io::IO, node::Node{FolderData}) = print(io, "$(length(node))-element Node{FolderData}($(node.name))")

isfolder(node::Node) = false
isfolder(node::Node{FolderData}) = true

function Base.empty!(node::Node) end

Base.propertynames(node::Node{FolderData}) = (:first_child, fieldnames(typeof(node))...)

function Base.getproperty(node::Node{FolderData}, name::Symbol)
    name === :first_child && return getfield(node, :data).first_child
    return getfield(node, name)
end

function Base.setproperty!(node::Node{FolderData}, name::Symbol, value)
    name === :first_child && return setfield!(getfield(node, :data), :first_child, value)
    return setfield!(node, name, value)
end

Base.isempty(node::Node{FolderData}) = !isnothing(node.first_child)

function visit(f::Function, node::Node{FolderData})
    child = node.first_child
    while !isnothing(child)
        next = child.next
        result = f(child)
        !isnothing(result) && return result
        child = next
    end
end

function Base.length(node::Node{FolderData})
    count = 0
    visit(node) do child
        count += 1
        nothing
    end
    count
end

Base.lastindex(node::Node{FolderData}) = length(node)

function Base.getindex(node::Node{FolderData}, index::Integer)
    if 0 < index
        count = 0
        child = visit(node) do child
            count += 1
            index == count && return child
            nothing
        end
        !isnothing(child) && return child
    end
    throw(BoundsError(node, index))
end

function Base.empty!(node::Node{FolderData})
    visit(node) do child
        child.parent = nothing
        child.next = nothing
        empty!(child)
    end
    node.first_child = nothing
    node
end

function Base.push!(node::Node{FolderData}, child::Node)
    @assert isnothing(child.next) "new child $(child) already has a next node"
    @assert isnothing(child.parent) "new child $(child) already has a parent node"
    if isnothing(node.first_child)
        node.first_child = child
    else
        last_child = node.first_child
        while !isnothing(last_child.next)
            last_child = last_child.next
        end
        last_child.next = child            
    end
    child.parent = node
    node
end

function Base.delete!(node::Node{FolderData}, name::AbstractString)
    child = findfirst(name, node)
    !isnothing(child) && delete!(node, child)
    node
end

function Base.delete!(node::Node{FolderData}, child::Node)
    @assert child.parent === node

    if node.first_child === child
        node.first_child = child.next
    else
        prev_child = node.first_child
        while !isnothing(prev_child.next)
            if prev_child.next === child
                prev_child.next = child.next
                break
            end
            prev_child = prev_child.next
        end
    end

    child.parent = nothing
    child.next = nothing

    node
end

function Base.delete!(child::Node)
    delete!(child.parent, child)
end

function Base.findfirst(name::AbstractString, node::Node{FolderData})::Union{Node,Nothing}
    return visit(node) do child
        child.name == name ? child : nothing
    end
end

Base.in(name::AbstractString, node::Node{FolderData}) = !isnothing(findfirst(name, node))
Base.propertynames(node::Node{ContentData}) = (:content, fieldnames(typeof(node))...)
    
function Base.getproperty(node::Node{ContentData}, name::Symbol)
    name === :content && return getfield(node, :data).content
    return getfield(node, name)
end

function Base.setproperty!(node::Node{ContentData}, name::Symbol, value)
    name === :content && return setfield!(getfield(node, :data), :content, value)
    return setfield!(node, name, value)
end

function Base.abspath(node::Node)::String
    path = String[]
    while !isnothing(node.parent)
        insert!(path, 1, node.name)
        node = node.parent
    end
    '/' * join(path, '/')
end

touch(node::Node{D,M}) where {D,M} = nothing
touch(node::Node{D,CommonMeta}) where D = (node.meta.mtime = Dates.now(UTC); nothing)

function getlock(node::Node{D,CommonMeta}) where D
    depth = 0
    while !isnothing(node)
        if !isnothing(node.meta.lock) && depth <= node.meta.lock.depth
            return node.meta.lock
        end
        node = node.parent
    end
end

function islocked(node::Node{D,CommonMeta}) where D
    !isnothing(getlock(node))
end

function lock(node::Node{D,CommonMeta}, depth=0) where D
    @assert !islocked(node)
    node.meta.lock = Lock(depth, string("urn:uuid:", UUIDs.uuid4()))
end

function unlock(node::Node{D,CommonMeta}, token::AbstractString) where D
    if !isnothing(node.meta.lock) && node.meta.lock.token == token
        lock = node.meta.lock
        node.meta.lock = nothing
        lock
    end
end

function checkwrite(node::Node{D,CommonMeta}, token::AbstractString) where D
    lock = getlock(node)
    isnothing(lock) || lock.token == token
end

function checkwrite(node::Node{D,CommonMeta}, ::Nothing) where D
    lock = getlock(node)
    isnothing(lock)
end
