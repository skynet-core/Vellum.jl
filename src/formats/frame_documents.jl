"""Maximum exact integer size accepted by the document writers' Float32 page model."""
const DOCUMENT_MAX_SIDE = 1 << 24

"""Per-run outline command limit for captured text in a vector document."""
const DOCUMENT_TEXT_COMMANDS = 65_536

"""Owned crops shared across an export, keyed by the immutable image payload and integer pixel bounds."""
const DocumentCrops = IdDict{ImageData,Dict{NTuple{4,Int},Image}}

"""Maximum total prepared vertices for one isolated document raster patch."""
const DOCUMENT_RASTER_VERTICES = 65_536

"""Maximum group nesting depth admitted by the document raster renderer."""
const DOCUMENT_RASTER_DEPTH = 8

"""An isolated group awaiting document rasterization after semantic lowering."""
struct DocumentRasterGroup <: PicOp
    node::SemanticNode
end

"""
    _document_path(path::PathData) -> Path

Copy retained path commands into the writers' Float32 path representation
without flattening Bézier curves. The writers reject coordinates that
overflow Float32 before opening the destination.
"""
function _document_path(path::PathData)
    result = newPath()
    for (kind, coordinates...) in path.commands
        if kind === :move
            moveTo(result, coordinates...)
        elseif kind === :line
            lineTo(result, coordinates...)
        elseif kind === :quad
            quadraticCurveTo(result, coordinates...)
        elseif kind === :cubic
            bezierCurveTo(result, coordinates...)
        else
            closePath(result)
        end
    end
    return result
end

"""
    _document_matrix(transform, node) -> Mat3

Preserve the retained affine coefficients in the document writers' layout.
Raise `CapabilityError` when the Float32 transform is nonfinite or singular.
"""
function _document_matrix(transform::Transform2D, node::UInt64)
    a, b, c, d, x, y = Float32.(transform.coefficients)
    all(isfinite, (a, b, c, d, x, y)) && Float64(a) * d != Float64(b) * c ||
        throw(CapabilityError(node, :document_affine_transform))
    return Mat3((a, b, 0f0, c, d, 0f0, x, y, 1f0))
end

"""
    _document_color(color, node) -> ColorRGBA

Convert straight sRGB channels to the writers' 8-bit color type. Raise
`CapabilityError` for any other color space.
"""
function _document_color(color::Color, node::UInt64)
    color.space === :srgb || throw(CapabilityError(node, :document_srgb))
    return rgba(map(channel -> round(Int, channel * 255), color.channels)...)
end

"""
    _document_paint(paint::Solid, state, node, matrix) -> Paint

Build a solid paint using the drawing state's opacity. Solid color is
independent of `matrix`. Raise `CapabilityError` for non-sRGB colors.
"""
function _document_paint(paint::Solid, state::DrawingState, node::UInt64, ::Mat3)
    return Paint(_document_color(paint.color, node); opacity=state.opacity)
end

"""
    _document_paint(paint::LinearGradient, state, node, matrix) -> Paint

Re-express the gradient's scalar projection as two canvas-space handles.
This preserves its sampled parameter under local or canvas-space affine
maps, including skew. The common vector profile preserves sRGB and alpha
stops with strictly increasing Float32 offsets and finite, distinct handles.
Unsupported values raise `CapabilityError` on the owning node.
"""
function _document_paint(paint::LinearGradient, state::DrawingState, node::UInt64, matrix::Mat3)
    result = newPaint(LinearGradientPaint)
    previous = -Inf32
    for stop in paint.stops
        position = Float32(stop.position)
        position > previous || throw(CapabilityError(node, :document_ordered_stops))
        push!(result.gradientStops, ColorStop(_document_color(stop.color, node), position))
        previous = position
    end
    paint_to_canvas = paint.space === :local ? state.transform * paint.transform : paint.transform
    canvas_to_paint = PortableGeometry.paint_mapping(paint, state.transform)
    a, b, c, d, _, _ = canvas_to_paint.coefficients
    dx, dy = paint.stop .- paint.start
    axis_length = hypot(dx, dy)
    ux, uy = dx / axis_length, dy / axis_length
    sx, sy = a * ux + b * uy, c * ux + d * uy
    slope_length = hypot(sx, sy)
    span = axis_length / slope_length
    x, y = map_point(paint_to_canvas, paint.start)
    first_handle = Vec2(Float32(x), Float32(y))
    last_handle = Vec2(Float32(x + span * (sx / slope_length)), Float32(y + span * (sy / slope_length)))
    all(isfinite, (first_handle.x, first_handle.y, last_handle.x, last_handle.y)) &&
        0 < lengthSq(last_handle - first_handle) < Inf32 || throw(CapabilityError(node, :document_gradient_axis))
    pdf_first, pdf_last = _pdfLinearHandles(first_handle, last_handle, matrix)
    all(isfinite, inverse(matrix).data) &&
        all(isfinite, (pdf_first.x, pdf_first.y, pdf_last.x, pdf_last.y)) && pdf_first != pdf_last ||
        throw(CapabilityError(node, :document_gradient_transform))
    append!(result.gradientHandlePositions, (first_handle, last_handle))
    result.opacity = Float32(state.opacity)
    return result
