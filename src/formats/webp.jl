"""
    decodeWebP(data; limits=ImageCodecs.CodecLimits()) -> Image

Decode the first composited WebP frame into an owned premultiplied RGBA image.
Use `ImageCodecs.eachframe` for all frames, their durations and disposal.
"""
function decodeWebP(data::Vector{UInt8}; limits=ImageCodecs.CodecLimits())
    C = ImageCodecs
    header = C.inspect_image(data; format=:webp, limits)
    return first(C.webp_frames(data,header,limits,Returns(false);first_only=true)).image
end

"""
    decodeWebPDimensions(data; limits=ImageCodecs.CodecLimits()) -> Tuple{Int,Int}

Inspect the bounded RIFF header and return the canvas width and height in pixels.
"""
function decodeWebPDimensions(data::Vector{UInt8}; limits=ImageCodecs.CodecLimits())
    header = ImageCodecs.inspect_image(data; format=:webp, limits)
    return (header.width, header.height)
end

"""
    encodeWebP(image; quality=nothing, limits=ImageCodecs.CodecLimits()) -> Vector{UInt8}

Encode an owned WebP byte stream. The default preserves premultiplied pixels
losslessly. An integer quality from 0 through 100 selects lossy RGB encoding
with lossless alpha.
"""
function encodeWebP(image::Image; quality=nothing, limits=ImageCodecs.CodecLimits())
    return ImageCodecs.encode_image(image;format=:webp,quality,limits).bytes
end
