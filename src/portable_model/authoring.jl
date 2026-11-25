const _canvas_sequence = Threads.Atomic{UInt64}(0)

function next_revision(value::UInt64)
    value < typemax(UInt64) || model_error(:size_overflow, "revision or identifier exhausted")
    return value + UInt64(1)
end

function canvas_identity()
    while true
        old = _canvas_sequence[]
        updated = next_revision(old)
        Threads.atomic_cas!(_canvas_sequence,old,updated) == old && return updated
    end
end

"""
    Canvas(; size)

Create editable retained drawing state with positive finite logical dimensions.
Use [`transaction!`](@ref) to edit the drawing and [`snapshot`](@ref) to pass
an immutable revision to renderers. Invalid dimensions raise `ModelError`.

# Fields

- `frame` is the latest published snapshot.
- `next_node` and `next_resource` track canvas-local identifiers.
- `resource_revisions` records the latest version of each resource.
- `editing` guards against nested transactions. The `lock` serializes edits.
- `changes` describes the most recent published revision transition.
"""
mutable struct Canvas
    frame::Frame
    next_node::UInt64
    next_resource::UInt64
    resource_revisions::Dict{UInt64,UInt64}
    editing::Bool
    lock::ReentrantLock
    changes::CanvasChanges
    function Canvas(; size::Tuple{Real,Real})
        dimensions = map(nonnegative,size)
        all(>(0),dimensions) || model_error(:invalid_input, "canvas dimensions must be positive")
        id = canvas_identity()
        return new(Frame(1,id,0,dimensions,SceneNodes(nothing),()),0,0,Dict{UInt64,UInt64}(),
            false,ReentrantLock(),CanvasChanges(id,0,0,()))
    end
end

"""
    CanvasEdit

Create a mutable transaction workspace from internal canvas state. The
constructor captures `current_task()` as owner. Operations return their normal
authoring result and raise `ModelError(:invalid_state)` for foreign-task or
closed-edit use. Ownership follows the Julia task across yields and OS threads.
User code obtains an edit through `transaction!`.

# Fields

- `owner` identifies the Julia task and `canvas` the originating canvas.
- `nodes`, `resources`, and `resource_revisions` hold the candidate revision.
  An edit reads the published tuple and its revision map until its first
  resource change. Resource operations detach that storage before writing.
- `state` is the current drawing state. `stack` holds saved states.
- `next_node` and `next_resource` track identifiers within the edit.
- `active` indicates whether the edit can accept operations.
- `changed` and `child_changes` record changed nodes and nested edits.
"""
mutable struct CanvasEdit
    """Task that created the edit and can use its operations."""
    const owner::Task
    """Stable identity of the canvas being edited."""
    canvas::UInt64
    """Current persistent node tree under construction."""
    nodes::NodeBuffer
    """Published resource tuple or private editable copy of those records."""
    resources::Union{Tuple,Vector{ResourceRecord}}
    """Resource revision high-water marks. Shared while the records are a tuple."""
    resource_revisions::Dict{UInt64,UInt64}
    """Drawing state applied to the next recorded operation."""
    state::DrawingState
    """Drawing states saved by the callback and restored in reverse order."""
    stack::Vector{DrawingState}
    """Highest node ID assigned in the candidate canvas revision."""
    next_node::UInt64
    """Highest resource ID assigned in the candidate canvas revision."""
    next_resource::UInt64
    """Whether the owning callback can still use the edit."""
    active::Bool
    """IDs of directly changed nodes used to construct the commit delta."""
    changed::Set{UInt64}
    """Deltas for nested edits, keyed by their immediate layer node ID."""
    child_changes::Dict{UInt64,Tuple}

    # Keep the published tuple boxed when transferring it to the edit.
    function CanvasEdit(owner, canvas, nodes, resources, resource_revisions, state, stack,
                        next_node, next_resource, active, changed, child_changes)
        @nospecialize resources
        new(owner, canvas, nodes, resources, resource_revisions, state, stack,
            next_node, next_resource, active, changed, child_changes)
    end
