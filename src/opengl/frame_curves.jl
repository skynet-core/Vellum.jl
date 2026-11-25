"""Pack portable paths and drawing state for the offscreen OpenGL shader."""
module FrameCurves

import ...Vetra
using ...Vetra: Solid, rectangle_path
using ..RasterAssets: RasterAssets
using ..RasterPages: RasterPages

"""Alias for the portable types used by the packer."""
const V = Vetra
"""Geometry lowerer shared with the CPU backend."""
const G = V.PortableGeometry
"""Word count in the packed frame header."""
const HEADER = 10
"""Words per command record."""
const COMMAND = 14
"""Words per shape record."""
const SHAPE = 8
"""Words per contour record."""
const CONTOUR = 6
"""Words per paint-stop record."""
const STOP = 5
"""Format identifier at the front of the packed word buffer."""
const MAGIC = 20261122
"""Maximum packed commands, including group markers."""
const MAX_COMMANDS = 32
"""Maximum packed drawing and clip shapes."""
const MAX_SHAPES = 64
"""Maximum packed contours across shapes within the native record buffer."""
const MAX_CONTOURS = 4096
"""Maximum packed position pairs before the shared 512 KiB packet budget."""
const MAX_POINTS = 32_768
"""Maximum premultiplied paint stops across the frame."""
const MAX_STOPS = 128
"""Largest absolute physical geometry coordinate in the extended bridge packet."""
const COORDINATE_LIMIT = 16384

"""Neutral-paint physical geometry retained under its exact lowering inputs."""
struct CachedShape
    path::V.PathData
    transform::V.Transform2D
    tolerance::Float64
    winding::Symbol
    stroke::Union{Nothing,V.StrokeStyle}
    geometry::G.PreparedGeometry
end

"""One optional cache entry per packed shape. Published vectors are read-only."""
const ShapeCache = Vector{Union{Nothing,CachedShape}}
"""Empty cache for a new target or isolated packet builds."""
const EMPTY_SHAPES = ShapeCache()
"""Neutral paint used for geometry whose actual paint is validated separately."""
const GEOMETRY_PAINT = Solid(0,0,0)

"""
One contiguous, reusable run of packed clips. Exact captured state, viewport,
and lowering tolerance identify the run. Its bounds are the intersection of
all clip shapes, or `nothing` when no samples can pass.
"""
struct ClipSpan
    clips::Tuple
    viewport::V.Transform2D
    tolerance::Float64
    first::Int
    bounds::Union{Nothing,NTuple{4,Float64}}
end

"""
    Workspace()

Exclusive owner-thread scratch for native packet tables and page resolution.
One pack at a time can use a workspace. Each pack clears its tables and
reuses their capacity, including after an error. The result owns its own
words, resident maps, and shape cache. Admission bounds still apply, including the
512 KiB limit on a complete packet with its page lookups.
"""
struct Workspace
    """Draw commands and group markers in scene order."""
    commands::Vector{Float64}
    """Shape offsets, fill rules and physical bounds."""
    shapes::Vector{Float64}
    """Contour ranges and physical bounds, grouped by shape."""
    contours::Vector{Float64}
    """Alternating x and y physical coordinates."""
    points::Vector{Float64}
    """Premultiplied color stops in paint order."""
    stops::Vector{Float64}
    """Dense and paged image draw descriptors."""
    rasters::Vector{Float64}
    """Reusable row-ordered source lookups for the current packet."""
    page_lookups::Vector{RasterPages.PageLookup}
    """Reusable first-encounter source keys. Published maps have separate ownership."""
    page_keys::Vector{RasterPages.TileKey}
    """Physical slots in the order of the reusable keys."""
    page_slots::Vector{Int}
end

"""Create empty, exclusively owned packet-table scratch."""
Workspace() = Workspace(Float64[],Float64[],Float64[],Float64[],Float64[],Float64[],
    RasterPages.PageLookup[],RasterPages.TileKey[],Int[])

"""Growable word tables for a single frame. Offsets are zero-based in the shader."""
mutable struct Packing{C<:Union{Nothing,ShapeCache}}
    commands::Vector{Float64}
    shapes::Vector{Float64}
    contours::Vector{Float64}
    points::Vector{Float64}
    stops::Vector{Float64}
    rasters::Vector{Float64}
    page_selection::RasterPages.Selection
    previous_shapes::C
    retained_shapes::C
    clip_spans::Union{Nothing,Vector{ClipSpan}}
