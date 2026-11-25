module ImageCodecs

import ..Vellum
const S = Vellum.ImageStorage
export CodecError, CodecLimits, ImageHeader, DecodedImage, CodecProvider, CodecRegistry,
       register_provider!, providers, detect_format, inspect_image, decode_image, encode_image,
       AnimationFrame, ImageSequence, eachframe,
       read_image, write_image

struct CodecError <: Exception
    code::Symbol
    message::String
end
Base.showerror(io::IO, error::CodecError) = print(io,error.code,": ",error.message)
fail(code, message) = throw(CodecError(code,message))

struct CodecLimits
    encoded_bytes::Int
    pixels::Int
    decoded_bytes::Int
    header_bytes::Int
    frames::Int
    function CodecLimits(;encoded_bytes=128*1024*1024, pixels=64*1024*1024,
                         decoded_bytes=512*1024*1024, header_bytes=1024*1024, frames=256)
        values = (encoded_bytes,pixels,decoded_bytes,header_bytes,frames)
        all(v -> v isa Integer && !(v isa Bool) && 0 < v <= typemax(Int),values) ||
            fail(:invalid_input,"codec limits must be positive machine-sized integers")
        new(Int.(values)...)
    end
end

"""Encoded dimensions and interpretation, before orientation/alpha normalization."""
struct ImageHeader
    width::Int
    height::Int
    format::Symbol
    channels::Symbol
    bit_depth::Int
    alpha::Symbol
    color_space::Symbol
    color_source::Symbol
    orientation::Int
end

"""Owned decoded CPU pixels plus the original header and explicit work accounting."""
struct DecodedImage
    buffer::S.PixelBuffer
    source::ImageHeader
    report::NamedTuple
end
Base.close(image::DecodedImage) = close(image.buffer)

"""An owned composited image, its exact display duration in seconds, and its source disposal rule."""
struct AnimationFrame
    image::Vellum.Image
    duration::Rational{Int}
    disposal::Symbol
end

"""
    ImageSequence(frames, loop_count)

An iterable collection of fully composited frames in display order. `loop_count`
stores the encoded loop value. In GIF, zero requests indefinite looping and
`nothing` means the file contained no loop directive.
"""
struct ImageSequence
    frames::Vector{AnimationFrame}
    loop_count::Union{Nothing,Int}
end
"""Return the number of decoded animation frames."""
Base.length(seq::ImageSequence) = length(seq.frames)
"""Yield each composited frame and its timing information in display order."""
Base.iterate(seq::ImageSequence,state=1) = iterate(seq.frames,state)
"""Iteration yields an owned image with timing and disposal metadata."""
Base.eltype(::Type{ImageSequence}) = AnimationFrame

"""Known magic bytes inherited by replacement providers for the standard image formats."""
const FORMAT_SIGNATURES = (png=(Vellum.PNG_SIGNATURE,), jpeg=((0xff,0xd8),),
    gif=map(codeunits,Vellum.GIF_SIGNATURES), qoi=(codeunits("qoif"),),
    ppm=(codeunits("P3"),codeunits("P6")), bmp=(codeunits("BM"),))

"""
    CodecProvider(name, format, available, inspect, decode, encode; probe, probe_bytes, decode_sequence)

Register callbacks for a raster format. Supply `nothing` for unavailable read
or write operations. An optional `probe(prefix)::Bool` recognizes the format
from at most `probe_bytes` encoded bytes. It must handle short inputs, including
empty ones. Standard formats inherit their signature probes. An optional
`decode_sequence(bytes, header, limits, cancelled)` returns an `ImageSequence`
and must enforce the frame and memory limits during decoding.
"""
struct CodecProvider
    name::Symbol
    format::Symbol
    available::Function
    inspect::Function
    decode::Union{Nothing,Function}
    encode::Union{Nothing,Function}
    probe::Union{Nothing,Function}
    probe_bytes::Int
    decode_sequence::Union{Nothing,Function}
    function CodecProvider(name,format,available,inspect,decode,encode;
                           probe=nothing,probe_bytes::Integer=0,decode_sequence=nothing)
        if probe === nothing && probe_bytes == 0
            signatures = get(FORMAT_SIGNATURES,format,())
            if !isempty(signatures)
                probe_bytes = maximum(length,signatures)
                probe = prefix -> any(signatures) do signature
                    length(prefix) >= length(signature) &&
                        all(i -> prefix[i] == signature[i],eachindex(signature))
                end
            end
        end
        0 <= probe_bytes <= typemax(Int) && ((probe === nothing) == iszero(probe_bytes)) ||
            fail(:invalid_input,"a codec probe requires a positive byte limit")
        return new(name,format,available,inspect,decode,encode,probe,Int(probe_bytes),decode_sequence)
    end
