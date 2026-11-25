abstract type ResourcePayload end
abstract type RasterPayload <: ResourcePayload end
abstract type SemanticOperation end

"""
    ModelError(category, message)

Describe a failed retained drawing operation. The `category` symbol
identifies the kind of failure and the `message` explains its cause.
"""
struct ModelError <: Exception
    category::Symbol
    message::String
end
Base.showerror(io::IO, error::ModelError) = print(io, error.category, ": ", error.message)
model_error(category, message) = throw(ModelError(category, message))

function logical(value::Real)
    isfinite(value) || model_error(:invalid_input, "non-finite number")
    result = Float64(value)
    isfinite(result) || model_error(:invalid_input, "number exceeds Float64")
    return result
end

function nonnegative(value::Real)
    result = logical(value)
    result >= 0 || model_error(:invalid_input, "negative size")
    return result
end

function unit_interval(value::Real)
    result = logical(value)
    0 <= result <= 1 || model_error(:invalid_input, "value outside [0,1]")
    return result
end

function option(value::Symbol, choices::Tuple)
    value in choices || model_error(:invalid_input, "invalid option: $value")
    return value
end

"""
    Transform2D(a=1, b=0, c=0, d=1, e=0, f=0)

Create the affine map `(a*x+c*y+e, b*x+d*y+f)`. The `coefficients` tuple
stores `(a, b, c, d, e, f)` as finite Float64 values. Composition applies
the right operand first. Nonfinite or unrepresentable inputs raise
[`ModelError`](@ref).
"""
struct Transform2D
    coefficients::NTuple{6,Float64}
    function Transform2D(a::Real=1, b::Real=0, c::Real=0, d::Real=1, e::Real=0, f::Real=0)
        return new(map(logical, (a,b,c,d,e,f)))
    end
end

function Base.:*(left::Transform2D, right::Transform2D)
    a,b,c,d,e,f = left.coefficients
    g,h,i,j,k,l = right.coefficients
    return Transform2D(a*g+c*h, b*g+d*h, a*i+c*j, b*i+d*j, a*k+c*l+e, b*k+d*l+f)
end

function map_point(transform::Transform2D, point::Tuple{Real,Real})
    a,b,c,d,e,f = transform.coefficients
    x,y = map(logical, point)
    return (a*x+c*y+e, b*x+d*y+f)
end

"""
    Color(r, g, b, a=1; space=:srgb)

Construct a portable straight-alpha color. The `channels` store red,
green, blue, and alpha in that order. The `space` is either sRGB or
linear sRGB, selected with `:srgb` or `:linear_srgb`. Unsupported spaces
and channels outside the finite interval `[0, 1]` raise `ModelError`.
"""
struct Color
    channels::NTuple{4,Float64}
    space::Symbol
    function Color(r::Real, g::Real, b::Real, a::Real=1; space::Symbol=:srgb)
        return new(map(unit_interval, (r,g,b,a)), option(space, (:srgb,:linear_srgb)))
    end
end

abstract type PaintDescriptor end
"""
    Solid(color::Color)
    Solid(r, g, b, a=1)

Create a uniform fill or stroke whose `color` is a portable straight-alpha
color. The numeric form uses sRGB and validates the channels through
[`Color`](@ref).
"""
struct Solid <: PaintDescriptor
    color::Color
end
"""Create a uniform sRGB paint from normalized red, green, blue, and alpha."""
Solid(r::Real, g::Real, b::Real, a::Real=1) = Solid(Color(r,g,b,a))

"""
    GradientStop(position, color)

Set the `color` at a normalized `position` along a gradient axis.
A nonfinite position or one outside `[0, 1]` raises `ModelError`.
"""
struct GradientStop
    position::Float64
    color::Color
    GradientStop(position::Real, color::Color) = new(unit_interval(position), color)
end

