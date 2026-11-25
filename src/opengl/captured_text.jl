"""Lower captured glyphs to private outline fills for the native GPU adapters."""
module GLText

import ...Vellum
using ...Vellum: Frame, TextRun, SemanticNode, FillPath, StrokePath, ClearRegion, CompositeGroup, ImageRegion
using ..FrameCurves: BRIDGE_LIMITS

"""Per-run limit on outline commands before the donor's separate geometry limits."""
const OUTLINE_COMMANDS = BRIDGE_LIMITS.outline

"""
    neutral_text_child(operation) -> Union{Nothing,SemanticNode}

Return the only child of an effect-free, unit-opacity source-over group when
that child is a source-over text run. Drawing one such run into transparent
storage and composing the result at unit opacity leaves its source pixels
unchanged. Return `nothing` for all other operations.
"""
function neutral_text_child(operation)
    operation isa CompositeGroup && operation.effect === nothing &&
        operation.opacity == 1 && operation.blend === :source_over &&
        length(operation.nodes) == 1 || return nothing
    child = only(operation.nodes)
    child.operation isa TextRun && child.operation.state.blend === :source_over || return nothing
    return child
end

"""
    outline_nodes(nodes, source::Frame, slots, depth) -> Tuple

Derive nonzero outline fills for captured `TextRun` operations while
preserving their node IDs, revisions and drawing state. Drop neutral
single-run text groups and retain all other groups and their effects.
Track the native command budget in `slots` and the remaining group depth.
Throw `ArgumentError` for unsupported operations or exhausted limits.
Invalid font references, glyph IDs and outline geometry are rejected by Vellum.
"""
function outline_nodes(nodes, source::Frame, slots, depth, limits=BRIDGE_LIMITS)
    length(nodes) <= slots[] || throw(ArgumentError("command budget exceeded"))
    return Tuple(map(collect(nodes)) do original
        child = neutral_text_child(original.operation)
        node = child === nothing ? original : child
        op = node.operation
        slots[] -= op isa CompositeGroup ? 2 : 1
        slots[] >= 0 || throw(ArgumentError("command budget exceeded"))
        if op isa TextRun
            0 < length(op.glyphs) <= limits.glyphs || throw(ArgumentError("captured glyph count outside packet profile"))
            isempty(op.fallback_fonts) || throw(ArgumentError("use separate captured face runs"))
            path = Vellum._portable_text_path(op, source, node.id; max_commands=limits.outline)
            SemanticNode(node.id, node.revision, FillPath(path, op.state, :nonzero))
        elseif op isa CompositeGroup
            depth < limits.depth || throw(ArgumentError("unsupported group depth"))
            children = outline_nodes(op.nodes, source, slots, depth + 1, limits)
            SemanticNode(node.id, node.revision, CompositeGroup(children, op.opacity, op.blend, op.effect))
        else
            op isa Union{FillPath,StrokePath,ClearRegion,ImageRegion} ||
                throw(ArgumentError("unsupported operation"))
            node
        end
    end)
end

"""
    unchanged_nodes(nodes, slots, depth) -> Bool

Validate the same command, operation and group-depth limits as outlining.
Return `false` when text needs rewriting so the outliner can validate
and lower the entire graph. Update the caller's command counter for nodes
visited during the scan.
"""
function unchanged_nodes(nodes,slots,depth,limits=BRIDGE_LIMITS)
    length(nodes) <= slots[] || throw(ArgumentError("command budget exceeded"))
    for node in nodes
        op = node.operation
        op isa TextRun && return false
        neutral_text_child(op) === nothing || return false
        slots[] -= op isa CompositeGroup ? 2 : 1
        slots[] >= 0 || throw(ArgumentError("command budget exceeded"))
        if op isa CompositeGroup
            depth < limits.depth || throw(ArgumentError("unsupported group depth"))
            unchanged_nodes(op.nodes,slots,depth+1,limits) || return false
        else
            op isa Union{FillPath,StrokePath,ClearRegion,ImageRegion} ||
                throw(ArgumentError("unsupported operation"))
        end
    end
    return true
end

"""
    outline_frame(source::Frame) -> Frame

Validate the source and return an outline-only execution snapshot for the
GPU adapter. A scene without text can reuse its immutable frame. Outlining
preserves source identity, resources and logical size. Propagate unsupported
or invalid outline errors before packing.
"""
function outline_frame(source::Frame,limits=BRIDGE_LIMITS)
    unchanged_nodes(source.nodes,Ref(limits.commands),0,limits) && return source
    return Frame(source.schema_version, source.canvas, source.revision, source.size,
        outline_nodes(source.nodes, source, Ref(limits.commands), 0, limits), source.resources)
end

end