end

"""
    CanvasEdit(canvas, nodes, resources, revisions, state, stack, next_node, next_resource, active)

Construct an internal child edit from its canvas ID, node/resource state,
drawing state, saved-state stack, ID counters, and active flag. Returns an edit
owned by the calling Julia task without copying its resource inputs. Tuple
inputs and their map must remain read-only; vector inputs and their map must
already be private. Foreign-task or closed-edit operations raise
`ModelError(:invalid_state)`. User code obtains edits through `transaction!`.
"""
function CanvasEdit(canvas,nodes,resources,revisions,state,stack,next_node,next_resource,active)
    @nospecialize resources
    return CanvasEdit(current_task(),canvas,node_buffer(nodes),resources,revisions,state,stack,next_node,next_resource,active,
        Set{UInt64}(),Dict{UInt64,Tuple}())
end

function node_changes(edit::CanvasEdit, before)
    return Tuple(NodeChange(id,try_node(before,id),try_node(edit.nodes.root,id),
        get(edit.child_changes,id,())) for id in sort!(collect(edit.changed)))
end

function changes(canvas::Canvas)
    lock(canvas.lock) do
        return canvas.changes
    end
end

"""
    active_edit(edit::CanvasEdit)

Check that `edit` belongs to `current_task()` and is active. Returns `nothing`;
foreign-task and closed edits raise `ModelError(:invalid_state)`. Ownership
follows the Julia task across yields and OS threads.
"""
function active_edit(edit::CanvasEdit)
    current_task() === edit.owner || model_error(:invalid_state, "edit belongs to another task")
    edit.active || model_error(:invalid_state, "edit is outside its transaction")
    return nothing
end

"""
    snapshot(canvas::Canvas) -> Frame

Return the canvas's current committed revision. The returned frame shares
immutable scene data and remains valid after later edits to the canvas.
"""
function snapshot(canvas::Canvas)
    lock(canvas.lock) do
        return canvas.frame
    end
end

"""
    transaction!(callback, canvas::Canvas)

Run `callback(edit)` with an active `CanvasEdit` and return its result.
Publish the revision only after the callback and validation succeed. A
nested transaction on the same canvas raises `ModelError`. Callback and
model errors propagate, leaving the committed canvas revision intact.
"""
function transaction!(callback, canvas::Canvas)
    lock(canvas.lock) do
        canvas.editing && model_error(:invalid_state, "nested transaction on the same canvas")
        old = canvas.frame
        edit = CanvasEdit(old.canvas,old.nodes,old.resources,
                          canvas.resource_revisions,
                          DrawingState(),DrawingState[],canvas.next_node,canvas.next_resource,true)
        canvas.editing = true
        try
            result = callback(edit)
            isempty(edit.stack) || model_error(:invalid_state, "unbalanced saved state")
            revision = next_revision(old.revision)
            frame = Frame(1,old.canvas,revision,old.size,SceneNodes(edit.nodes.root),Tuple(edit.resources))
            before = node_buffer(old.nodes)
            committed = CanvasChanges(old.canvas,old.revision,revision,node_changes(edit,before.root))
            canvas.frame = frame
            canvas.next_node,canvas.next_resource = edit.next_node,edit.next_resource
            canvas.resource_revisions = edit.resource_revisions
            canvas.changes = committed
            return result
        finally
            edit.active = false
            canvas.editing = false
        end
    end
end

"""
    writable_resources!(edit::CanvasEdit) -> nothing

Detach the shared resource tuple and revision map before a resource mutation.
Already-private working storage is unchanged. A closed or foreign-task edit
raises `ModelError(:invalid_state)`; allocation errors propagate.
"""
function writable_resources!(edit::CanvasEdit)
    active_edit(edit)
    if edit.resources isa Tuple
        records = collect(ResourceRecord,edit.resources)
        revisions = copy(edit.resource_revisions)
        edit.resources = records
        edit.resource_revisions = revisions
    end
    return nothing