"""
    LinearGradient(start, stop, stops; space=:local, transform=Transform2D())

Build an interpolated paint between the finite points `start` and `stop`.
The immutable `stops` tuple contains one or more `GradientStop` values
in ascending position order. The `space` selects local or canvas
coordinates and the invertible `transform` maps the gradient within
that coordinate space. Degenerate geometry or invalid stops raise
`ModelError`.
"""
struct LinearGradient <: PaintDescriptor
    start::NTuple{2,Float64}
    stop::NTuple{2,Float64}
    stops::Tuple
    space::Symbol
    transform::Transform2D
    function LinearGradient(start::Tuple{Real,Real}, stop::Tuple{Real,Real}, stops;
                            space::Symbol=:local, transform::Transform2D=Transform2D())
        a,b = map(logical,start), map(logical,stop)
        a != b || model_error(:invalid_input, "zero gradient axis")
        values = Tuple(stops)
        !isempty(values) && all(x -> x isa GradientStop, values) ||
            model_error(:invalid_input, "invalid gradient stops")
        issorted(map(x -> x.position, values)) || model_error(:invalid_input, "unordered gradient stops")
        m,n,p,q,_,_ = transform.coefficients
        m*q-n*p != 0 || model_error(:invalid_input, "singular paint transform")
        return new(a,b,values,option(space,(:local,:canvas)),transform)
    end
end

"""
    PathData(commands)

Capture a sequence of vector commands. The `commands` tuple holds the
validated `:move`, `:line`, `:quad`, `:cubic`, and `:close` records.
The `has_curves` flag identifies paths with quadratic or cubic segments.
Nonempty paths begin with a move. Invalid commands, arity, or nonfinite
coordinates raise `ModelError`.
"""
struct PathData <: ResourcePayload
    commands::Tuple
    has_curves::Bool
    function PathData(commands)
        # Validate vector inputs before freezing them into a heterogeneous tuple.
        source = commands isa Vector ? commands : Tuple(commands)
        result = map(source) do command
            command isa Tuple && !isempty(command) || model_error(:invalid_input, "invalid path command")
            kind = command[1]
            count = kind === :move || kind === :line ? 2 :
                    kind === :quad ? 4 : kind === :cubic ? 6 : kind === :close ? 0 : -1
            count >= 0 && length(command) == count+1 ||
                model_error(:invalid_input, "invalid path command or arity")
            return (kind, map(logical,Base.tail(command))...)
        end
        isempty(result) || result[1][1] === :move || model_error(:invalid_input, "path must start with move")
        return new(Tuple(result),any(command -> command[1] in (:quad,:cubic),result))
    end
end

"""
    rectangle_path(x, y, width, height) -> PathData

Return a closed, axis-aligned path from logical origin `(x, y)` and
nonnegative dimensions. Negative dimensions or nonfinite coordinates,
including computed endpoints, raise `ModelError`.
"""
function rectangle_path(x::Real, y::Real, width::Real, height::Real)
    x,y,w,h = logical(x),logical(y),nonnegative(width),nonnegative(height)
    return PathData(((:move,x,y),(:line,x+w,y),(:line,x+w,y+h),(:line,x,y+h),(:close,)))
end

"""
    StrokeStyle(; width=1, cap=:butt, join=:miter, miter_limit=10,
                  dashes=(), dash_offset=0)

Store stroke geometry in logical units. The `width` is the line's
thickness, `cap` selects the end shape, and `join` selects how adjacent
segments meet. The `miter_limit` bounds the miter extension.
The `dashes` tuple alternates drawn and blank lengths and
`dash_offset` shifts its origin. Invalid options, nonfinite numbers,
negative lengths, and a nonempty all-zero pattern raise `ModelError`.
"""
struct StrokeStyle
    width::Float64
    cap::Symbol
    join::Symbol
    miter_limit::Float64
    dashes::Tuple
    dash_offset::Float64
    function StrokeStyle(; width::Real=1, cap::Symbol=:butt, join::Symbol=:miter,
                         miter_limit::Real=10, dashes=(), dash_offset::Real=0)
        pattern = map(nonnegative, Tuple(dashes))
        isempty(pattern) || any(>(0),pattern) || model_error(:invalid_input, "all-zero dash pattern")
        return new(nonnegative(width),option(cap,(:butt,:round,:square)),
                   option(join,(:miter,:round,:bevel)),nonnegative(miter_limit),pattern,logical(dash_offset))
    end
end

"""
    ResourceRef

An immutable identifier returned by `resource!` or `revise_resource!`.
The `canvas` and `id` identify the resource, `revision` selects its
version, and `kind` carries its resource category. Resolve a reference
against the originating edit or frame. An absent or foreign reference
raises `ModelError`.
"""
struct ResourceRef
    canvas::UInt64
    id::UInt64
    revision::UInt64
    kind::Symbol
