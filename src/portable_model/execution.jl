"""A drawing provider that declares capabilities, allocates surfaces and executes prepared frames."""
abstract type Backend end
"""A render destination owned by the caller of `make_surface` or `render`. Release it with `close`."""
abstract type Surface end
"""Pending work submitted to a backend. Use `wait` to observe completion."""
abstract type Submission end
"""A platform adapter that presents a completed submission to a display surface."""
abstract type Presenter end

struct CapabilityError <: Exception
    node::UInt64
    requirement::Symbol
end
Base.showerror(io::IO, error::CapabilityError) = print(io,"unsupported: node ",error.node," requires ",error.requirement)

struct Capabilities
    version::UInt16
    features::Tuple
    profiles::Tuple
    formats::Tuple
    max_image_size::NTuple{2,Int64}
    rasterizable::Tuple
    fallback_features::Tuple
    fallback_scratch_bytes::Int64
    fallback_transfers::Tuple
    function Capabilities(; features=(), profiles=(:portable2d,), formats=(:rgba8,),
                          max_image_size=(typemax(Int32),typemax(Int32)), rasterizable=(), fallback_features=(),
                          fallback_scratch_bytes::Integer=0, fallback_transfers=())
        dimensions = map(Tuple(max_image_size)) do value
            value isa Integer && 0 < value <= typemax(Int64) ||
                model_error(:invalid_input,"invalid maximum image dimension")
            return Int64(value)
        end
        length(dimensions) == 2 || model_error(:invalid_input,"image limit must have two dimensions")
        fallback_scratch_bytes >= 0 && fallback_scratch_bytes <= typemax(Int64) ||
            model_error(:invalid_input,"invalid fallback scratch reservation")
        lists = map(Tuple,(features,profiles,formats,rasterizable,fallback_features,fallback_transfers))
        all(list -> all(x -> x isa Symbol,list),lists) || model_error(:invalid_input,"invalid capability identifiers")
        return new(1,lists[1],lists[2],lists[3],dimensions,lists[4],lists[5],fallback_scratch_bytes,lists[6])
    end
end
capabilities(::Backend) = model_error(:unsupported,"backend must declare capabilities")

struct RenderPolicy
    mode::Symbol
    raster_size::Union{Nothing,NTuple{2,Int64}}
    byte_budget::Int64
    function RenderPolicy(mode::Symbol=:strict; raster_size=nothing, byte_budget::Integer=0)
        option(mode,(:strict,:portable,:allow_rasterization))
        byte_budget >= 0 && byte_budget <= typemax(Int64) || model_error(:invalid_input,"invalid raster byte budget")
        dimensions = raster_size === nothing ? nothing : checked_dimensions(raster_size...)
        return new(mode,dimensions,byte_budget)
    end
end

struct PlanDiagnostic
    node::UInt64
    requirement::Symbol
    action::Symbol
    resolution::NTuple{2,Int64}
    payload_bytes::Int64
    scratch_bytes::Int64
    transfers::Tuple
end
struct PreparedNode
    node::SemanticNode
    action::Symbol
    children::Tuple
end
struct PreparedFrame{B<:Backend}
    backend::B
    frame::Frame
    nodes::Tuple
    report::Tuple
    retention::Any
end
PreparedFrame(backend::Backend,frame::Frame,nodes::Tuple,report::Tuple) =
    PreparedFrame(backend,frame,nodes,report,nothing)
PreparedFrame{B}(backend::B,frame::Frame,nodes::Tuple,report::Tuple) where {B<:Backend} =
    PreparedFrame{B}(backend,frame,nodes,report,nothing)

"""Adapters acquire only after semantic preflight; a failing hook rolls back its own acquisitions."""
prepare_retention(::Backend, ::Frame) = nothing
retain_execution(::Nothing) = nothing
close_retention(::Nothing) = nothing
close_retention(retention) = close(retention)
Base.close(plan::PreparedFrame) = close_retention(plan.retention)
"""Obtain independent execution/submission pins before closing a resource-bearing plan."""
execution_retention(plan::PreparedFrame) = retain_execution(plan.retention)

operation_kind(::FillPath) = :fill_path
operation_kind(::StrokePath) = :stroke_path
operation_kind(::ImageRegion) = :image
operation_kind(::TextRun) = :text
operation_kind(::ClearRegion) = :clear
operation_kind(::SurfaceRegion) = :surface
operation_kind(::CompositeGroup) = :group
operation_kind(::SemanticOperation) = model_error(:unsupported,"unknown semantic operation")