end
"""Start empty frame tables with the given source capacity and read-only geometry cache."""
Packing(capacity=RasterPages.CAPACITY,shared=nothing,previous=EMPTY_SHAPES) =
    Packing(Float64[],Float64[],Float64[],Float64[],Float64[],Float64[],
        RasterPages.Selection(capacity,shared),previous,previous === nothing ? nothing : ShapeCache(),nothing)

"""
    Packing(workspace, capacity, shared, previous)

Reset exclusive intermediate tables and page vectors for one pack. The
candidate slot dictionary and geometry cache have their own storage.
The next pack can reuse the workspace after an error.
Normal packet and source admission limits still apply.
"""
function Packing(workspace::Workspace,capacity,shared,previous)
    for table in (workspace.commands,workspace.shapes,workspace.contours,
                  workspace.points,workspace.stops,workspace.rasters)
        empty!(table)
    end
    empty!(workspace.page_lookups)
    empty!(workspace.page_keys)
    selection = RasterPages.Selection(workspace.page_lookups,Dict{RasterPages.TileKey,Int}(),
        workspace.page_keys,0,false,capacity,shared)
    return Packing(workspace.commands,workspace.shapes,workspace.contours,
        workspace.points,workspace.stops,workspace.rasters,
        selection,previous,
        previous === nothing ? nothing : ShapeCache(),nothing)
end

"""Require an admission condition, raising `ArgumentError` with its reason."""
check(ok, what) = ok || throw(ArgumentError(what))

"""
    append_shape!(p, geometry) -> Int

Append contours and their bounds from prepared geometry and return the
zero-based shape index. Invalid coordinates or exceeded limits raise
`ArgumentError`. The caller discards the scratch packing after a failure.
"""
function append_shape!(p, geometry, cached=nothing)
    shape = length(p.shapes) ÷ SHAPE
    check(shape < MAX_SHAPES, "geometry count exceeds profile")
    first = length(p.contours) ÷ CONTOUR
    for contour in geometry.contours
        n = length(contour.points)
        start = length(p.points) ÷ 2
        check(length(p.contours) ÷ CONTOUR < MAX_CONTOURS &&
              start+n <= MAX_POINTS, "contour and point budget exceeded")
        n > 0 || continue
        xmin,ymin,xmax,ymax = Inf,Inf,-Inf,-Inf
        for point in contour.points
            check(all(x -> isfinite(x) && abs(x) <= COORDINATE_LIMIT, point), "coordinate outside native profile")
            append!(p.points,point)
            x,y = point
            xmin,ymin,xmax,ymax = min(xmin,x),min(ymin,y),max(xmax,x),max(ymax,y)
        end
        append!(p.contours,(start,n,xmin,ymin,xmax,ymax))
    end
    bounds = geometry.bounds === nothing ? (0,0,0,0) : geometry.bounds
    mode = geometry.union_pieces ? 2 : Int(geometry.winding === :evenodd)
    append!(p.shapes, (first,length(p.contours)÷CONTOUR-first,mode,bounds...,0))
    p.retained_shapes === nothing || push!(p.retained_shapes,cached)
    shape
end

"""
    lower_path(path, paint, transform, tolerance, winding, stroke) -> PreparedGeometry

Apply the shared physical lowering and native vertex budget for a fill or
stroke. Invalid paint and geometry raise from `PortableGeometry`.
"""
function lower_path(path,paint,transform,tolerance,winding,stroke)
    return stroke === nothing ?
        G.lower_fill(path,paint;transform,winding,tolerance,max_vertices=MAX_POINTS) :
        G.lower_stroke(path,paint,stroke;transform,tolerance,max_vertices=MAX_POINTS)
end

"""Lower one path and return packed index, physical bounds and paint mapping without retaining geometry."""
function append_path!(p::Packing{Nothing},path,paint,transform,tolerance,winding,stroke=nothing)
    geometry = lower_path(path,paint,transform,tolerance,winding,stroke)
    return append_shape!(p,geometry),geometry.bounds,geometry.canvas_to_paint
end