end

"""Finite box-filter radii in canvas units; physical supports are axiswise ceilings."""
struct BoxBlur
    radius_x::Float64
    radius_y::Float64
    BoxBlur(radius_x::Real, radius_y::Real=radius_x) =
        new(nonnegative(radius_x),nonnegative(radius_y))
end

"""Owned immutable binary data. Publication copies once; snapshots share it."""
struct FrozenBytes <: ResourcePayload
    bytes::String
    # Copy directly into String storage, without a temporary full-size byte vector.
    FrozenBytes(bytes::AbstractVector{UInt8}) = new(String(view(bytes,:)))
end
Base.length(bytes::FrozenBytes) = ncodeunits(bytes.bytes)
Base.getindex(bytes::FrozenBytes, index::Int) = codeunit(bytes.bytes,index)
Base.show(io::IO, bytes::FrozenBytes) = print(io,"FrozenBytes(",length(bytes)," bytes)")

"""Published legacy RGBA8 Image revision; not an editable buffer or device handle."""
struct ImageData <: RasterPayload
    width::Int64
    height::Int64
    format::Symbol
    alpha::Symbol
    color_space::Symbol
    orientation::Symbol
    row_stride::Int64
    pixels::FrozenBytes
    function ImageData(image::Image)
        pixels = FrozenBytes(image.data)
        for i in 1:4:length(pixels)
            max(pixels[i],pixels[i+1],pixels[i+2]) <= pixels[i+3] ||
                model_error(:invalid_input, "invalid premultiplied image pixel")
        end
        return new(image.width,image.height,:rgba8,:premultiplied,:srgb,:top_left,
                   Base.checked_mul(Int64(4),Int64(image.width)),pixels)
    end
end

"""Portable raster description; layout/provider details stay with the immutable payload."""
struct ImageMetadata <: ResourcePayload
    width::Int64
    height::Int64
    format::Symbol
    alpha::Symbol
    color_space::Symbol
    orientation::Symbol
    storage::Symbol
    function ImageMetadata(width::Integer, height::Integer; format::Symbol=:rgba8,
                           alpha::Symbol=:premultiplied, color_space::Symbol=:srgb,
                           orientation::Symbol=:top_left, storage::Symbol=:dense)
        width > 0 && height > 0 || model_error(:invalid_input,"logical image dimensions must be positive")
        width <= typemax(Int64) && height <= typemax(Int64) || model_error(:size_overflow,"logical image dimensions exceed Int64")
        return new(Int64(width),Int64(height),format,option(alpha,(:none,:straight,:premultiplied)),
                   option(color_space,(:srgb,:linear_srgb)),option(orientation,(:top_left,:bottom_left)),storage)
    end
end
image_metadata(::RasterPayload) = model_error(:unsupported,"raster provider must describe its immutable revision")
image_metadata(image::ImageData) = ImageMetadata(image.width,image.height;
    format=image.format,alpha=image.alpha,color_space=image.color_space,orientation=image.orientation)
raster_requirement(::RasterPayload) = model_error(:unsupported,"raster provider must declare its capability identifier")
raster_requirement(::ImageData) = :image

"""External immutable revision identity; availability requires explicit host leases."""
struct RasterReference <: RasterPayload
    namespace::UInt128
    asset::UInt64
    revision::UInt64
    metadata::ImageMetadata
    function RasterReference(namespace::Integer, asset::Integer, revision::Integer, metadata::ImageMetadata)
        0 < namespace <= typemax(UInt128) && 0 < asset <= typemax(UInt64) &&
            0 < revision <= typemax(UInt64) || model_error(:invalid_input,"invalid raster revision identity")
        metadata.storage === :tiled && metadata.orientation === :top_left ||
            model_error(:invalid_input,"raster revision requires top-left tiled storage")
        metadata.format in (:gray8,:rgb8,:bgr8,:rgba8,:bgra8) ||
            model_error(:invalid_input,"unsupported raster revision format")
        alpha = metadata.format in (:gray8,:rgb8,:bgr8) ? (:none,) : (:straight,:premultiplied)
        metadata.alpha in alpha || model_error(:invalid_input,"invalid raster revision alpha")
        new(UInt128(namespace),UInt64(asset),UInt64(revision),metadata)
    end