end
"""Codec providers for one decoding or encoding context, keyed by image format."""
struct CodecRegistry
    entries::Dict{Symbol,CodecProvider}
end
"""Register a provider and return it. Each format has one provider within a registry."""
function register_provider!(registry::CodecRegistry, provider::CodecProvider)
    haskey(registry.entries,provider.format) && fail(:invalid_input,"duplicate codec format")
    registry.entries[provider.format] = provider
end
function CodecRegistry(entries::AbstractVector{CodecProvider}=builtin_providers())
    registry = CodecRegistry(Dict{Symbol,CodecProvider}())
    foreach(p -> register_provider!(registry,p),entries)
    registry
end
function providers(registry::CodecRegistry=CodecRegistry())
    [(name=p.name,format=p.format,available=available(p),decode=p.decode !== nothing,
      encode=p.encode !== nothing,sequence=p.decode_sequence !== nothing) for p in sort!(collect(values(registry.entries));by=p->p.format)]
end
function available(provider)
    result = provider_call(provider.available)
    result isa Bool || fail(:provider_failure,"provider availability must return Bool")
    result
end

function check_cancel(cancelled)
    value = cancelled()
    value isa Bool || fail(:invalid_input,"cancellation callback must return Bool")
    value && fail(:cancelled,"codec operation cancelled; native calls are not preemptible")
end
function check_size(width, height, limits)
    width > 0 && height > 0 || fail(:invalid_input,"empty image dimensions")
    width <= limits.pixels ÷ height || fail(:resource_limit,"pixel limit exceeded")
    width <= limits.decoded_bytes ÷ 4 ÷ height || fail(:resource_limit,"decoded byte limit exceeded")
    Base.checked_mul(Base.checked_mul(width,height),4)
end
function take_header(io, n, used, limits, cancelled)
    check_cancel(cancelled)
    0 <= n <= limits.header_bytes-used[] || fail(:resource_limit,"header byte limit exceeded")
    data = read(io,n)
    used[] += length(data)
    length(data) == n || fail(:invalid_input,"truncated image header")
    data
end
be16(data, i) = (Int(data[i]) << 8) | Int(data[i+1])
be32(data, i) = (Int(data[i]) << 24) | (Int(data[i+1]) << 16) | (Int(data[i+2]) << 8) | Int(data[i+3])

function png_crc(data)
    crc = typemax(UInt32)
    for byte in data
        crc ⊻= UInt32(byte)
        for _ in 1:8
            crc = (crc >> 1) ⊻ (isodd(crc) ? UInt32(0xedb88320) : UInt32(0))
        end
    end
    ~crc
end
function png_header(io, limits, cancelled)
    used = Ref(0)
    take(n) = take_header(io,n,used,limits,cancelled)
    Tuple(take(8)) == Vellum.PNG_SIGNATURE || fail(:invalid_input,"invalid PNG signature")
    chunk = take(8)
    be32(chunk,1) == 13 && String(chunk[5:8]) == "IHDR" || fail(:invalid_input,"missing PNG IHDR")
    payload = take(13)
    UInt32(be32(take(4),1)) == png_crc(vcat(chunk[5:8],payload)) || fail(:invalid_input,"PNG IHDR CRC mismatch")
    w,h = be32(payload,1),be32(payload,5)
    check_size(w,h,limits)
    depth,kind = Int(payload[9]),Int(payload[10])
    permitted = kind == 0 ? (1,2,4,8,16) : kind == 3 ? (1,2,4,8) : (8,16)
    kind in (0,2,3,4,6) && depth in permitted || fail(:unsupported,"unsupported PNG samples")
    payload[11] == 0 && payload[12] == 0 && payload[13] <= 1 || fail(:unsupported,"unsupported PNG coding")
    alpha = kind in (4,6) ? :straight : :none
    declared = false
    palette = false
    while true
        chunk = take(8)
        size,tag = be32(chunk,1),String(chunk[5:8])
        if tag == "IDAT"
            kind == 3 && !palette && fail(:invalid_input,"indexed PNG has no palette")
            break
        end
        tag in ("iCCP","eXIf") && fail(:unsupported,"PNG profile/orientation requires another provider")
        tag in ("IHDR","IEND") && fail(:invalid_input,"PNG has no image data or a duplicate header")
        bytes = take(size)
        UInt32(be32(take(4),1)) == png_crc(vcat(chunk[5:8],bytes)) || fail(:invalid_input,"PNG header CRC mismatch")
        if tag == "sRGB"
            length(bytes) == 1 && bytes[1] <= 3 || fail(:invalid_input,"invalid PNG sRGB intent")
            declared = true
        elseif tag == "gAMA"
            length(bytes) == 4 && be32(bytes,1) == 45455 || fail(:unsupported,"only sRGB PNG gamma is supported")
            declared = true
        elseif tag == "cHRM"
            length(bytes) == 32 && [be32(bytes,i) for i in 1:4:32] ==
                [31270,32900,64000,33000,30000,60000,15000,6000] ||
                fail(:unsupported,"only sRGB PNG chromaticities are supported")
        elseif tag == "PLTE"
            0 < length(bytes) <= 768 && length(bytes) % 3 == 0 || fail(:invalid_input,"invalid PNG palette")
            palette = true
        elseif tag == "tRNS"
            alpha = :straight
        elseif isuppercase(Char(chunk[5]))
            fail(:unsupported,"unknown critical PNG chunk")
        end
    end
    channels = kind == 0 ? :gray : kind == 4 ? :gray_alpha : kind == 2 ? :rgb : kind == 6 ? :rgba : :indexed
    ImageHeader(w,h,:png,channels,depth,alpha,:srgb,declared ? :declared : :assumed,1)