"""
    append_path!(p, path, paint, transform, tolerance, winding, [stroke]) -> Tuple

Append a fill, clip or stroke and return its index, bounds and paint mapping.
Reuse the previous shape in this slot only on exact lowering inputs.
Retain no more geometry than the validated shape, contour and point budgets.
Path lowering and packing errors propagate without publishing the cache.
"""
function append_path!(p::Packing{ShapeCache},path,paint,transform,tolerance,winding,stroke=nothing)
    mapping = G.paint_mapping(paint,transform)
    slot = length(p.retained_shapes)+1
    previous = slot <= length(p.previous_shapes) ? p.previous_shapes[slot] : nothing
    geometry = if previous !== nothing && previous.path === path &&
                  previous.transform === transform && previous.tolerance === tolerance &&
                  previous.winding === winding && previous.stroke === stroke
        previous.geometry
    else
        lower_path(path,GEOMETRY_PAINT,transform,tolerance,winding,stroke)
    end
    # Oversized sources can still lower within the render budgets, but need
    # not extend the lifetime of their inputs as cache keys.
    keep = length(path.commands) <= MAX_POINTS && (stroke === nothing || length(stroke.dashes) <= MAX_POINTS)
    cached = keep ? CachedShape(path,transform,tolerance,winding,stroke,geometry) : nothing
    index = append_shape!(p,geometry,cached)
    return index,geometry.bounds,mapping
end

"""Append one premultiplied sRGB stop. Reject unsupported colors or excess stops."""
function add_stop!(p, position, color)
    check(color.space === :srgb && length(p.stops) ÷ STOP < MAX_STOPS, "unsupported color space or stop budget")
    r,g,b,a = color.channels
    append!(p.stops,(position,r*a,g*a,b*a,a))
end

"""
    add_paint!(p, paint, mapping, viewport) -> Tuple

Append a solid color or gradient stops. Return their first index, count,
and the three coefficients for mapping a physical pixel to gradient position.
Unsupported paints, degenerate axes and excess stops raise `ArgumentError`.
"""
function add_paint!(p, paint, mapping, viewport)
    begin_at = length(p.stops) ÷ STOP
    if paint isa Solid
        add_stop!(p,0,paint.color)
        return (begin_at,1,0,0,0)
    end
    check(paint isa V.LinearGradient && 1 <= length(paint.stops) <= 8, "unsupported paint")
    for stop in paint.stops
        add_stop!(p,stop.position,stop.color)
    end
    if paint.space === :canvas
        mapping = mapping * G.inverse_transform(viewport)
    end
    a,b,c,d,e,f = mapping.coefficients
    dx,dy = paint.stop .- paint.start
    denom = dx*dx+dy*dy
    check(isfinite(denom) && denom > 0, "bad gradient axis")
    (begin_at,length(paint.stops),(a*dx+b*dy)/denom,(c*dx+d*dy)/denom,
     ((e-paint.start[1])*dx+(f-paint.start[2])*dy)/denom)
end

"""Append one command and its stable node identity after validating the budget."""
function add_command!(p, opcode, node, data=(0,0,0,0,0,0,0,0,0,0,0))
    check(length(p.commands) ÷ COMMAND < MAX_COMMANDS &&
          0 < node.id <= 2^48 && 0 < node.revision <= 2^48, "draw count or identity outside profile")
    append!(p.commands,(opcode,node.id,node.revision,data...))
end

"""
    intersect_bounds(a, b) -> Union{Nothing,Tuple}

Intersect physical bounds conservatively. Empty geometry or a disjoint
clip contributes no source samples.
"""
function intersect_bounds(a,b)
    (a === nothing || b === nothing) && return nothing
    overlap = (max(a[1],b[1]),max(a[2],b[2]),min(a[3],b[3]),min(a[4],b[4]))
    return overlap[1] <= overlap[3] && overlap[2] <= overlap[4] ? overlap : nothing
end

