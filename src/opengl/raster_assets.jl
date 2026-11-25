"""Select and describe immutable dense source images for the native GPU adapters."""
module RasterAssets

import ...Vellum

"""Number of distinct dense images that can be sampled by a resident target."""
const SLOT_COUNT = 4
"""Largest admitted source image dimension in pixels."""
const MAX_SIDE = 256
"""Number of words in one native raster drawing descriptor."""
const RECORD_WORDS = 14
"""Fixed resident array of immutable image payloads and vacant slots."""
const Slots = NTuple{SLOT_COUNT,Union{Nothing,Vellum.ImageData}}
"""A slot array with no images yet uploaded."""
const EMPTY_SLOTS = ntuple(_ -> nothing, SLOT_COUNT)

"""C ABI view of an immutable RGBA8 source. Its owner must stay alive through the call."""
struct Upload
    pixels::Ptr{UInt8}
    slot::UInt32
    bytes::UInt32
end

"""One upload backed by owned linear bytes, rooted while the bridge copies them."""
struct StagedUpload
    slot::Int
    bytes::Union{String,Vector{UInt8}}
end

"""
    describe(uploads) -> Vector{Upload}

Convert owned, tightly packed upload bytes to native C views. Preserve the
`uploads` array for the duration of the native call. Packets are bounded by
the resident slot sizes, which fit both C integer fields.
"""
describe(uploads::Vector{StagedUpload}) =
    [Upload(pointer(item.bytes),UInt32(item.slot),UInt32(sizeof(item.bytes))) for item in uploads]

"""Return whether an image draw has a nonempty source and destination rectangle."""
drawable(op::Vellum.ImageRegion) =
    op.source[3] > 0 && op.source[4] > 0 && op.destination[3] > 0 && op.destination[4] > 0

"""
    validate_asset(payload) -> ImageData

Require a top-left, tightly packed premultiplied sRGB RGBA8 snapshot of at
most 256 × 256 pixels. Unsupported representations or dimensions throw
`ArgumentError`. The GPU reads little-endian RGBA8 words.
"""
function validate_asset(payload)
    payload isa Vellum.ImageData && 1 <= payload.width <= MAX_SIDE && 1 <= payload.height <= MAX_SIDE &&
        payload.format === :rgba8 && payload.alpha === :premultiplied && payload.color_space === :srgb &&
        payload.orientation === :top_left && payload.row_stride == 4*payload.width &&
        length(payload.pixels) == payload.row_stride*payload.height && ENDIAN_BOM == 0x04030201 ||
        throw(ArgumentError("native GPU images must be little-endian packed premultiplied RGBA8 up to 256 × 256"))
    return payload
end

"""
    collect_assets!(items, frame, nodes) -> nothing

Collect distinct visible-use payloads in drawing order, including child
groups. Throw on an unsupported image or a fifth distinct payload.
"""
function collect_assets!(items::Vector{Vellum.ImageData}, frame::Vellum.Frame, nodes)
    for node in nodes
        op = node.operation
        if op isa Vellum.CompositeGroup
            collect_assets!(items, frame, op.nodes)
        elseif op isa Vellum.ImageRegion && drawable(op)
            resource = Vellum.resource(frame, op.image)
            resource isa Vellum.RasterReference && continue
            asset = validate_asset(resource)
            any(item -> item === asset, items) && continue
            length(items) < SLOT_COUNT || throw(ArgumentError("native image slot limit exceeded"))
            push!(items, asset)
        end
    end
    return nothing
end

"""
    select_slots(frame, resident=EMPTY_SLOTS) -> Slots

Keep reused images in their completed slots and fill vacancies with new
images in drawing order. Snapshot pixels are shared throughout. A plan with
unsupported resources, extents or too many active images throws.
"""
function select_slots(frame::Vellum.Frame, resident::Slots=EMPTY_SLOTS)::Slots
    active = Vellum.ImageData[]
    collect_assets!(active, frame, frame.nodes)
    slots = Union{Nothing,Vellum.ImageData}[
        any(item -> item === asset, active) ? asset : nothing for asset in resident
    ]
    for asset in active
        any(item -> item === asset, slots) && continue
        slots[findfirst(isnothing, slots)] = asset
    end
    return Tuple(slots)
end

"""
    uploads(before, after) -> Vector{StagedUpload}

Collect only changed, nonempty dense slots and retain their immutable bytes.
"""
function uploads(before::Slots, after::Slots)
    pending = StagedUpload[]
    for (index, asset) in pairs(after)
        asset === nothing && continue
        asset === before[index] && continue
        push!(pending, StagedUpload(index-1,asset.pixels.bytes))
    end
    return pending
end

"""Build the shared physical-to-source affine map. Reject nonfinite or excessive coefficients."""
function source_mapping(op::Vellum.ImageRegion, transform)
    x,y,w,h = op.destination
    sx,sy,sw,sh = op.source
    mapping = Vellum.Transform2D(sw/w,0,0,sh/h,sx-x*sw/w,sy-y*sh/h) *
        Vellum.PortableGeometry.inverse_transform(transform)
    all(v -> isfinite(v) && abs(v) <= 1e12, mapping.coefficients) ||
        throw(ArgumentError("GPU image mapping exceeds the native range"))
    return mapping
end

"""Return the inclusive source texel crop. Reject a range with no addressable sample."""
function crop_bounds(op::Vellum.ImageRegion)
    sx,sy,sw,sh = op.source
    crop = (floor(Int,sx),floor(Int,sy),ceil(Int,sx+sw)-1,ceil(Int,sy+sh)-1)
    crop[1] <= crop[3] && crop[2] <= crop[4] || throw(ArgumentError("empty raster texel crop"))
    return crop
end

"""
    append_record!(records, frame, slots, op, transform) -> Int

Append the resident slot, inclusive filter crop, sampling mode and affine
mapping in physical coordinates. This uses the same inverse mapping and
crop boundaries as CPU rendering. Throw on missing or invalid geometry,
an unsupported sampling mode, or an out-of-profile mapping.
"""
function append_record!(records, frame, slots::Slots, op::Vellum.ImageRegion, transform)
    asset = Vellum.resource(frame, op.image)
    slot = findfirst(item -> item === asset, slots)
    slot === nothing && throw(ArgumentError("image has no selected resident GPU slot"))
    crop = crop_bounds(op)
    0 <= crop[1] <= crop[3] < asset.width && 0 <= crop[2] <= crop[4] < asset.height ||
        throw(ArgumentError("image source crop exceeds dense asset bounds"))
    mapping = source_mapping(op,transform)
    filter = op.state.sampling
    filter in (:nearest, :linear) || throw(ArgumentError("unsupported GPU image filter"))
    index = length(records) ÷ RECORD_WORDS
    append!(records, (slot-1,asset.width,asset.height,crop...,Int(filter === :linear),mapping.coefficients...))
    return index
end

end