"""
    requirements(operation)

List the rendering capabilities needed by a frame operation. A backend offering
`:path_precision_1_256px` must preserve transformed fill and stroke coordinates
to within 1/256 physical pixel per axis when narrowing geometry. It must reject
out-of-range geometry before publishing the result. Float64 providers also qualify.
"""
function requirements(operation::SemanticOperation)
    kind = operation_kind(operation)
    if operation isa CompositeGroup
        required = operation.blend === :source_over ? (kind,) : (kind,operation.blend)
        return operation.effect === nothing ? required : (required...,:effect_box_blur_v1)
    end
    state = operation.state
    precision = operation isa Union{FillPath,StrokePath} ? :path_precision_1_256px : :float64
    result = (kind,precision)
    isempty(state.clips) || (result = (result...,:clip))
    if (operation isa Union{FillPath,StrokePath} && operation.path.has_curves) ||
       any(clip -> clip.path.has_curves,state.clips)
        result = (result...,:curve_paths)
    end
    state.blend === :source_over || operation isa ClearRegion || (result = (result...,state.blend))
    paint = operation isa StrokePath ? state.stroke : state.fill
    if operation isa Union{FillPath,StrokePath,TextRun} && paint isa LinearGradient
        result = (result...,:gradient)
    end
    if operation isa Union{FillPath,StrokePath,TextRun}
        colors = paint isa Solid ? (paint.color,) : map(stop -> stop.color,paint.stops)
        any(color -> color.space === :linear_srgb,colors) && (result = (result...,:linear_srgb_color))
    end
    operation isa ImageRegion && state.sampling === :linear && (result = (result...,:linear_sampling))
    if operation isa TextRun
        if isempty(operation.glyphs)
            isempty(operation.fallback_fonts) || (result = (result...,:text_ordered_fallback_v1))
            isempty(operation.features) || (result = (result...,:text_features_v1))
        else
            result = (result...,:text_captured_glyphs_v1)
        end
    end
    return result
end

function prepare_node(node::SemanticNode, frame::Frame, caps::Capabilities, policy::RenderPolicy, report)
    return prepare_operation(node.operation,node,frame,caps,policy,report)
end

function prepare_operation(operation::SemanticOperation, node::SemanticNode, frame::Frame,
                           caps::Capabilities, policy::RenderPolicy, report)
    required = requirements(operation)
    missing = findfirst(required) do feature
        feature in caps.features && return false
        return !(feature === :path_precision_1_256px && :float64 in caps.features)
    end
    if !(operation isa CompositeGroup)
        operation.state.profile in caps.profiles || throw(CapabilityError(node.id,operation.state.profile))
        if operation isa ImageRegion
            image = resource(frame,operation.image)
            image isa RasterPayload || model_error(:invalid_input,"invalid image payload")
            metadata = image_metadata(image)
            requirement = raster_requirement(image)
            requirement in caps.features || throw(CapabilityError(node.id,requirement))
            metadata.format in caps.formats || throw(CapabilityError(node.id,metadata.format))
            metadata.storage === :dense || Symbol("image_storage.",metadata.storage) in caps.features ||
                throw(CapabilityError(node.id,Symbol("image_storage.",metadata.storage)))
            metadata.color_space === :srgb || :linear_srgb_image in caps.features ||
                throw(CapabilityError(node.id,:linear_srgb_image))
            metadata.width <= caps.max_image_size[1] && metadata.height <= caps.max_image_size[2] ||
                throw(CapabilityError(node.id,:image_size))
        elseif operation isa TextRun
            validate_text_fonts(operation.state.font,operation.fallback_fonts,frame.resources,frame.canvas)
            text_glyphs(operation.text,operation.glyphs)
            map(logical,operation.position)
            text_features(operation.features)
            if isempty(operation.glyphs) &&
               any(feature -> feature isa Symbol && !text_feature_tag(feature),operation.features)
                throw(CapabilityError(node.id,:text_features_v1))
            end
        elseif operation isa SurfaceRegion
            surface = resource(frame,operation.surface)
            surface isa SurfaceData || model_error(:invalid_input,"invalid surface payload")
            surface.format in caps.formats || throw(CapabilityError(node.id,surface.format))
        end
    end
    if missing !== nothing
        requirement = required[missing]
        if policy.mode === :allow_rasterization && operation_kind(operation) in caps.rasterizable
            fallback = Capabilities(features=caps.fallback_features,profiles=caps.profiles,formats=caps.formats,
                                    max_image_size=caps.max_image_size)
            prepare_node(node,frame,fallback,RenderPolicy(),PlanDiagnostic[])
            policy.raster_size === nothing && model_error(:invalid_input,"raster fallback needs an explicit resolution")
            width,height = policy.raster_size
            bytes = 4*width*height
            used = sum(d -> Int128(d.payload_bytes)+d.scratch_bytes,report;init=Int128(0))
            used+bytes+caps.fallback_scratch_bytes <= policy.byte_budget ||
                model_error(:resource_limit,"raster fallback exceeds payload and scratch budget")
            push!(report,PlanDiagnostic(node.id,requirement,:rasterize,policy.raster_size,
                                       bytes,caps.fallback_scratch_bytes,caps.fallback_transfers))
            return PreparedNode(node,:rasterize,())
        end
        throw(CapabilityError(node.id,requirement))
    end
    children = operation isa CompositeGroup ?
        Tuple(prepare_node(child,frame,caps,policy,report) for child in operation.nodes) : ()
    return PreparedNode(node,:native,children)