end

"""
    _document_leaf(operation, frame, node, matrix) -> PicOp

Lower a path, a solid undashed stroke, or a captured text run to one vector
operation. Glyphs become outlines at their recorded positions. Unsupported
paint, fill-rule and stroke combinations raise `CapabilityError`; malformed
captured text errors propagate from the shared outline decoder.
"""
function _document_leaf(operation, frame::Frame, node::UInt64, matrix::Mat3)
    state = operation.state
    if operation isa StrokePath
        style = state.stroke_style
        width, miter = Float32(style.width), Float32(style.miter_limit)
        state.stroke isa Solid && isempty(style.dashes) && 0 < width < Inf32 && 1 <= miter < Inf32 ||
            throw(CapabilityError(node, :document_solid_undashed_stroke))
        cap = (butt=ButtCap, round=RoundCap, square=SquareCap)[style.cap]
        join = (miter=MiterJoin, round=RoundJoin, bevel=BevelJoin)[style.join]
        return StrokeOp(_document_path(operation.path), _document_paint(state.stroke, state, node, matrix),
            matrix, width, cap, join, miter, Float32[])
    end
    if operation isa TextRun
        isempty(operation.glyphs) && throw(CapabilityError(node, :document_captured_text))
        path = _portable_text_path(operation, frame, node; max_commands=DOCUMENT_TEXT_COMMANDS)
        return FillOp(_document_path(path), _document_paint(state.fill, state, node, matrix), matrix, NonZero)
    end
    winding = operation.winding === :evenodd ? EvenOdd : NonZero
    winding == EvenOdd && state.fill isa LinearGradient &&
        throw(CapabilityError(node, :document_nonzero_gradient_fill))
    return FillOp(_document_path(operation.path), _document_paint(state.fill, state, node, matrix), matrix, winding)
end

"""
    _document_image(operation, frame, node, matrix, crops)

Resolve a dense RGBA8 image revision and retain only the source crop's
contributing texels. Return its image operation and a destination clip
for a fractional crop, or `nothing` for an empty placement. Source and
destination coordinates use top-left coordinates. Reject tiled sources,
invalid regions, and nonrepresentable image transforms during preflight.
"""
function _document_image(operation::ImageRegion, frame::Frame, node::UInt64, matrix::Mat3, crops::DocumentCrops)
    source = resource(frame, operation.image)
    source isa ImageData || throw(CapabilityError(node, :document_dense_image))
    sx, sy, sw, sh = operation.source
    x, y, width, height = operation.destination
    all(isfinite, operation.source) && all(isfinite, operation.destination) &&
        min(sx, sy, sw, sh, width, height) >= 0 &&
        sx + sw <= source.width && sy + sh <= source.height ||
        throw(ArgumentError("invalid document region at image node $node"))
    min(sw, sh, width, height) == 0 && return nothing

    left, top = floor(Int, sx), floor(Int, sy)
    right, bottom = ceil(Int, sx + sw), ceil(Int, sy + sh)
    scale_x, scale_y = width / sw, height / sh
    mapping = Transform2D(scale_x, 0, 0, scale_y,
        x + (left - sx) * scale_x, y + (top - sy) * scale_y)
    image_matrix = _document_matrix(operation.state.transform * mapping, node)
    regions = get!(() -> Dict{NTuple{4,Int},Image}(),crops,source)
    crop = get!(regions, (left, top, right, bottom)) do
        image = newImage(right - left, bottom - top)
        pixels = codeunits(source.pixels.bytes)
        row_bytes = 4 * image.width
        for row in 0:(image.height - 1)
            start = (top + row) * source.row_stride + 4 * left + 1
            copyto!(image.data, row * row_bytes + 1, pixels, start, row_bytes)
        end
        return image
    end
    clip = if all(isinteger, (sx, sy, sx + sw, sy + sh))
        nothing
    else
        PicClip(_document_path(rectangle_path(x, y, width, height)), NonZero, matrix)
    end
    return DocumentImageOp(crop, image_matrix, operation.state.sampling), clip