end

function exif_orientation(data)
    length(data) >= 6 && data[1:6] == UInt8[0x45,0x78,0x69,0x66,0,0] || return 1
    tiff = data[7:end]
    length(tiff) >= 8 || fail(:invalid_input,"truncated EXIF")
    little = tiff[1:2] == UInt8[0x49,0x49]
    little || tiff[1:2] == UInt8[0x4d,0x4d] || fail(:invalid_input,"invalid EXIF byte order")
    u16(i) = little ? Int(tiff[i]) | (Int(tiff[i+1]) << 8) : be16(tiff,i)
    u32(i) = little ? u16(i) | (u16(i+2) << 16) : be32(tiff,i)
    u16(3) == 42 || fail(:invalid_input,"invalid TIFF magic")
    offset = u32(5)
    8 <= offset <= length(tiff)-2 || fail(:invalid_input,"invalid EXIF directory")
    count = u16(offset+1)
    count <= (length(tiff)-offset-2) ÷ 12 || fail(:invalid_input,"truncated EXIF directory")
    orientation = 1
    seen = false
    for n in 0:count-1
        index = offset+3+12n
        if u16(index) == 0x0112
            seen && fail(:invalid_input,"duplicate EXIF orientation")
            u16(index+2) == 3 && u32(index+4) == 1 || fail(:invalid_input,"invalid EXIF orientation type")
            orientation = u16(index+8)
            orientation in 1:8 || fail(:unsupported,"invalid EXIF orientation")
            seen = true
        end
    end
    orientation
end
function jpeg_header(io, limits, cancelled)
    used = Ref(0)
    take(n) = take_header(io,n,used,limits,cancelled)
    take(2) == UInt8[0xff,0xd8] || fail(:invalid_input,"invalid JPEG signature")
    w=h=0
    orientation=1
    seen_exif=false
    channels=:rgb
    while true
        take(1)[1] == 0xff || fail(:invalid_input,"invalid JPEG marker")
        marker = take(1)[1]
        while marker == 0xff
            marker = take(1)[1]
        end
        if marker == 0xda
            w > 0 || fail(:invalid_input,"JPEG has no frame header")
            break
        end
        marker in (0,0xd8,0xd9,0x01,0xd0,0xd1,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7) &&
            fail(:invalid_input,"unexpected JPEG marker")
        size = be16(take(2),1)
        size >= 2 || fail(:invalid_input,"invalid JPEG segment length")
        bytes = take(size-2)
        if marker in (0xc0,0xc2)
            w == 0 && length(bytes) >= 6 || fail(:invalid_input,"invalid JPEG frame header")
            bytes[1] == 8 && bytes[6] in (1,3) || fail(:unsupported,"only 8-bit gray/RGB JPEG is supported")
            h,w = be16(bytes,2),be16(bytes,4)
            check_size(w,h,limits)
            channels = bytes[6] == 1 ? :gray : :rgb
        elseif marker == 0xe1
            if length(bytes) >= 6 && bytes[1:6] == UInt8[0x45,0x78,0x69,0x66,0,0]
                seen_exif && fail(:invalid_input,"duplicate JPEG EXIF segment")
                orientation = exif_orientation(bytes)
                seen_exif=true
            end
        elseif marker == 0xe2 && length(bytes) >= 12 && bytes[1:12] == collect(codeunits("ICC_PROFILE\0"))
            fail(:unsupported,"JPEG ICC conversion requires another provider")
        elseif 0xc0 <= marker <= 0xcf && !(marker in (0xc4,0xc8,0xcc))
            fail(:unsupported,"unsupported JPEG frame coding")
        end
    end
    ImageHeader(w,h,:jpeg,channels,8,:none,:srgb,:assumed,orientation)
