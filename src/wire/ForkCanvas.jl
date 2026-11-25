"""
    fork_canvas(snapshot::Snapshot) -> Canvas

Open a validated Wire scene as an independently editable canvas. The new
canvas assigns its own node and resource IDs and preserves paint order at
every depth. Live resource revisions keep their order and revision numbers.
The canvas shares immutable payloads, including embedded font and image bytes.

Transport history, unpublished edits, and application undo state stay with
the original session. For external raster data, keep the archive resolver
open and supply it to the renderer. The canvas owns no archive leases.

A closed external snapshot or invalid scene raises `ArgumentError`.
Model errors propagate without modifying the supplied snapshot.
"""
function fork_canvas(snapshot::Snapshot)
    bindings = snapshot_bindings(snapshot)
    frame = snapshot.frame
    nodes = tree_nodes(frame.nodes)
    check(length(frame.resources) <= MAX_RESOURCES, "resource count limit")
    records = Dict{ResourceKey,V.ResourcePayload}()
    for record in frame.resources
        old = record.reference
        key = resourcekey(old)
        check(old.canvas == frame.canvas && old.id > 0 && old.revision > 0,
              "invalid resource identity")
        check(!haskey(records, key), "duplicate resource revision")
        if record.payload isa V.RasterReference
            check(bindings !== nothing && haskey(bindings, key) &&
                  bindings[key].descriptor == record.payload, "missing or invalid raster binding")
        end
        records[key] = record.payload
    end
    for node in nodes
        valid_node(node, records, frame.canvas)
    end

    canvas = V.Canvas(size=frame.size)
    # An archive created in another process may already use the next local ID.
    if V.snapshot(canvas).canvas == frame.canvas
        canvas = V.Canvas(size=frame.size)
    end
    V.transaction!(canvas) do edit
        refs = fork_resources!(edit, frame.resources)
        fork_nodes!(edit, frame.nodes, refs)
    end
    return canvas
end

"""
    fork_resources!(edit, records) -> Dict{ResourceRef,ResourceRef}

Import live resource records into an empty edit and return the old-to-new
reference lookup. A single new ID represents all live revisions of each old
ID. The frozen record tuple can be shared by the subsequent group edits.
Resource and identifier errors propagate from the model.
"""
function fork_resources!(edit::V.CanvasEdit, records::Tuple)
    ids = Dict{UInt64,UInt64}()
    refs = Dict{V.ResourceRef,V.ResourceRef}()
    imported = V.ResourceRecord[]
    sizehint!(imported, length(records))
    for record in records
        old = record.reference
        id = get!(ids, old.id) do
            V.resource!(edit, old.kind, record.payload).id
        end
        ref = V.ResourceRef(edit.canvas, id, old.revision, old.kind)
        refs[old] = ref
        push!(imported, V.ResourceRecord(ref, record.payload))
        edit.resource_revisions[id] = max(edit.resource_revisions[id], old.revision)
    end
    edit.resources = Tuple(imported)
    return refs
end

"""
    fork_nodes!(edit, nodes, refs) -> Nothing

Append validated nodes in depth-first paint order, preserving groups and
replacing canvas-scoped references with entries in `refs`. Missing
references and unsupported operations raise `ArgumentError`. Validation
and edit lifecycle errors propagate from the transaction.
"""
function fork_nodes!(edit::V.CanvasEdit, nodes, refs::Dict{V.ResourceRef,V.ResourceRef})
    rebind(ref) = get(refs, ref) do
        throw(ArgumentError("wire: missing resource revision"))
    end
    for node in nodes
        op = node.operation
        if op isa V.CompositeGroup
            id = V.with_group(edit; opacity=op.opacity, blend=op.blend, effect=op.effect) do _
                nothing
            end
            V.edit_layer!(edit, id) do child
                fork_nodes!(child, op.nodes, refs)
            end
            continue
        end
        state = op.state
        if state.font !== nothing
            state = V.DrawingState(; merge(V.state_values(state), (font=rebind(state.font),))...)
        end
        converted = if op isa V.FillPath
            V.FillPath(op.path, state, op.winding)
        elseif op isa V.StrokePath
            V.StrokePath(op.path, state)
        elseif op isa V.ImageRegion
            V.ImageRegion(rebind(op.image), op.source, op.destination, state)
        elseif op isa V.ClearRegion
            V.ClearRegion(op.rectangle, state)
        elseif op isa V.TextRun
            V.TextRun(op.text, op.position, state, op.glyphs, op.language, op.script,
                      op.features, map(rebind, op.fallback_fonts))
        else
            throw(ArgumentError("wire: unsupported required operation $(typeof(op))"))
        end
        V.append_operation!(edit, converted)
    end
    return nothing
end