end
"""
    hash(reference::RasterReference, seed::UInt) -> UInt

Hash a source revision by its namespace, asset and revision identifiers.
Equality still includes metadata, so descriptors with inconsistent metadata
remain distinct keys even when their identifiers match.
"""
Base.hash(reference::RasterReference, seed::UInt) =
    hash((reference.namespace,reference.asset,reference.revision),seed)
image_metadata(reference::RasterReference) = reference.metadata
raster_requirement(::RasterReference) = :image_provider_revision_v1

struct FontData <: ResourcePayload
    family::String
    data::FrozenBytes
    FontData(family::AbstractString, bytes::AbstractVector{UInt8}) = new(String(family),FrozenBytes(bytes))
end

"""Portable surface result identity; backend objects live only in adapter registries."""
struct SurfaceData <: ResourcePayload
    producer::Symbol
    width::Int64
    height::Int64
    format::Symbol
    function SurfaceData(producer::Symbol, width::Integer, height::Integer; format::Symbol=:rgba8)
        w,h = checked_dimensions(width,height)
        return new(producer,w,h,option(format,(:rgba8,:rgba32f)))
    end
end

function checked_dimensions(width::Integer, height::Integer)
    width > 0 && height > 0 || model_error(:invalid_input, "dimensions must be positive")
    width <= typemax(Int64) && height <= typemax(Int64) || model_error(:size_overflow, "dimensions exceed Int64")
    w,h = Int64(width),Int64(height)
    w <= typemax(Int64) ÷ 4 ÷ h || model_error(:size_overflow, "RGBA8 byte count overflow")
    return (w,h)
end

function checked_dimensions(width::Real, height::Real)
    isfinite(width) && isfinite(height) && isinteger(width) && isinteger(height) ||
        model_error(:invalid_input, "physical dimensions must be finite integers")
    0 < width <= typemax(Int64) && 0 < height <= typemax(Int64) ||
        model_error(:size_overflow, "physical dimensions exceed Int64")
    return checked_dimensions(Int64(width),Int64(height))
end

portable_scalar(value) = value isa Union{Nothing,Bool,Symbol,String,
    Int8,Int16,Int32,Int64,Int128,UInt8,UInt16,UInt32,UInt64,UInt128}
portable_float(value) = value isa Union{Float16,Float32,Float64}

function portable_payload(value)
    if portable_scalar(value)
        return true
    elseif portable_float(value)
        return isfinite(value)
    elseif value isa Union{Tuple,NamedTuple}
        return all(portable_payload,value)
    elseif value isa ResourceRef
        return true
    elseif value isa Union{ResourcePayload,Transform2D,Color,PaintDescriptor,GradientStop,StrokeStyle,BoxBlur} &&
           !ismutabletype(typeof(value))
        return all(i -> portable_payload(getfield(value,i)),1:fieldcount(typeof(value)))
    end
    return false
end

struct ResourceRecord
    reference::ResourceRef
    payload::ResourcePayload
end

struct CapturedClip
    path::PathData
    transform::Transform2D
    winding::Symbol
    CapturedClip(path::PathData, transform::Transform2D, winding::Symbol) =
        new(path,transform,option(winding,(:nonzero,:evenodd)))
end

