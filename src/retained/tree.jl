"""Persistent ordered AVL tree; edits share untouched subtrees and raster payloads."""
struct SceneTree
    node::SemanticNode
    left::Union{Nothing,SceneTree}
    right::Union{Nothing,SceneTree}
    height::Int
    count::Int
    bounds::Union{Nothing,SceneBounds}
    support::Int
    own_bounds::Union{Nothing,SceneBounds}
    own_support::Int
end
tree_height(tree) = tree === nothing ? 0 : tree.height
tree_count(tree) = tree === nothing ? 0 : tree.count
tree_bounds(tree) = tree === nothing ? nothing : tree.bounds
tree_support(tree) = tree === nothing ? 0 : tree.support
function scene_tree(node, left, right, bounds, support)
    return SceneTree(node,left,right,1+max(tree_height(left),tree_height(right)),
        1+tree_count(left)+tree_count(right),
        union_bounds(bounds,union_bounds(tree_bounds(left),tree_bounds(right))),
        max(support,tree_support(left),tree_support(right)),bounds,support)
end
scene_tree(node, left=nothing, right=nothing) =
    scene_tree(node,left,right,operation_bounds(node.operation),support_depth(node.operation))
rebuild_tree(tree, left, right) =
    scene_tree(tree.node,left,right,tree.own_bounds,tree.own_support)
function rotate_left(tree)
    right = tree.right
    return rebuild_tree(right,rebuild_tree(tree,tree.left,right.left),right.right)
end
function rotate_right(tree)
    left = tree.left
    return rebuild_tree(left,left.left,rebuild_tree(tree,left.right,tree.right))
end
function balance_tree(tree)
    delta = tree_height(tree.left)-tree_height(tree.right)
    if delta > 1
        left = tree.left
        tree_height(left.left) < tree_height(left.right) &&
            (tree = rebuild_tree(tree,rotate_left(left),tree.right))
        return rotate_right(tree)
    elseif delta < -1
        right = tree.right
        tree_height(right.right) < tree_height(right.left) &&
            (tree = rebuild_tree(tree,tree.left,rotate_right(right)))
        return rotate_left(tree)
    end
    return tree
end
function put_node(tree, node)
    tree === nothing && return scene_tree(node)
    node.id == tree.node.id && return scene_tree(node,tree.left,tree.right)
    return balance_tree(node.id < tree.node.id ?
        rebuild_tree(tree,put_node(tree.left,node),tree.right) :
        rebuild_tree(tree,tree.left,put_node(tree.right,node)))
end
function find_node(tree, id)
    while tree !== nothing
        id == tree.node.id && return tree.node
        tree = id < tree.node.id ? tree.left : tree.right
    end
    model_error(:invalid_input,"unknown top-level node")
end
function try_node(tree, id)
    while tree !== nothing
        id == tree.node.id && return tree.node
        tree = id < tree.node.id ? tree.left : tree.right
    end
    return nothing
end
function delete_node(tree, id)
    tree === nothing && model_error(:invalid_input,"unknown top-level node")
    if id < tree.node.id
        return balance_tree(rebuild_tree(tree,delete_node(tree.left,id),tree.right))
    elseif id > tree.node.id
        return balance_tree(rebuild_tree(tree,tree.left,delete_node(tree.right,id)))
    end
    tree.left === nothing && return tree.right
    tree.right === nothing && return tree.left
    successor = tree.right
    while successor.left !== nothing
        successor = successor.left
    end
    return balance_tree(rebuild_tree(successor,tree.left,delete_node(tree.right,successor.node.id)))
end
function node_at(tree, index::Int)
    1 <= index <= tree_count(tree) || throw(BoundsError())
    left = tree_count(tree.left)
    index == left+1 && return tree.node
    return index <= left ? node_at(tree.left,index) : node_at(tree.right,index-left-1)
end

struct SceneNodes <: AbstractVector{SemanticNode}
    root::Union{Nothing,SceneTree}
end
Base.size(nodes::SceneNodes) = (tree_count(nodes.root),)
Base.getindex(nodes::SceneNodes, index::Int) = node_at(nodes.root,index)
Base.IndexStyle(::Type{SceneNodes}) = IndexLinear()
function tree_stack!(stack, tree)
    while tree !== nothing
        push!(stack,tree)
        tree = tree.left
    end
    return stack