end

"""
    child_edit(edit::CanvasEdit, nodes) -> CanvasEdit

Create an isolated child over `nodes`, inheriting state and identifiers.
Shared frozen storage is reused read-only; mutable parent storage and its map
are copied. Does not mutate the parent. Closed or foreign-task use raises
`ModelError(:invalid_state)`; allocation errors propagate.
"""
function child_edit(edit::CanvasEdit, nodes)
    active_edit(edit)
    if edit.resources isa Vector{ResourceRecord}
        return CanvasEdit(edit.canvas,nodes,copy(edit.resources),copy(edit.resource_revisions),
            edit.state,DrawingState[],edit.next_node,edit.next_resource,true)
    end
    return CanvasEdit(edit.canvas,nodes,edit.resources,edit.resource_revisions,
        edit.state,DrawingState[],edit.next_node,edit.next_resource,true)
end

"""
    configure!(edit::CanvasEdit; kwargs...) -> DrawingState

Set drawing-state fields for subsequent operations in this edit. For
example, set `fill`, `opacity`, or `transform` while retaining the other
fields. Use the keywords accepted by `DrawingState`. An invalid value leaves
the previous state intact. A closed or foreign-task edit raises `ModelError`.

See also [`with_state`](@ref).
"""
function configure!(edit::CanvasEdit; kwargs...)
    active_edit(edit)
    state = DrawingState(; merge(state_values(edit.state),(;kwargs...))...)
    edit.state = state
    return state
end

"""
    with_state(callback, edit::CanvasEdit; kwargs...)

Apply temporary drawing state, call `callback(edit)`, and return its result.
The previous state and save stack are restored when the callback returns or
throws. Drawing operations remain part of the enclosing transaction. Errors
from state validation and the callback propagate.

See also [`configure!`](@ref), [`transaction!`](@ref).
"""
function with_state(callback, edit::CanvasEdit; kwargs...)
    active_edit(edit)
    old = edit.state
    stack = copy(edit.stack)
    configure!(edit;kwargs...)
    try
        return callback(edit)
    finally
        edit.state = old
        edit.stack = stack
    end
end

function save(edit::CanvasEdit)
    active_edit(edit)
    push!(edit.stack,edit.state)
    return nothing
end

function restore(edit::CanvasEdit)
    active_edit(edit)
    isempty(edit.stack) && model_error(:invalid_state, "restore without save")
    edit.state = pop!(edit.stack)
    return nothing
end

"""
    transform!(edit::CanvasEdit, transform::Transform2D)

Compose `transform` onto the active edit's current transform and return the new
drawing state. Foreign-task or closed-edit use raises `ModelError(:invalid_state)`.
"""
function transform!(edit::CanvasEdit, transform::Transform2D)
    active_edit(edit)
    return configure!(edit;transform=edit.state.transform*transform)
end

function clip(edit::CanvasEdit, path::PathData; winding::Symbol=:nonzero)
    active_edit(edit)
    rule = option(winding,(:nonzero,:evenodd))
    captured = CapturedClip(path,edit.state.transform,rule)
    return configure!(edit;clips=(edit.state.clips...,captured))
end

"""Register portable `payload` in the edit and return its new `ResourceRef`. The first write detaches shared resource storage. Invalid payloads raise `ModelError(:invalid_input)`, exhausted IDs raise `ModelError(:size_overflow)`, and closed or foreign edits raise `ModelError(:invalid_state)`."""
function resource!(edit::CanvasEdit, kind::Symbol, payload::ResourcePayload)
    active_edit(edit)
    portable_payload(payload) || model_error(:invalid_input, "payload contains mutable data or native handles")
    id = next_revision(edit.next_resource)
    reference = ResourceRef(edit.canvas,id,1,kind)
    writable_resources!(edit)
    push!(edit.resources,ResourceRecord(reference,payload))
    edit.resource_revisions[id] = 1
    edit.next_resource = id
    return reference