"""
    pack_clip_span!(p, clips, viewport, tolerance) -> ClipSpan

Return a run for a nonempty ordered tuple of captured clips. Omit duplicate
geometry only when the clip stack, transform and tolerance match. Geometry
or packet-limit failures propagate and the caller discards the scratch packet.
"""
function pack_clip_span!(p, clips, viewport, tolerance)
    spans = p.clip_spans
    if spans === nothing
        spans = ClipSpan[]
        p.clip_spans = spans
    end
    for span in spans
        if span.clips === clips && span.viewport === viewport && span.tolerance === tolerance
            return span
        end
    end
    first = length(p.shapes) ÷ SHAPE
    clip = clips[1]
    _,bounds,_ = append_path!(p,clip.path,GEOMETRY_PAINT,viewport*clip.transform,tolerance,clip.winding)
    for i in 2:length(clips)
        clip = clips[i]
        _,mask_bounds,_ = append_path!(p,clip.path,GEOMETRY_PAINT,viewport*clip.transform,tolerance,clip.winding)
        bounds = intersect_bounds(bounds,mask_bounds)
    end
    span = ClipSpan(clips,viewport,tolerance,first,bounds)
    push!(spans,span)
    return span
end

"""
    encode_nodes!(p, nodes, viewport, frame, assets, size, halo, depth=0)

Append drawing records in order at the given physical viewport transform.
Capture clips, lower fills and strokes, reference resident image slots,
and bracket isolated groups.
Unsupported operations and profile limit violations raise before submission.
"""
function encode_nodes!(p, nodes, viewport, frame, assets, size, halo, depth=0)
    for node in nodes
        op = node.operation
        if op isa V.CompositeGroup
            check(depth < 2 && op.effect === nothing, "unsupported group depth or effect")
            add_command!(p,1,node)
            encode_nodes!(p,op.nodes,viewport,frame,assets,size,halo,depth+1)
            add_command!(p,2,node,(0,0,0,op.opacity,Int(op.blend===:multiply),0,0,0,0,0,0))
            continue
        end
        check(op isa Union{V.FillPath,V.StrokePath,V.ClearRegion,V.ImageRegion}, "unsupported Frame operation")
        encode_draw!(p,node,op,viewport,frame,assets,size,halo)
    end
end

"""
    encode_draw!(packing, node, operation, viewport, frame, assets, size, halo)

Encode one previously admitted non-group operation with concrete operation
type dispatch. Mutate the current pack's scratch and return `nothing`.
Geometry, source and packet-limit errors propagate before publication.
"""
function encode_draw!(p,node,op::T,viewport,frame,assets,size,halo) where T
    image = op isa V.ImageRegion
    image && !RasterAssets.drawable(op) && return nothing
    source = image ? V.resource(frame,op.image) : nothing
    paged = source isa V.RasterReference
    state = op.state
    check(state.profile === :portable2d && length(state.clips) <= 4, "unsupported profile or too many clips")
    transform = viewport * state.transform
    a,b,c,d,_,_ = transform.coefficients
    tolerance = 1/(256*max(hypot(a,b)+hypot(c,d),1.0))
    paint = op isa V.FillPath ? state.fill : op isa V.StrokePath ? state.stroke : GEOMETRY_PAINT
    shape,bounds,mapping = if op isa V.FillPath
        append_path!(p,op.path,paint,transform,tolerance,op.winding)
    elseif op isa V.StrokePath
        append_path!(p,op.path,paint,transform,tolerance,:nonzero,state.stroke_style)
    else
        rectangle = image ? op.destination : op.rectangle
        geometry = G.lower_fill(rectangle_path(rectangle...),GEOMETRY_PAINT;
            transform,tolerance,max_vertices=MAX_POINTS)
        append_shape!(p,geometry),geometry.bounds,geometry.canvas_to_paint
    end
    clip_start = length(p.shapes) ÷ SHAPE
    if !isempty(state.clips)
        span = pack_clip_span!(p,state.clips,viewport,tolerance)
        clip_start = span.first
        paged && (bounds = intersect_bounds(bounds,span.bounds))
    end
    clear = op isa V.ClearRegion
    paint_words = if paged
        start = RasterPages.append_record!(p.rasters,p.page_selection,source,op,transform,bounds,size,halo)
        (start,0,0,0,0)
    elseif image
        (RasterAssets.append_record!(p.rasters,frame,assets,op,transform),0,0,0,0)
    elseif clear
        (0,0,0,0,0)
    else
        add_paint!(p,paint,mapping,viewport)
    end
    opcode = paged ? 5 : image ? 4 : clear ? 3 : 0
    add_command!(p,opcode,node,(shape,clip_start,length(state.clips),state.opacity,
        Int(state.blend===:multiply),paint_words...,0))
    return nothing
end

end
