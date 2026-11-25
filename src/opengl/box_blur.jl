"""
Lower Vellum's bounded BoxBlur effect into the OpenGL vector packet.
"""
module BoxBlurPlan

using ...Vellum: BoxBlur, CompositeGroup, Frame, SemanticNode, CPUBackend
using ..FrameCurves: FrameCurves

"""Physical kernel radius supported by bridges that predate the radius query."""
const LEGACY_RADIUS = 16

"""Largest physical kernel radius understood by this packet implementation."""
const MAX_RADIUS = 24

"""
    nonzero(effect) -> Bool

Return whether a group's effect needs a spatial pass. A missing effect or
a zero-radius BoxBlur uses ordinary isolated group compositing.
"""
nonzero(effect) = effect !== nothing && (effect.radius_x > 0 || effect.radius_y > 0)

"""
    validate(nodes, [depth]) -> Int

Count nonzero effects and admit a single top-level BoxBlur. Reject any
nested nonzero effect or more than one root effect with ArgumentError.
"""
function validate(nodes,depth=0)
    count = 0
    for node in nodes
        op = node.operation
        op isa CompositeGroup || continue
        if nonzero(op.effect)
            depth == 0 && count == 0 ||
                throw(ArgumentError("one top-level nonzero BoxBlur is supported"))
            count += 1
        end
        validate(op.nodes,depth+1)
    end
    return count
end

"""
    strip_effects(nodes) -> Tuple

Return effect-free semantic nodes for the sealed path and text lowerer.
Preserve draw order, IDs, revisions, opacity and blend. Effects are attached
later to the generated group exit, before submission.
"""
function strip_effects(nodes)
    return Tuple(map(node -> begin
        op = node.operation
        op isa CompositeGroup || return node
        SemanticNode(node.id,node.revision,
            CompositeGroup(strip_effects(op.nodes),op.opacity,op.blend,nothing))
    end,collect(nodes)))
end

"""
    has_effect(nodes) -> Bool

Detect effects, including zero-radius effects, in an immutable node graph.
Retains no storage and does not replace the separate placement validation.
"""
function has_effect(nodes)
    for node in nodes
        op = node.operation
        op isa CompositeGroup || continue
        (op.effect !== nothing || has_effect(op.nodes)) && return true
    end
    return false
end

"""
    support(effect, target, logical, limit) -> NTuple{2,Int}

Use the CPU's exact ceiling formula per axis. The result is in physical
pixels. Throws if a radius exceeds the profile or CPU conversion limits.
"""
function support(effect::BoxBlur,target,logical,limit)
    rx = CPUBackend.physical_radius(effect.radius_x,target[1],logical[1])
    ry = CPUBackend.physical_radius(effect.radius_y,target[2],logical[2])
    max(rx,ry) <= limit || throw(ArgumentError("physical BoxBlur radius exceeds $limit pixels"))
    return (rx,ry)
end

"""
    pack(pack_vectors, frame, size, blur_radius) -> NamedTuple

Validate effect placement and physical support. Lower an effect-free view
with a halo that preserves source-page availability for the blur pass.
Mark the exact group exit in the returned packed words. Throws for
unsupported effects, geometry, state or budgets.
"""
function pack(pack_vectors,frame::Frame,size,blur_radius)
    count = validate(frame.nodes)
    original = count == 0 ? nothing : only(node for node in frame.nodes if
        node.operation isa CompositeGroup && nonzero(node.operation.effect))
    radius = original === nothing ? (0,0) : support(original.operation.effect,size,frame.size,blur_radius)
    derived = has_effect(frame.nodes) ?
        Frame(frame.schema_version,frame.canvas,frame.revision,frame.size,
              strip_effects(frame.nodes),frame.resources) : frame
    packet = pack_vectors(derived,size,radius)
    original === nothing && return packet
    words = packet.words
    first = FrameCurves.HEADER+1
    stride = FrameCurves.COMMAND
    commands = Int(words[5])
    matching = [index for index in first:stride:first+(commands-1)*stride
        if words[index] == 2 && words[index+1] == original.id]
    length(matching) == 1 || throw(ArgumentError("packed blur group exit is ambiguous"))
    exit = only(matching)
    words[exit+3], words[exit+4] = radius
    return packet
end

end