end
function resource!(edit::CanvasEdit, image::Image)
    active_edit(edit)
    return resource!(edit,:image,ImageData(image))
end

function resolve_resource(resources, reference::ResourceRef)
    for record in resources
        record.reference == reference && return record.payload
    end
    model_error(:invalid_input, "resource revision is absent from frame")
end
resource(frame::Frame, reference::ResourceRef) = resolve_resource(frame.resources,reference)
resource(resources::Tuple, reference::ResourceRef) = resolve_resource(resources,reference)

function edit_resource(edit::CanvasEdit, reference::ResourceRef, kind::Symbol)
    reference.canvas == edit.canvas && reference.kind === kind ||
        model_error(:invalid_input, "resource belongs to another canvas or kind")
    return resolve_resource(edit.resources,reference)
end

"""Append a resource revision and return its `ResourceRef`, detaching shared storage on first write. Invalid references or payloads raise `ModelError(:invalid_input)`; stale revisions or inactive/foreign edits raise `ModelError(:invalid_state)`, and exhausted revisions raise `ModelError(:size_overflow)`."""
function revise_resource!(edit::CanvasEdit, reference::ResourceRef, payload::ResourcePayload)
    active_edit(edit)
    old = edit_resource(edit,reference,reference.kind)
    typeof(old) === typeof(payload) || model_error(:invalid_input, "resource revision changes payload type")
    portable_payload(payload) || model_error(:invalid_input, "payload contains mutable data or native handles")
    latest = edit.resource_revisions[reference.id]
    reference.revision == latest || model_error(:invalid_state, "cannot revise a stale resource")
    updated = ResourceRef(edit.canvas,reference.id,next_revision(latest),reference.kind)
    writable_resources!(edit)
    push!(edit.resources,ResourceRecord(updated,payload))
    edit.resource_revisions[reference.id] = updated.revision
    return updated
end

function references_resource(value, reference::ResourceRef)
    value isa ResourceRef && return value == reference
    value isa Union{Tuple,SceneNodes} && return any(x -> references_resource(x,reference),value)
    if value isa Union{SemanticNode,SemanticOperation,DrawingState,ResourcePayload,
                       Transform2D,Color,PaintDescriptor,GradientStop,StrokeStyle}
        return any(i -> references_resource(getfield(value,i),reference),1:fieldcount(typeof(value)))
    end
    return false
end

"""Retire an unused revision from future snapshots and return `nothing`; existing frames retain it. Invalid references raise `ModelError(:invalid_input)`, referenced resources and inactive or foreign edits raise `ModelError(:invalid_state)`."""
function release_resource!(edit::CanvasEdit, reference::ResourceRef)
    active_edit(edit)
    index = findfirst(record -> record.reference == reference,edit.resources)
    index === nothing && model_error(:invalid_input,"unknown resource revision")
    used = references_resource(SceneNodes(edit.nodes.root),reference) || references_resource(edit.state,reference) ||
           any(record -> references_resource(record.payload,reference),edit.resources)
    used && model_error(:invalid_state,"resource revision is still referenced")
    writable_resources!(edit)
    deleteat!(edit.resources,index)
    any(record -> record.reference.id == reference.id,edit.resources) ||
        delete!(edit.resource_revisions,reference.id)
    return nothing
end

function append_operation!(edit::CanvasEdit, operation::SemanticOperation)
    active_edit(edit)
    id = next_revision(edit.next_node)
    push!(edit.nodes,SemanticNode(id,1,operation))
    push!(edit.changed,id)
    edit.next_node = id
    return id
end

function lower!(edit::CanvasEdit, path::PathData; mode::Symbol=:fill, winding::Symbol=:nonzero)
    active_edit(edit)
    rule = option(winding,(:nonzero,:evenodd))
    operation = if mode === :fill
        FillPath(path,edit.state,rule)
    elseif mode === :stroke
        StrokePath(path,edit.state)
    else
        model_error(:invalid_input, "path mode must be fill or stroke")
    end
    return append_operation!(edit,operation)