end

"""
    _document_operations!(output, nodes, frame, crops, rasterize)

Append private writer operations in semantic order. Apply captured clips in
canvas coordinates and retain effect-free, source-over isolation groups. When
`rasterize` is true, stage source-over blur groups for bounded CPU rendering.
Fail on unsupported operations or profiles before any file is opened.
"""
function _document_operations!(output::Vector{PicOp}, nodes, frame::Frame, crops::DocumentCrops, rasterize::Bool)
    for node in nodes
        operation = node.operation
        if operation isa CompositeGroup
            operation.blend === :source_over ||
                throw(CapabilityError(node.id, :document_source_over_group))
            if operation.effect !== nothing
                rasterize || throw(CapabilityError(node.id, :document_source_over_group))
                push!(output, DocumentRasterGroup(node))
                continue
            end
            push!(output, GroupStart(Float32(operation.opacity)))
            _document_operations!(output, operation.nodes, frame, crops, rasterize)
            push!(output, GroupEnd(PicClip[]))
            continue
        end
        operation isa Union{FillPath,StrokePath,TextRun,ImageRegion} ||
            throw(CapabilityError(node.id, :document_vector_operation))
        state = operation.state
        state.profile === :portable2d && state.blend === :source_over ||
            throw(CapabilityError(node.id, :document_source_over_srgb))
        matrix = _document_matrix(state.transform, node.id)
        if operation isa ImageRegion
            placement = _document_image(operation, frame, node.id, matrix, crops)
            isnothing(placement) && continue
            leaf, destination_clip = placement
            opacity = Float32(state.opacity)
        else
            leaf = _document_leaf(operation, frame, node.id, matrix)
            destination_clip = nothing
            opacity = 1f0
        end
        if isempty(state.clips) && isnothing(destination_clip) && opacity == 1f0
            push!(output, leaf)
        else
            clips = PicClip[]
            for clip in state.clips
                push!(clips, PicClip(_document_path(clip.path), clip.winding === :evenodd ? EvenOdd : NonZero,
                    _document_matrix(clip.transform, node.id)))
            end
            isnothing(destination_clip) || push!(clips, destination_clip)
            append!(output, (GroupStart(opacity), leaf, GroupEnd(clips)))
        end
    end
    return nothing
end

"""
    _document_raster_bounds(node)

Find conservative bounds in the original physical viewport, intersecting
prepared geometry with every captured clip and expanding groups by their
blur radii. Return `nothing` for empty or disjoint coverage. Erasure can
only remove existing coverage.
"""
function _document_raster_bounds(node)
    if node isa CPUBackend.Group
        bounds = nothing
        for child in node.children
            bounds = union_bounds(bounds, _document_raster_bounds(child))
        end
        return expand_bounds(bounds, node.radius...)
    end
    node.clear && return nothing
    bounds = node.geometry.bounds
    for clip in node.clips
        mask = clip.bounds
        intersects_bounds(bounds, mask) || return nothing
        bounds = (max(bounds[1], mask[1]), max(bounds[2], mask[2]),
                  min(bounds[3], mask[3]), min(bounds[4], mask[4]))
    end
    return bounds
end

"""
    _document_patch_region(nodes, extent)

Return the integer pixel crop enclosing an isolated prepared group on the
page, or `nothing` when it has no coverage within `extent`. Group bounds
already include the exact quantized halo, including nested blurs.
"""
function _document_patch_region(nodes, extent)
    bounds = _document_raster_bounds(only(nodes))
    bounds === nothing && return nothing
    width, height = extent
    x = floor(Int, clamp(bounds[1], 0, width))
    y = floor(Int, clamp(bounds[2], 0, height))
    right = ceil(Int, clamp(bounds[3], 0, width))
    bottom = ceil(Int, clamp(bounds[4], 0, height))
    right > x && bottom > y || return nothing
    return x, y, right - x, bottom - y