end

# Header inspection intentionally stops before compressed pixels. Whole-buffer
# decode additionally rejects hidden late metadata and variable-height coding.
function validate_container(data, format, cancelled)
    if format == :png
        position=9
        seen_data=false
        while position <= length(data)-11
            check_cancel(cancelled)
            size=be32(data,position)
            size <= length(data)-position-11 || fail(:invalid_input,"truncated PNG chunk")
            tag=String(data[position+4:position+7])
            tag == "IHDR" && position != 9 && fail(:invalid_input,"duplicate PNG header")
            if seen_data && tag in ("iCCP","cHRM","gAMA","sRGB","eXIf","tRNS","PLTE")
                fail(:unsupported,"PNG interpretation metadata appears after image data")
            end
            seen_data |= tag == "IDAT"
            position += size+12
            if tag == "IEND"
                size == 0 && position == length(data)+1 || fail(:invalid_input,"invalid PNG end")
                return
            end
        end
        fail(:invalid_input,"missing PNG end")
    elseif format == :jpeg
        position=3
        entropy=false
        seen_scan=false
        while position < length(data)
            position % 8192 == 0 && check_cancel(cancelled)
            if entropy && data[position] != 0xff
                position+=1
                continue
            end
            data[position] == 0xff || fail(:invalid_input,"invalid JPEG marker sequence")
            position+=1
            while position <= length(data) && data[position] == 0xff
                position+=1
            end
            position <= length(data) || fail(:invalid_input,"truncated JPEG marker")
            marker=data[position]
            position+=1
            if entropy && (marker == 0 || marker in 0xd0:0xd7)
                continue
            elseif marker == 0xd9
                position == length(data)+1 || fail(:invalid_input,"trailing JPEG content")
                return
            end
            marker == 0xdc && fail(:unsupported,"JPEG variable-height coding is unsupported")
            seen_scan && marker in (0xe1,0xe2) && fail(:unsupported,"JPEG metadata after its first scan is unsupported")
            position < length(data) || fail(:invalid_input,"truncated JPEG segment")
            size=be16(data,position)
            2 <= size <= length(data)-position+1 || fail(:invalid_input,"invalid JPEG segment extent")
            position+=size
            entropy=marker == 0xda
            seen_scan |= entropy
        end
        fail(:invalid_input,"missing JPEG end")
    end
end

"""Decode GIF within the caller's cumulative image and frame limits."""
function gif_data(data,header,limits,cancelled)
    Vellum.decodeGIF(data;max_pixels=limits.pixels,max_frames=limits.frames,
        max_decoded_bytes=limits.decoded_bytes,max_encoded_bytes=limits.encoded_bytes,cancelled)
end