"""
    DrawingState(; kwargs...)

Capture immutable options for a retained drawing operation. Use
`configure!` to change selected options on an edit. Invalid options,
paint types, clips, or numeric values raise `ModelError`.

# Fields

- `fill` and `stroke` hold the two paint descriptors.
- `transform` maps local geometry into logical canvas coordinates.
- `clips` contains the intersected clip paths with their captured transforms.
- `opacity` scales the source alpha. `blend` selects the compositing operator.
- `profile` selects a rendering profile. `sampling` selects raster filtering.
- `stroke_style` defines how a path is stroked.
- `font` references a captured font resource. `font_size` is in logical units.
- `baseline`, `alignment`, and `direction` control text placement and flow.
"""
struct DrawingState
    fill::PaintDescriptor
    stroke::PaintDescriptor
    transform::Transform2D
    clips::Tuple
    opacity::Float64
    blend::Symbol
    profile::Symbol
    sampling::Symbol
    stroke_style::StrokeStyle
    font::Union{Nothing,ResourceRef}
    font_size::Float64
    baseline::Symbol
    alignment::Symbol
    direction::Symbol
    function DrawingState(; fill::PaintDescriptor=Solid(0,0,0), stroke::PaintDescriptor=Solid(0,0,0),
                          transform::Transform2D=Transform2D(), clips::Tuple=(), opacity::Real=1,
                          blend::Symbol=:source_over, profile::Symbol=:portable2d, sampling::Symbol=:linear,
                          stroke_style::StrokeStyle=StrokeStyle(), font::Union{Nothing,ResourceRef}=nothing,
                          font_size::Real=12, baseline::Symbol=:alphabetic, alignment::Symbol=:left,
                          direction::Symbol=:ltr)
        all(c -> c isa CapturedClip, clips) || model_error(:invalid_input, "invalid clip list")
        fill isa Union{Solid,LinearGradient} && stroke isa Union{Solid,LinearGradient} ||
            model_error(:unsupported, "unknown paint descriptor")
        return new(fill,stroke,transform,clips,unit_interval(opacity),
                   option(blend,(:source_over,:multiply)),option(profile,(:portable2d,:linear_light)),
                   option(sampling,(:nearest,:linear)),stroke_style,font,nonnegative(font_size),
                   option(baseline,(:top,:hanging,:middle,:alphabetic,:ideographic,:bottom)),
                   option(alignment,(:left,:center,:right)),option(direction,(:ltr,:rtl)))
    end
end

state_values(state::DrawingState) = NamedTuple{fieldnames(DrawingState)}(map(name -> getfield(state,name),fieldnames(DrawingState)))

struct FillPath <: SemanticOperation
    path::PathData
    state::DrawingState
    winding::Symbol
end
struct StrokePath <: SemanticOperation
    path::PathData
    state::DrawingState
end
struct ImageRegion <: SemanticOperation
    image::ResourceRef
    source::NTuple{4,Float64}
    destination::NTuple{4,Float64}
    state::DrawingState
end
struct TextRun <: SemanticOperation
    text::String
    position::NTuple{2,Float64}
    state::DrawingState
    glyphs::Tuple
    language::String
    script::Symbol
    features::Tuple
    fallback_fonts::Tuple
end
TextRun(text,position,state,glyphs,language,script,features) =
    TextRun(text,position,state,glyphs,language,script,features,())
struct ClearRegion <: SemanticOperation
    rectangle::NTuple{4,Float64}
    state::DrawingState
end
struct SurfaceRegion <: SemanticOperation
    surface::ResourceRef
    destination::NTuple{4,Float64}
    state::DrawingState
end
struct SemanticNode
    id::UInt64
    revision::UInt64
    operation::SemanticOperation
end
include("../retained/bounds.jl")
include("../retained/tree.jl")

struct CompositeGroup <: SemanticOperation
    nodes::Union{Tuple,SceneNodes}
    opacity::Float64
    blend::Symbol
    effect::Union{Nothing,BoxBlur}
    function CompositeGroup(nodes::Union{Tuple,SceneNodes}, opacity::Real, blend::Symbol, effect=nothing)
        effect === nothing || effect isa BoxBlur ||
            model_error(:unsupported,"unsupported group effect; expected nothing or BoxBlur")
        new(nodes,unit_interval(opacity),option(blend,(:source_over,:multiply)),effect)
    end
end

"""
    Frame

An immutable semantic revision returned by `snapshot` or `drawing`.
Renderers consume a frame at a chosen physical size. Provider-backed
resources retain their provider lifetime requirements.

# Fields

- `schema_version` identifies the semantic model version.
- `canvas` identifies the originating canvas and `revision` its edit version.
- `size` holds the logical width and height.
- `nodes` is the ordered sequence of retained drawing operations.
- `resources` contains captured immutable resource descriptors.
"""
struct Frame
    schema_version::UInt16
    canvas::UInt64
    revision::UInt64
    size::NTuple{2,Float64}
    nodes::Union{Tuple,SceneNodes}
    resources::Tuple
end
Base.show(io::IO, frame::Frame) = print(io,"Frame(",frame.size,", revision=",frame.revision,
    ", nodes=",length(frame.nodes),", resources=",length(frame.resources),")")