end

"""
    _document_check_raster_node(node, depth)

Require captured glyph positions for text inside a fallback group, including
nested groups. Fail on excessive nesting before preparing geometry. Raise a
node-specific `CapabilityError` for deferred text or an excessive depth.
"""
function _document_check_raster_node(node::SemanticNode, depth::Int)
    operation = node.operation
    if operation isa CompositeGroup
        depth < DOCUMENT_RASTER_DEPTH || throw(CapabilityError(node.id, :document_raster_depth))
        for child in operation.nodes
            _document_check_raster_node(child, depth + 1)
        end
    elseif operation isa TextRun && isempty(operation.glyphs)
        throw(CapabilityError(node.id, :document_captured_text))
    end
    return nothing
end

"""
    _document_raster_patch(frame, node, extent, available)

Render one isolated group at the requested full-page reference `extent`.
Use the same viewport and sample grid as CPU rendering, allocating only the
crop. Return its writer operation and diagnostic, or `nothing` for an empty
crop. Unsupported descendants and preparation errors propagate. A budget
failure occurs before allocating crop pixels or opening a destination.
"""
function _document_raster_patch(frame::Frame, node::SemanticNode, extent, available)
    _document_check_raster_node(node, 0)
    subframe = Frame(frame.schema_version, frame.canvas, frame.revision, frame.size, (node,), frame.resources)
    # Preflight the isolated subtree. Unrelated resources need no provider lease.
    prepared = prepare_node(node, subframe, CPUBackend.cpu_capabilities(false), RenderPolicy(), PlanDiagnostic[])
    page = (0.0, 0.0, frame.size...)
    intersects_bounds(raster_bounds(node, extent ./ frame.size), page) || return nothing
    tile, samples, depth = 32, 4, DOCUMENT_RASTER_DEPTH
    minimum = CPUBackend.scratch_payload(tile, tile, samples, depth, false)
    minimum <= available || model_error(:resource_limit, "document raster scratch exceeds byte_budget at node $(node.id)")
    renderer = CPUBackend.Renderer(tile_size=tile, samples=samples, max_depth=depth,
        max_vertices=DOCUMENT_RASTER_VERTICES, scratch_bytes=available)
    try
        plan = PreparedFrame(renderer, subframe, (prepared,), ())
        nodes = CPUBackend.cpu_plan(renderer, plan, extent)
        region = _document_patch_region(nodes, extent)
        region === nothing && return nothing
        x, y, width, height = region
        payload = Int64(4) * width * height
        scratch = CPUBackend.scratch_usage(renderer).peak_reserved_bytes
        payload <= available - scratch ||
            model_error(:resource_limit, "document raster payload and scratch exceed byte_budget at node $(node.id)")
        sx, sy = frame.size ./ extent
        matrix = _document_matrix(Transform2D(sx, 0, 0, sy, x * sx, y * sy), node.id)
        image = newImage(width, height)
        CPUBackend.draw_region!(renderer, nodes, x, y, width, height, image.data, width, x, y, nothing, false)
        report = PlanDiagnostic(node.id, :effect_box_blur_v1, :rasterize,
            (width, height), payload, scratch, ())
        return DocumentImageOp(image, matrix, :nearest), report
    finally
        close(renderer)
    end
end

"""
    _document_rasterize!(operations, frame, policy) -> Tuple

Replace staged groups with cropped image operations in the original stacking
order. Return one diagnostic per rasterized group and reserve their combined
payload and scratch bytes. Policy, preparation and rendering errors propagate
before publication.
"""
function _document_rasterize!(operations, frame, policy)
    extent = policy.raster_size
    extent !== nothing && all(side -> side <= DOCUMENT_MAX_SIDE, extent) && policy.byte_budget > 0 ||
        throw(ArgumentError("document raster fallback requires a valid raster_size and positive byte_budget"))
    available = min(policy.byte_budget, typemax(Int))
    size = map(Int, extent)
    report = PlanDiagnostic[]
    for i in eachindex(operations)
        operation = operations[i]
        operation isa DocumentRasterGroup || continue
        patch = _document_raster_patch(frame, operation.node, size, available)
        patch === nothing && continue
        image, diagnostic = patch
        operations[i] = image
        push!(report, diagnostic)
        available -= diagnostic.payload_bytes + diagnostic.scratch_bytes
    end
    filter!(operation -> !(operation isa DocumentRasterGroup), operations)
    return Tuple(report)