end
lower!(::CanvasEdit, drawable; kwargs...) = model_error(:unsupported, "no portable lowering for $(typeof(drawable))")
"""
    draw(edit::CanvasEdit, drawable; kwargs...)

Lower `drawable` and keyword inputs into the active edit and return the lowering
result. Foreign-task or closed-edit use raises `ModelError(:invalid_state)`
before extension code runs. Ownership follows the Julia task across yields and
OS threads.
"""
function draw(edit::CanvasEdit, drawable; kwargs...)
    active_edit(edit)
    return lower!(edit,drawable;kwargs...)
end

function draw(canvas::Canvas, drawable; kwargs...)
    return transaction!(canvas) do edit
        draw!(edit,drawable;kwargs...)
    end
end

function region(value::Tuple{Real,Real,Real,Real})
    x,y,w,h = value
    return (logical(x),logical(y),nonnegative(w),nonnegative(h))
end

function draw_image!(edit::CanvasEdit, reference::ResourceRef, destination::Tuple{Real,Real,Real,Real};
                     source=nothing)
    active_edit(edit)
    image = edit_resource(edit,reference,:image)
    image isa RasterPayload || model_error(:invalid_input, "image resource is not published raster data")
    metadata = image_metadata(image)
    src = source === nothing ? (0.0,0.0,Float64(metadata.width),Float64(metadata.height)) : region(source)
    src[1] >= 0 && src[2] >= 0 && src[1]+src[3] <= metadata.width && src[2]+src[4] <= metadata.height ||
        model_error(:invalid_input, "image source region exceeds resource")
    return append_operation!(edit,ImageRegion(reference,src,region(destination),edit.state))
end

function text_glyphs(content::String, glyphs::Tuple)
    isvalid(content) || model_error(:invalid_input, "text is not valid UTF-8")
    all(g -> g isa Tuple && length(g) == 4 && g[1] isa Integer && 0 <= g[1] <= typemax(UInt32) &&
             g[4] isa Integer && 0 <= g[4] <= typemax(UInt32) &&
             g[4] < ncodeunits(content) && isvalid(content,Int(g[4])+1) &&
             g[2] isa Real && g[3] isa Real &&
             isfinite(g[2]) && isfinite(g[3]), glyphs) || model_error(:invalid_input, "invalid glyph/cluster data")
    return map(g -> (UInt32(g[1]),logical(g[2]),logical(g[3]),UInt32(g[4])),glyphs)
end

text_feature_tag(tag::Symbol) = ncodeunits(String(tag)) == 4 &&
    all(c -> 'a' <= c <= 'z' || 'A' <= c <= 'Z',String(tag))

function text_features(features::Tuple)
    seen = Set{Symbol}()
    return map(features) do feature
        if feature isa Symbol
            tag = feature # Legacy Symbols remain stored unchanged, even unsupported tags.
            result = feature
        else
            feature isa Tuple && length(feature) == 2 && feature[1] isa Symbol &&
                text_feature_tag(feature[1]) && feature[2] isa Integer && feature[2] in (0,1) ||
                model_error(:invalid_input,"invalid text feature pair")
            tag = feature[1]
            result = (tag,Int(feature[2]))
        end
        tag in seen && model_error(:invalid_input,"duplicate text feature")
        push!(seen,tag)
        return result
    end
end

function validate_text_fonts(primary, fallbacks::Tuple, resources, canvas::UInt64)
    primary === nothing && model_error(:invalid_state,"text requires a font resource")
    seen = Set{ResourceRef}()
    for reference in (primary,fallbacks...)
        reference isa ResourceRef && reference.canvas == canvas && reference.kind === :font &&
            reference.id > 0 && reference.revision > 0 ||
            model_error(:invalid_input,"invalid text font reference canvas or kind")
        reference in seen && model_error(:invalid_input,"duplicate text font reference")
        push!(seen,reference)
        resolve_resource(resources,reference) isa FontData ||
            model_error(:invalid_input,"invalid font payload")
    end
    return nothing