end

"""Preflight every node before execution. No fallback executes during planning."""
function prepare(backend::Backend, frame::Frame; policy::RenderPolicy=RenderPolicy())
    frame.schema_version == 1 || model_error(:unsupported,"unsupported frame schema")
    caps = capabilities(backend)
    report = PlanDiagnostic[]
    nodes = Tuple(prepare_node(node,frame,caps,policy,report) for node in frame.nodes)
    diagnostics = Tuple(report)
    retention = prepare_retention(backend,frame)
    try
        return PreparedFrame(backend,frame,nodes,diagnostics,retention)
    catch
        close_retention(retention)
        rethrow()
    end
end

"""Allocate a render target of the requested physical pixel size on a backend."""
make_surface(::Backend, size) = model_error(:unsupported,"backend must create or receive a surface")
"""Execute a prepared frame synchronously and return its destination surface."""
execute!(::Backend, ::Surface, ::PreparedFrame) = model_error(:unsupported,"backend must implement execution")

"""
    readback(surface) -> Image

Copy the completed surface into an independently owned, top-left, premultiplied RGBA8 image.
Providers implement this operation for readable surfaces. GPU surfaces may need a device transfer.
"""
readback(::Surface) = model_error(:unsupported,"surface does not support pixel readback")

"""Release resources belonging to a surface. Providers holding native handles implement this method."""
Base.close(::Surface) = nothing

"""Take the image from a private one-shot surface. Providers with transferable storage can avoid a copy."""
_take_raster_image(surface::Surface) = readback(surface)

"""
    render(frame; backend, size=frame.size, policy=RenderPolicy()) -> Surface

Render synchronously into a new surface at the requested physical pixel size.
The caller owns the result and can present it, call `readback` to copy pixels, or close it.
"""
function render(frame::Frame; backend::Backend, size=frame.size, policy::RenderPolicy=RenderPolicy())
    plan = prepare(backend,frame;policy)
    surface = nothing
    try
        try
            surface = make_surface(backend,checked_dimensions(size...))
            return execute!(backend,surface,plan)
        finally
            close(plan)
        end
    catch
        isnothing(surface) || close(surface)
        rethrow()
    end
end

function submit!(backend::Backend, surface::Surface, frame::Frame; policy::RenderPolicy=RenderPolicy())
    plan = prepare(backend,frame;policy)
    try
        return submit!(backend,surface,plan)
    finally
        close(plan)
    end
end
submit!(::Backend, ::Surface, ::PreparedFrame) = model_error(:unsupported,"backend must implement submission and retention")
Base.wait(::Submission) = model_error(:unsupported,"adapter must implement completion")
cancel!(::Submission) = model_error(:unsupported,"adapter must implement cancellation")
completed(::Submission) = model_error(:unsupported,"adapter must report completion")
present!(::Presenter, ::Submission) = model_error(:unsupported,"presenter must validate completion before acceptance")

"""Backend-independent debug data, not the VTR-015 persistence/wire schema."""
function portable_descriptor(value)
    if portable_scalar(value)
        return value
    elseif portable_float(value)
        isfinite(value) || model_error(:invalid_input,"non-finite portable value")
        return value
    elseif value isa SceneNodes
        return Tuple(portable_descriptor(node) for node in value)
    elseif value isa Union{Tuple,NamedTuple}
        return map(portable_descriptor,value)
    elseif value isa Union{Frame,SemanticNode,ResourceRecord,ResourceRef,ResourcePayload,
                           Transform2D,Color,PaintDescriptor,GradientStop,StrokeStyle,BoxBlur,
                          CapturedClip,DrawingState,SemanticOperation}
        value isa SemanticOperation && operation_kind(value)
        ismutabletype(typeof(value)) && model_error(:invalid_input,"mutable portable descriptor")
        fields = map(i -> portable_descriptor(getfield(value,i)),1:fieldcount(typeof(value)))
        return (type=Symbol(nameof(typeof(value))),fields=Tuple(fields))
    end
    model_error(:invalid_input,"native handle, closure or unsupported portable value")
end