"""Expose each composited GIF frame and preserve its centisecond delay and disposal rule."""
function gif_sequence(data,header,limits,cancelled)
    gif = gif_data(data,header,limits,cancelled)
    frames = [AnimationFrame(image,round(Int,100*delay)//100,disposal)
              for (image,delay,disposal) in zip(gif.frames,gif.intervals,gif.disposals)]
    return ImageSequence(frames,gif.loop_count)
end

include("webp_codec.jl")

function builtin_providers()
    [
        CodecProvider(:pngfiles,:png,()->Base.locate_package(Vellum._PNGFILES_PKGID) !== nothing,
                      png_header,(data,header,limits,cancelled)->Vellum.decodePNG(data),
                      (image,options)->Vellum.encodePNG(image)),
        CodecProvider(:jpegturbo,:jpeg,()->Base.locate_package(Vellum._JPEGTURBO_PKGID) !== nothing,
                      jpeg_header,(data,header,limits,cancelled)->begin
                          # A legal COM bypasses JpegTurbo's invalid 624-byte
                          # minimum for small grayscale files; workspace is owned.
                          if length(data) < 624
                              padding=max(4,624-length(data))
                              size=padding-2
                              data=vcat(data[1:end-2],UInt8[0xff,0xfe,size>>8,size&255],
                                        zeros(UInt8,padding-4),data[end-1:end])
                          end
                          Vellum.decodeJPEG(data)
                      end,
                      (image,options)->Vellum.encodeJPEG(image;quality=options.quality,background=options.background)),
        CodecProvider(:libwebp,:webp,()->Base.locate_package(WEBP_PACKAGE) !== nothing,
                      webp_header,(args...)->first(webp_frames(args...;first_only=true)).image,
                      (image,options)->webp_encode(image,options.quality);
                      probe=webp_signature,probe_bytes=12,decode_sequence=webp_frames),
        CodecProvider(:builtin,:gif,Returns(true),gif_header,
                      (args...)->first(gif_data(args...).frames),nothing;decode_sequence=gif_sequence),
        CodecProvider(:builtin,:qoi,Returns(true),qoi_header,
                      (data,header,limits,cancelled)->Vellum.newImage(Vellum.decodeQOI(data)),
                      (image,options)->collect(codeunits(Vellum.encodeQOI(image)))),
        CodecProvider(:builtin,:ppm,Returns(true),ppm_header,
                      (data,header,limits,cancelled)->Vellum.decodePPM(data),
                      (image,options)->collect(codeunits(Vellum.encodePPM(image)))),
        CodecProvider(:builtin,:bmp,Returns(true),bmp_header,
                      (data,header,limits,cancelled)->Vellum.decodeBMP(data),
                      (image,options)->collect(codeunits(Vellum.encodeBMP(image))))
    ]
end
function gif_header(io, limits, cancelled)
    bytes = take_header(io,13,Ref(0),limits,cancelled)
    String(bytes[1:6]) in Vellum.GIF_SIGNATURES || fail(:invalid_input,"invalid GIF signature")
    w,h = Vellum.gifRead16(bytes,7),Vellum.gifRead16(bytes,9)
    ImageHeader(w,h,:gif,:indexed,8,:straight,:srgb,:assumed,1)
end
function qoi_header(io, limits, cancelled)
    bytes = take_header(io,14,Ref(0),limits,cancelled)
    String(bytes[1:4]) == "qoif" && bytes[13] in (3,4) && bytes[14] in (0,1) ||
        fail(:invalid_input,"invalid QOI header")
    ImageHeader(be32(bytes,5),be32(bytes,9),:qoi,bytes[13] == 4 ? :rgba : :rgb,8,
                bytes[13] == 4 ? :straight : :none,bytes[14] == 0 ? :srgb : :linear_srgb,:declared,1)
end
function ppm_header(io, limits, cancelled)
    used = Ref(0)
    fields = String[]
    field = UInt8[]
    comment = false
    while length(fields) < 4
        byte = take_header(io,1,used,limits,cancelled)[1]
        if byte == UInt8('#')
            comment = true
        elseif byte == 0x0a
            comment = false
        end
        if !comment
            if Char(byte) in Vellum.PPM_WS
                if !isempty(field)
                    push!(fields,String(field))
                    field = UInt8[]
                end
            else
                push!(field,byte)
            end
        end
    end
    fields[1] == "P6" && fields[4] == "255" ||
        fail(:unsupported,"P3 and scaled/high-depth PPM compatibility support is retired; use binary P6 with max sample 255")
    w,h = tryparse(Int,fields[2]),tryparse(Int,fields[3])
    w !== nothing && h !== nothing || fail(:invalid_input,"invalid PPM dimensions")
    ImageHeader(w,h,:ppm,:rgb,8,:none,:srgb,:assumed,1)
end
function bmp_header(io, limits, cancelled)
    used = Ref(0)
    take(n) = take_header(io,n,used,limits,cancelled)
    file = take(14)
    file[1:2] == UInt8[0x42,0x4d] || fail(:invalid_input,"invalid BMP signature")
    le16(data,i) = Int(data[i]) | (Int(data[i+1]) << 8)
    le32(data,i) = le16(data,i) | (le16(data,i+2) << 16)
    first = take(4)
    size = le32(first,1)
    size in (40,108,124) || fail(:unsupported,"unsupported BMP header")
    dib = vcat(first,take(size-4))
    width,height = le32(dib,5),le32(dib,9)
    height = height >= 1<<31 ? (1<<32)-height : height
    bits,compression = le16(dib,15),le32(dib,17)
    le16(dib,13) == 1 && bits in (24,32) && compression in (0,3) ||
        fail(:unsupported,"indexed/compressed BMP compatibility support is retired; use uncompressed 24/32-bit BMP")
    (size == 40 && compression == 0) || (size > 40 && compression == 3 && bits == 32) ||
        fail(:unsupported,"unsupported BMP masks")
    le32(file,11) == 14+size || fail(:unsupported,"BMP has an unsupported pixel offset")
    if size > 40
        le32(dib,57) == 0x73524742 || fail(:unsupported,"BMP profile is not sRGB")
        [le32(dib,i) for i in (41,45,49,53)] == [0xff,0xff00,0xff0000,0xff000000] ||
            fail(:unsupported,"unsupported BMP channel masks")
        size == 124 && (le32(dib,113) != 0 || le32(dib,117) != 0) &&
            fail(:unsupported,"embedded BMP profiles are unsupported")
    end
    ImageHeader(width,height,:bmp,bits == 32 ? :rgba : :rgb,8,
                compression == 3 ? :straight : :none,:srgb,size > 40 ? :declared : :assumed,1)
end
function provider_for(registry, format)
    provider = get(registry.entries,format,nothing)
    provider === nothing && fail(:unsupported,"no registered provider for $format")
    provider
end
"""
    detect_format(bytes; registry=CodecRegistry(), limits=CodecLimits()) -> Symbol

Return the format recognized by exactly one registered probe. Each callback gets
a private prefix bounded by its declared size and the header budget. Supply an
explicit format to inspection or decoding when multiple formats match.
"""
function detect_format(bytes;registry=CodecRegistry(),limits=CodecLimits())
    matched = nothing
    for provider in values(registry.entries)
        provider.probe === nothing && continue
        count = min(provider.probe_bytes,limits.header_bytes,length(bytes))
        accepted = provider_call(provider.probe,bytes[1:count])
        accepted isa Bool || fail(:provider_failure,"format probe must return Bool")
        accepted || continue
        matched === nothing || fail(:invalid_input,"ambiguous image signature; supply format explicitly")
        matched = provider.format
    end
    matched === nothing && fail(:unsupported,"unrecognized or unsupported image signature")
    return matched
end

"""Consumes header bytes only; does not seek or close caller-owned IO."""
function inspect_image(io::IO;format::Symbol,limits=CodecLimits(),registry=CodecRegistry(),cancelled=()->false)
    check_cancel(cancelled)
    header = provider_call(provider_for(registry,format).inspect,io,limits,cancelled)
    header isa ImageHeader && header.format == format || fail(:provider_failure,"invalid provider header")
    check_size(header.width,header.height,limits)
    header.orientation in 1:8 && header.alpha in (:none,:straight) &&
        header.color_space in (:srgb,:linear_srgb) || fail(:unsupported,"unsupported source interpretation")
    header
end
"""Inspect encoded bytes using the requested format or the supplied registry's probes."""
function inspect_image(data::Vector{UInt8};format=nothing,registry=CodecRegistry(),limits=CodecLimits(),cancelled=()->false)
    check_cancel(cancelled)
    format === nothing && (format = detect_format(data;registry,limits))
    inspect_image(IOBuffer(data);format,registry,limits,cancelled)
end
function read_encoded(io, limits, cancelled)
    data = UInt8[]
    while !eof(io)
        check_cancel(cancelled)
        part = read(io,min(8192,limits.encoded_bytes-length(data)+1))
        isempty(part) && !eof(io) && fail(:io_error,"input IO made no progress")
        length(part) <= limits.encoded_bytes-length(data) || fail(:resource_limit,"encoded byte limit exceeded")
        append!(data,part)
    end
    data
end

function orient_image(image, orientation)
    orientation == 1 && return image
    w,h = image.width,image.height
    out = orientation <= 4 ? Vellum.newImage(w,h) : Vellum.newImage(h,w)
    for y in 1:h, x in 1:w
        dx,dy = orientation == 2 ? (w-x+1,y) : orientation == 3 ? (w-x+1,h-y+1) :
            orientation == 4 ? (x,h-y+1) : orientation == 5 ? (y,x) :
            orientation == 6 ? (h-y+1,x) : orientation == 7 ? (h-y+1,w-x+1) : (y,w-x+1)
        copyto!(out.data,4*((dy-1)*out.width+dx-1)+1,image.data,4*((y-1)*w+x-1)+1,4)
    end
    out
end
function provider_call(callback, args...)
    try
        Base.invokelatest(callback,args...)
    catch error
        error isa InterruptException && rethrow()
        error isa CodecError && rethrow()
        fail(:provider_failure,sprint(showerror,error))
    end
end

function decode_image(data::Vector{UInt8};format=nothing,limits=CodecLimits(),
                      registry=CodecRegistry(),cancelled=()->false)
    length(data) <= limits.encoded_bytes || fail(:resource_limit,"encoded byte limit exceeded")
    header = inspect_image(data;format,limits,registry,cancelled)
    format = header.format
    provider = provider_for(registry,format)
    available(provider) || fail(:provider_unavailable,"install/register provider $(provider.name) for $format")
    provider.decode !== nothing || fail(:unsupported,"provider cannot decode")
    format == :jpeg && (length(data) < 2 || data[end-1:end] != UInt8[0xff,0xd9]) &&
        fail(:invalid_input,"JPEG is missing its end marker")
    validate_container(data,format,cancelled)
    image = provider_call(provider.decode,data,header,limits,cancelled)
    image isa Vellum.Image || fail(:provider_failure,"decoder must return a legacy raster for this adapter")
    (image.width,image.height) == (header.width,header.height) ||
        fail(:provider_failure,"decoded dimensions differ from inspected source")
    count = check_size(image.width,image.height,limits)
    length(image.data) == count || fail(:provider_failure,"decoder returned invalid pixel extent")
    valid_pixels(image.data) || fail(:provider_failure,"decoder returned invalid premultiplied pixels")
    check_cancel(cancelled)
    image = orient_image(image,header.orientation)
    check_cancel(cancelled)
    descriptor = S.PixelDescriptor(image.width,image.height)
    buffer = S.wrap_buffer(image.data,descriptor;owner=image)
    conversions = (header.orientation != 1 ? (:orientation,) : (),
                   header.alpha == :straight ? (:premultiply,) : (),
                   header.bit_depth == 16 ? (:quantize8,) : ())
    DecodedImage(buffer,header,(encoded_buffer_bytes=0,owned_pixel_bytes=count,
                 orientation_copy_bytes=header.orientation == 1 ? 0 : count,provider_workspace_bytes=nothing,
                 conversions=(conversions[1]...,conversions[2]...,conversions[3]...,
                              (header.color_space == :linear_srgb ? (:transfer,) : ())...,
                              ((format == :gif || (format == :webp && webp_animated(data))) ? (:first_frame,) : ())...)))
end
function decode_image(io::IO;limits=CodecLimits(),cancelled=()->false,kwargs...)
    data = read_encoded(io,limits,cancelled)
    result = decode_image(data;limits,cancelled,kwargs...)
    DecodedImage(result.buffer,result.source,merge(result.report,(encoded_buffer_bytes=length(data),)))
end

"""
    eachframe(bytes; format=nothing, limits=CodecLimits(), registry=CodecRegistry(), cancelled=()->false)
    eachframe(io; kwargs...)

Decode a bounded image sequence and iterate its composited frames. Frames are
retained in memory up to the decoded-byte and frame-count limits. An unsupported
format raises `CodecError`. The caller retains ownership of an input stream.
"""
function eachframe(data::Vector{UInt8};format=nothing,limits=CodecLimits(),registry=CodecRegistry(),cancelled=()->false)
    length(data) <= limits.encoded_bytes || fail(:resource_limit,"encoded byte limit exceeded")
    header = inspect_image(data;format,limits,registry,cancelled)
    provider = provider_for(registry,header.format)
    available(provider) || fail(:provider_unavailable,"sequence provider is unavailable")
    provider.decode_sequence === nothing && fail(:unsupported,"provider cannot decode image sequences")
    seq = provider_call(provider.decode_sequence,data,header,limits,cancelled)
    seq isa ImageSequence || fail(:provider_failure,"expected an ImageSequence")
    frame_bytes = check_size(header.width,header.height,limits)
    0 < length(seq) <= min(limits.frames,limits.decoded_bytes ÷ frame_bytes) ||
        fail(:resource_limit,"decoded sequence exceeds frame or byte limits")
    for frame in seq
        check_cancel(cancelled)
        image = frame.image
        (image.width,image.height) == (header.width,header.height) && length(image.data) == frame_bytes &&
            valid_pixels(image.data) && frame.duration >= 0 || fail(:provider_failure,"invalid composited frame")
    end
    return seq
end

function eachframe(io::IO;limits=CodecLimits(),cancelled=()->false,kwargs...)
    return eachframe(read_encoded(io,limits,cancelled);limits,cancelled,kwargs...)
end
function read_image(path::AbstractString;kwargs...)
    open(io -> decode_image(io;kwargs...),path)
end

valid_pixels(bytes) = all(i -> max(bytes[i],bytes[i+1],bytes[i+2]) <= bytes[i+3],1:4:length(bytes))
function encode_image(image::Vellum.Image;format::Symbol,limits=CodecLimits(),
                      registry=CodecRegistry(),cancelled=()->false,quality::Union{Nothing,Int}=nothing,background=nothing)
    check_cancel(cancelled)
    count = check_size(image.width,image.height,limits)
    length(image.data) == count || fail(:invalid_input,"invalid raster extent")
    valid_pixels(image.data) || fail(:invalid_input,"invalid premultiplied pixels")
    quality === nothing && format !== :webp && (quality = 92)
    if format in (:jpeg,:ppm)
        1 <= quality <= 100 || fail(:invalid_input,"JPEG quality must be 1..100")
        opaque = all(==(0xff),@view image.data[4:4:end])
        !opaque && background === nothing && fail(:invalid_input,"JPEG alpha removal requires an explicit background")
    end
    background === nothing || background isa Vellum.ColorRGB || fail(:invalid_input,"background must be ColorRGB")
    provider = provider_for(registry,format)
    available(provider) || fail(:provider_unavailable,"install/register provider $(provider.name) for $format")
    provider.encode !== nothing || fail(:unsupported,"provider cannot encode")
    if format == :ppm && background !== nothing
        out = Vellum.newImage(image.width,image.height)
        for i in 1:4:count
            for (k,channel) in enumerate((background.r,background.g,background.b))
                out.data[i+k-1] = UInt8(Vellum._jpegComposite(Int(image.data[i+k-1]),Int(channel),Int(image.data[i+3])))
            end
            out.data[i+3] = 0xff
        end
        image = out
    end
    bytes = provider_call(provider.encode,image,(quality=quality,background=background === nothing ? Vellum.rgb(255,255,255) : background))
    bytes isa Vector{UInt8} || fail(:provider_failure,"encoder must return bytes")
    isempty(bytes) && fail(:provider_failure,"encoder returned an empty payload")
    length(bytes) <= limits.encoded_bytes || fail(:resource_limit,"encoded output limit exceeded")
    check_cancel(cancelled)
    (bytes=bytes,report=(encoded_buffer_bytes=length(bytes),source_staging_bytes=format == :ppm && background !== nothing ? count : 0,
                        codec_workspace_bytes=nothing))
end
function encode_image(io::IO,image;kwargs...)
    result = encode_image(image;kwargs...)
    bytes = result.bytes
    write(io,bytes) == length(bytes) || fail(:io_error,"short image write")
    merge(result.report,(written_bytes=length(bytes),))
end
function encode_image(source::S.AbstractImageProvider;limits=CodecLimits(),cancelled=()->false,kwargs...)
    check_cancel(cancelled)
    meta = S.image_metadata(source)
    check_size(meta.width,meta.height,limits)
    converted = S.convert_buffer(source;format=:rgba8,alpha=:premultiplied,color_space=:srgb,
                                 budget_bytes=limits.decoded_bytes)
    try
        S.with_pixels(converted.buffer) do lease
            GC.@preserve lease begin
                bytes = unsafe_wrap(Vector{UInt8},S.lease_pointer(lease),4*meta.width*meta.height;own=false)
                result = encode_image(Vellum.Image(meta.width,meta.height,bytes);limits,cancelled,kwargs...)
                (bytes=result.bytes,report=merge(result.report,(source_staging_bytes=
                    Base.checked_add(converted.report.copied_bytes,result.report.source_staging_bytes),)))
            end
        end
    finally
        close(converted.buffer)
    end
end
function write_image(path::AbstractString,image;kwargs...)
    result = encode_image(image;kwargs...)
    bytes = result.bytes
    temporary,io = mktemp(dirname(abspath(path)))
    try
        write(io,bytes) == length(bytes) || fail(:io_error,"short image write")
        close(io)
        Base.Filesystem.rename(temporary,path)
    finally
        isopen(io) && close(io)
        isfile(temporary) && rm(temporary)
    end
    merge(result.report,(written_bytes=length(bytes),))
end

end