end
function iterate_tree!(stack)
    isempty(stack) && return nothing
    tree = pop!(stack)
    tree_stack!(stack,tree.right)
    return (tree.node,stack)
end
Base.iterate(nodes::SceneNodes) = iterate_tree!(tree_stack!(SceneTree[],nodes.root))
Base.iterate(::SceneNodes, stack::Vector{SceneTree}) = iterate_tree!(stack)
mutable struct NodeBuffer
    root::Union{Nothing,SceneTree}
end
Base.length(nodes::NodeBuffer) = tree_count(nodes.root)
Base.isempty(nodes::NodeBuffer) = nodes.root === nothing
Base.iterate(nodes::NodeBuffer) = iterate(SceneNodes(nodes.root))
Base.iterate(::NodeBuffer, stack::Vector{SceneTree}) = iterate_tree!(stack)
function Base.push!(nodes::NodeBuffer, node::SemanticNode)
    nodes.root = put_node(nodes.root,node)
    return nodes
end
function node_buffer(nodes)
    nodes isa SceneNodes && return NodeBuffer(nodes.root)
    result = NodeBuffer(nothing)
    for node in nodes
        push!(result,node)
    end
    return result
end

"""Spatial broad phase in compositing order; subtree bounds prune unrelated content."""
function query_nodes(frame, rectangle::Tuple{Real,Real,Real,Real}; scale=(1,1))
    x,y,w,h = region(rectangle)
    target = (x,y,logical(x+w),logical(y+h))
    padding = physical_padding(scale)
    result = SemanticNode[]
    query_tree!(result,node_buffer(frame.nodes).root,target,padding)
    return result
end
function query_tree!(result, tree, target, padding)
    tree === nothing && return nothing
    box = expand_bounds(tree.bounds,padding[1]*tree.support,padding[2]*tree.support)
    intersects_bounds(box,target) || return nothing
    query_tree!(result,tree.left,target,padding)
    node = tree.node
    box = expand_bounds(tree.own_bounds,
        padding[1]*tree.own_support,padding[2]*tree.own_support)
    intersects_bounds(box,target) && push!(result,node)
    query_tree!(result,tree.right,target,padding)
    return nothing
end

"""Prune a snapshot for rendering only `rectangle`; the rectangle is an output crop, not a clip.

Effects retain their expanded input neighborhood, including content outside the crop.
Never use this derived snapshot for rendering outside the requested rectangle.
"""
function region_snapshot(frame, rectangle::Tuple{Real,Real,Real,Real}; scale=(1,1))
    x,y,w,h = region(rectangle)
    target = (x,y,logical(x+w),logical(y+h))
    padding = physical_padding(scale)
    nodes = region_nodes(frame.nodes,target,padding)
    return Frame(frame.schema_version,frame.canvas,frame.revision,frame.size,nodes,frame.resources)
end
function region_nodes(nodes, target, padding)
    candidates = SemanticNode[]
    query_tree!(candidates,node_buffer(nodes).root,target,padding)
    return Tuple(map(candidates) do node
        group = node.operation
        group isa CompositeGroup || return node
        effect = group.effect
        input = effect === nothing ? target :
            expand_bounds(target,logical(effect.radius_x+padding[1]),logical(effect.radius_y+padding[2]))
        children = region_nodes(group.nodes,input,padding)
        SemanticNode(node.id,node.revision,CompositeGroup(children,group.opacity,group.blend,effect))
    end)
end

struct NodeChange
    id::UInt64
    before::Union{Nothing,SemanticNode}
    after::Union{Nothing,SemanticNode}
    children::Tuple
end
struct CanvasChanges
    canvas::UInt64
    before::UInt64
    revision::UInt64
    nodes::Tuple
end
function damage(changes::CanvasChanges; scale=(1,1))
    physical_padding(scale)
    box = nothing
    for change in changes.nodes
        box = union_bounds(box,change_damage(change,scale))
    end
    return box
end
function change_damage(change::NodeChange, scale)
    if !isempty(change.children)
        box = nothing
        for child in change.children
            box = union_bounds(box,change_damage(child,scale))
        end
        group = change.after.operation
        effect = group.effect
        if effect !== nothing
            x,y = physical_padding(scale)
            box = expand_bounds(box,logical(effect.radius_x+x),logical(effect.radius_y+y))
        end
        return box
    end
    box = nothing
    for node in (change.before,change.after)
        node === nothing || (box = union_bounds(box,raster_bounds(node,scale)))
    end
    return box
end
