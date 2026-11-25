function put_operation!(edit::CanvasEdit, old::SemanticNode, operation::SemanticOperation)
    active_edit(edit)
    node = SemanticNode(old.id,next_revision(old.revision),operation)
    push!(edit.nodes,node)
    push!(edit.changed,node.id)
    delete!(edit.child_changes,node.id)
    return node.id
end

"""Change one retained object's state, or a layer's opacity/blend/effect, preserving its ID."""
function update_node!(edit::CanvasEdit, id::Integer; kwargs...)
    active_edit(edit)
    old = find_node(edit.nodes.root,id)
    operation = old.operation
    updated = if operation isa CompositeGroup
        values = merge((opacity=operation.opacity,blend=operation.blend,effect=operation.effect),(;kwargs...))
        CompositeGroup(operation.nodes;values...)
    else
        state = DrawingState(;merge(state_values(operation.state),(;kwargs...))...)
        values = map(name -> name === :state ? state : getfield(operation,name),fieldnames(typeof(operation)))
        typeof(operation)(values...)
    end
    return put_operation!(edit,old,updated)
end
CompositeGroup(nodes; opacity=1, blend=:source_over, effect=nothing) =
    CompositeGroup(nodes,opacity,blend,effect)

"""Edit a persistent ordered layer and return the callback result. Child changes publish on success; callback errors propagate, invalid IDs or non-layers raise `ModelError`, and unbalanced or inactive edits raise `ModelError(:invalid_state)`."""
function edit_layer!(callback, edit::CanvasEdit, id::Integer)
    active_edit(edit)
    old = find_node(edit.nodes.root,id)
    group = old.operation
    group isa CompositeGroup || model_error(:invalid_input,"node is not a layer")
    child = child_edit(edit,group.nodes,old.id)
    try
        result = with_child_edit(callback,child)
        isempty(child.stack) || model_error(:invalid_state,"unbalanced layer state")
        operation = CompositeGroup(SceneNodes(child.nodes.root),group.opacity,group.blend,group.effect)
        previous = get(edit.child_changes,old.id,())
        narrowed = !(old.id in edit.changed) || haskey(edit.child_changes,old.id)
        delta = node_changes(child,node_buffer(group.nodes).root)
        put_operation!(edit,old,operation)
        narrowed && (edit.child_changes[old.id] = (previous...,delta...))
        edit.next_node,edit.next_resource = child.next_node,child.next_resource
        edit.resources,edit.resource_revisions = child.resources,child.resource_revisions
        return result
    finally
        child.active = false
    end
end