end

"""
    _document_picture(frame, policy) -> Tuple{Picture,Tuple}

Build an owned document and its fallback report from a version-one snapshot. Whole
logical dimensions must fit exactly in Float32. Invalid dimensions or an
unsupported schema raise `ArgumentError`; node diagnostics propagate.
"""
function _document_picture(frame::Frame, policy::RenderPolicy, crops=DocumentCrops())
    frame.schema_version == 1 || throw(ArgumentError("unsupported document frame schema"))
    all(side -> isinteger(side) && 0 < side <= DOCUMENT_MAX_SIDE, frame.size) ||
        throw(ArgumentError("document dimensions must be positive whole logical units"))
    operations = PicOp[]
    rasterize = policy.mode === :allow_rasterization
    _document_operations!(operations, frame.nodes, frame, crops, rasterize)
    report = rasterize ? _document_rasterize!(operations, frame, policy) : ()
    return Picture(operations, Vec2(Float32.(frame.size)...)), report
end

"""
    writeSvg(file::AbstractString, frame::Frame) -> String

Write one retained frame as a standalone vector SVG and return its text.
The viewport uses the frame's positive, whole logical dimensions. Paint,
curves, solid undashed strokes, captured text outlines, and supported clips
and source-over groups remain vector content. Unsupported nodes raise
`CapabilityError` before opening `file`. Invalid dimensions, malformed data,
writer preflight errors and filesystem errors propagate. Each dense source
crop is embedded once with its alpha. Image sampling uses the viewer's
resampling implementation.
"""
function writeSvg(file::AbstractString, frame::Frame)
    picture, _ = _document_picture(frame, RenderPolicy())
    return writeSvg(String(file), picture)
end

"""
    writeSvg(file::AbstractString, frame::Frame, policy::RenderPolicy) -> NamedTuple

Export the frame and return `(document, report)`. With
`RenderPolicy(:allow_rasterization; raster_size, byte_budget)`, crop each
unsupported isolated source-over blur group to its affected pixels at the
explicit full-page reference size. Keep supported artwork as vectors.
The report records each rasterized node, actual crop resolution, RGBA
payload and peak CPU scratch. Their summed reservations must fit
`byte_budget`. Other modes are strict. Unsupported nodes, invalid policy
or dimensions and filesystem errors propagate. Semantic, budget and
preflight failures leave the destination untouched.
"""
function writeSvg(file::AbstractString, frame::Frame, policy::RenderPolicy)
    picture, report = _document_picture(frame, policy)
    return (document=writeSvg(String(file), picture), report=report)
end

"""
    writePdf(file::AbstractString, frame::Frame; dpi=96) -> String

Write a single-page vector PDF of the same strict profile as [`writeSvg`](@ref).
The page measures `frame.size * 72 / dpi` points. Return the binary PDF as
a `String`. A nonpositive or nonfinite `dpi` raises `ArgumentError`.
Unsupported node, invalid frame and filesystem errors propagate. Preflight
errors leave the destination untouched. Repeated placements of a source
crop with the same sampling mode share one image and any required soft mask.
"""
function writePdf(file::AbstractString, frame::Frame; dpi::Real=96)
    return writePdf(file, frame, RenderPolicy(); dpi).document
end

"""
    writePdf(file::AbstractString, frame::Frame, policy::RenderPolicy; dpi=96) -> NamedTuple

Export one PDF page and return `(document, report)` with the same fallback
contract as the three-argument `writeSvg`. The page measures
`frame.size * 72 / dpi` points. Its physical size and the policy's reference
raster dimensions are independent. A nonpositive or nonfinite `dpi` raises
`ArgumentError`. Preflight failures leave the destination untouched.
"""
function writePdf(file::AbstractString, frame::Frame, policy::RenderPolicy; dpi::Real=96)
    resolution = Float32(dpi)
    isfinite(resolution) && resolution > 0 || throw(ArgumentError("document DPI must be finite and positive"))
    picture, report = _document_picture(frame, policy)
    return (document=writePdf(String(file), picture; dpi=resolution), report=report)
end