end

function draw_text!(edit::CanvasEdit, text::AbstractString, position::Tuple{Real,Real};
                    glyphs=(), language::AbstractString="", script::Symbol=:auto, features=(),
                    fallback_fonts=())
    active_edit(edit)
    fallbacks = Tuple(fallback_fonts)
    validate_text_fonts(edit.state.font,fallbacks,edit.resources,edit.canvas)
    content = String(text)
    captured = text_glyphs(content,Tuple(glyphs))
    tags = text_features(Tuple(features))
    return append_operation!(edit,TextRun(content,map(logical,position),edit.state,captured,
                                         String(language),script,tags,fallbacks))
end

function clear_region!(edit::CanvasEdit, rectangle::Tuple{Real,Real,Real,Real})
    active_edit(edit)
    return append_operation!(edit,ClearRegion(region(rectangle),edit.state))
end

function compose_surface!(edit::CanvasEdit, reference::ResourceRef, destination::Tuple{Real,Real,Real,Real})
    active_edit(edit)
    edit_resource(edit,reference,:surface) isa SurfaceData || model_error(:invalid_input, "invalid surface resource")
    return append_operation!(edit,SurfaceRegion(reference,region(destination),edit.state))
end

"""Run `callback(child)` in an isolated group and return its node ID. Child resources publish on success; callback errors propagate and an unbalanced stack raises `ModelError(:invalid_state)`. Invalid options raise `ModelError`; unsupported effects raise `ModelError(:unsupported)`."""
function with_group(callback, edit::CanvasEdit; opacity::Real=1, blend::Symbol=:source_over, effect=nothing)
    active_edit(edit)
    alpha,mode = unit_interval(opacity),option(blend,(:source_over,:multiply))
    effect === nothing || effect isa BoxBlur ||
        model_error(:unsupported,"unsupported group effect; expected nothing or BoxBlur")
    child = child_edit(edit,SemanticNode[])
    try
        callback(child)
        isempty(child.stack) || model_error(:invalid_state, "unbalanced group state")
        id = next_revision(child.next_node)
        push!(edit.nodes,SemanticNode(id,1,CompositeGroup(SceneNodes(child.nodes.root),alpha,mode,effect)))
        push!(edit.changed,id)
        edit.next_node,edit.next_resource,edit.resources = id,child.next_resource,child.resources
        edit.resource_revisions = child.resource_revisions
        return id
    finally
        child.active = false
    end
end

function remove_node!(edit::CanvasEdit, id::Integer)
    active_edit(edit)
    old = find_node(edit.nodes.root,id)
    edit.nodes.root = delete_node(edit.nodes.root,id)
    push!(edit.changed,old.id)
    delete!(edit.child_changes,old.id)
    return nothing
end

"""Replace a node using an isolated lowering edit and return its ID. Lowering errors propagate; missing nodes, inactive edits, or a replacement that does not produce exactly one node raise `ModelError`."""
function replace_node!(edit::CanvasEdit, id::Integer, drawable; kwargs...)
    active_edit(edit)
    old = find_node(edit.nodes.root,id)
    child = child_edit(edit,SemanticNode[])
    try
        lower!(child,drawable;kwargs...)
        length(child.nodes) == 1 || model_error(:invalid_input, "replacement must lower to one node")
        node = SemanticNode(old.id,next_revision(old.revision),only(child.nodes).operation)
        push!(edit.nodes,node)
        push!(edit.changed,node.id)
        delete!(edit.child_changes,node.id)
        edit.resources,edit.next_resource,edit.next_node = child.resources,child.next_resource,child.next_node
        edit.resource_revisions = child.resource_revisions
        return node.id
    finally
        child.active = false
    end
end
