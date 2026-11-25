"""Package identity used to load the WebP codec only when encoding or decoding pixels."""
const WEBP_PACKAGE = Base.PkgId(Base.UUID("c5f90fcd-3b7e-5836-afba-fc50a0988cb2"),"libwebp_jll")

"""ABI version of the libwebp 1.6 WebPAnimDecoder interface."""
const WEBP_DEMUX_ABI = 0x0107

"""Borrowed WebPData span. The Julia vector must outlive the decoder."""
struct WebPData
    bytes::Ptr{UInt8}
    size::Csize_t
end

"""Layout of libwebp's WebPAnimInfo. Dimensions and frame count describe its composited output."""
struct WebPAnimInfo
    width::UInt32
    height::UInt32
    loops::UInt32
    background::UInt32
    frames::UInt32
    padding::NTuple{4,UInt32}
end

"""Return the loaded JLL handle for an encoding or decoding operation."""
function webp_handle(library)
    package = Vellum._require_provider(WEBP_PACKAGE)
    return Base.invokelatest(getproperty,package,library)
end

"""Match the RIFF container type using only the first twelve bytes."""
webp_signature(data) = length(data) >= 12 && view(data,1:4) == codeunits("RIFF") &&
    view(data,9:12) == codeunits("WEBP")

"""Identify the animation flag in a WebP extended header."""
webp_animated(data) = length(data)>=21 && view(data,13:16)==codeunits("VP8X") && !iszero(data[21] & 0x02)

"""Read an unsigned little-endian field of one to four bytes without unaligned loads."""
webp_uint(data,start,count) = sum(Int64(data[start+i]) << (8i) for i in 0:count-1)

"""Read canvas dimensions and alpha interpretation without allocating pixels or reading compressed payloads."""
function webp_header(io,limits,cancelled)
    used = Ref(0)
    take(n) = take_header(io,n,used,limits,cancelled)
    riff = take(20)
    webp_signature(riff) || fail(:invalid_input,"invalid WebP signature")
    length_field = webp_uint(riff,5,4)
    length_field+8 <= limits.encoded_bytes || fail(:resource_limit,"WebP encoded byte limit exceeded")
    tag = String(riff[13:16])
    size = webp_uint(riff,17,4)
    size + isodd(size) + 12 <= length_field || fail(:invalid_input,"invalid WebP chunk size")
    if tag == "VP8X"
        size == 10 || fail(:invalid_input,"invalid extended WebP header")
        p = take(10)
        p[1] & 0x28 == 0 || fail(:unsupported,"WebP ICC and EXIF metadata need a color/orientation-aware provider")
        w,h = 1+webp_uint(p,5,3),1+webp_uint(p,8,3)
        alpha = !iszero(p[1] & 0x10)
    elseif tag == "VP8L"
        size >= 5 || fail(:invalid_input,"truncated lossless WebP header")
        p = take(5)
        p[1] == 0x2f && p[5] < 0x20 || fail(:invalid_input,"invalid lossless WebP header")
        bits = webp_uint(p,2,4)
        w,h = 1+(bits & 0x3fff),1+((bits >> 14) & 0x3fff)
        alpha = !iszero(p[5] & 0x10)
    elseif tag == "VP8 "
        size >= 10 || fail(:invalid_input,"truncated lossy WebP header")
        p = take(10)
        iseven(p[1]) && p[4:6] == UInt8[0x9d,0x01,0x2a] || fail(:invalid_input,"invalid VP8 key frame")
        w,h = webp_uint(p,7,2) & 0x3fff,webp_uint(p,9,2) & 0x3fff
        alpha = false
    else
        fail(:invalid_input,"missing WebP image header")
    end
    check_size(w,h,limits)
    return ImageHeader(w,h,:webp,alpha ? :rgba : :rgb,8,alpha ? :straight : :none,:srgb,:assumed,1)
end

"""Check the complete RIFF extent and budget all animation frames before opening a native decoder."""
function webp_controls(data,header,limits,cancelled)
    length(data) <= limits.encoded_bytes || fail(:resource_limit,"WebP encoded byte limit exceeded")
    webp_uint(data,5,4)+8 == length(data) || fail(:invalid_input,"WebP RIFF length mismatch")
    controls = Tuple{Int,Symbol}[]
    animated = webp_animated(data)
    max_frames = min(limits.frames,limits.decoded_bytes ÷ check_size(header.width,header.height,limits))
    pos = 13
    total_ms = Int64(0)
    while pos <= length(data)
        check_cancel(cancelled)
        pos+7 <= length(data) || fail(:invalid_input,"truncated WebP chunk")
        tag = view(data,pos:pos+3)
        size = webp_uint(data,pos+4,4)
        pos += 8
        size+isodd(size) <= length(data)-pos+1 || fail(:invalid_input,"truncated WebP payload")
        if tag == codeunits("ANMF")
            animated && size >= 16 || fail(:invalid_input,"unexpected WebP animation frame")
            length(controls) < max_frames || fail(:resource_limit,"WebP sequence exceeds frame or byte budget")
            x,y = 2*webp_uint(data,pos,3),2*webp_uint(data,pos+3,3)
            w,h = 1+webp_uint(data,pos+6,3),1+webp_uint(data,pos+9,3)
            x+w <= header.width && y+h <= header.height || fail(:invalid_input,"WebP frame outside canvas")
            ms = Int(webp_uint(data,pos+12,3))
            total_ms += ms
            total_ms <= typemax(Cint) || fail(:resource_limit,"WebP timeline exceeds native timestamp range")
            push!(controls,(ms,isodd(data[pos+15]) ? :background : :keep))
        elseif tag == codeunits("ICCP") || tag == codeunits("EXIF")
            fail(:unsupported,"WebP ICC and EXIF metadata need a color/orientation-aware provider")
        end
        pos += Int(size+isodd(size))
    end
    animated == !isempty(controls) || fail(:invalid_input,"missing WebP animation frames")
    return controls
end

"""Copy straight RGBA into an owned image and premultiply each sample. Source and destination may alias."""
function webp_premultiply!(image,src)
    for i in 1:length(image)
        k = 4i-3
        image[i] = Vellum.rgbx(Vellum.rgba(src[k],src[k+1],src[k+2],src[k+3]))
    end
    return image
end

"""Decode a still WebP into a size-checked Julia output buffer."""
function webp_still(data,header)
    w,h = Ref{Cint}(0),Ref{Cint}(0)
    library = webp_handle(:libwebp_handle)
    ccall(Vellum.Libdl.dlsym(library,:WebPGetInfo),Cint,
          (Ptr{UInt8},Csize_t,Ref{Cint},Ref{Cint}),data,length(data),w,h) == 1 &&
        (w[],h[]) == (header.width,header.height) || fail(:invalid_input,"invalid WebP canvas dimensions")
    image = Vellum.Image(header.width,header.height)
    result = ccall(Vellum.Libdl.dlsym(library,:WebPDecodeRGBAInto),Ptr{UInt8},
                   (Ptr{UInt8},Csize_t,Ptr{UInt8},Csize_t,Cint),
                   data,length(data),image.data,length(image.data),4*image.width)
    result == C_NULL && fail(:invalid_input,"could not decode WebP pixels")
    return webp_premultiply!(image,image.data)
end

"""Decode full composited canvases through libwebp, copying each before advancing the native iterator."""
function webp_frames(data,header,limits,cancelled;first_only=false)
    controls = webp_controls(data,header,limits,cancelled)
    if isempty(controls)
        image = webp_still(data,header)
        check_cancel(cancelled)
        return ImageSequence([AnimationFrame(image,0//1,:unspecified)],nothing)
    end
    count = length(controls)
    info = Ref{WebPAnimInfo}()
    pixels = Ref{Ptr{UInt8}}(C_NULL)
    timestamp = Ref{Cint}(0)
    frames = AnimationFrame[]
    library = webp_handle(:libwebpdemux_handle)
    next_frame = Vellum.Libdl.dlsym(library,:WebPAnimDecoderGetNext)
    GC.@preserve data begin
        input = Ref(WebPData(pointer(data),length(data)))
        decoder = ccall(Vellum.Libdl.dlsym(library,:WebPAnimDecoderNewInternal),Ptr{Cvoid},
                        (Ref{WebPData},Ptr{Cvoid},Cint),input,C_NULL,WEBP_DEMUX_ABI)
        decoder == C_NULL && fail(:invalid_input,"invalid WebP image data")
        try
            ccall(Vellum.Libdl.dlsym(library,:WebPAnimDecoderGetInfo),Cint,(Ptr{Cvoid},Ref{WebPAnimInfo}),decoder,info) == 1 &&
                (info[].width,info[].height,info[].frames) == (header.width,header.height,count) ||
                fail(:invalid_input,"WebP canvas or frame count disagrees with the container")
            elapsed_ms = 0
            for index in 1:(first_only ? 1 : count)
                check_cancel(cancelled)
                ccall(next_frame,Cint,(Ptr{Cvoid},Ref{Ptr{UInt8}},Ref{Cint}),
                      decoder,pixels,timestamp) == 1 || fail(:invalid_input,"could not decode WebP frame")
                image = Vellum.Image(header.width,header.height)
                src = unsafe_wrap(Vector{UInt8},pixels[],length(image.data))
                webp_premultiply!(image,src)
                ms,disposal = controls[index]
                elapsed_ms += ms
                timestamp[] == elapsed_ms || fail(:invalid_input,"WebP timestamp disagrees with the frame header")
                push!(frames,AnimationFrame(image,ms//1000,disposal))
            end
            check_cancel(cancelled)
            return ImageSequence(frames,Int(info[].loops))
        finally
            ccall(Vellum.Libdl.dlsym(library,:WebPAnimDecoderDelete),Cvoid,(Ptr{Cvoid},),decoder)
        end
    end
end

"""Encode straight RGBA derived from Vellum pixels, then transfer the libwebp output to Julia ownership."""
function webp_encode(image,quality)
    quality === nothing || 0 <= quality <= 100 || fail(:invalid_input,"WebP quality must be 0..100")
    max(image.width,image.height) <= 16383 || fail(:unsupported,"WebP encoder dimensions exceed 16383")
    bytes = Vellum._straight_rgba_bytes(image)
    output = Ref{Ptr{UInt8}}(C_NULL)
    library = webp_handle(:libwebp_handle)
    stride = 4*image.width
    if isnothing(quality)
        n = ccall(Vellum.Libdl.dlsym(library,:WebPEncodeLosslessRGBA),Csize_t,(Ptr{UInt8},Cint,Cint,Cint,Ref{Ptr{UInt8}}),
                  bytes,image.width,image.height,stride,output)
    else
        n = ccall(Vellum.Libdl.dlsym(library,:WebPEncodeRGBA),Csize_t,(Ptr{UInt8},Cint,Cint,Cint,Cfloat,Ref{Ptr{UInt8}}),
                  bytes,image.width,image.height,stride,quality,output)
    end
    try
        n > 0 && output[] != C_NULL || fail(:provider_failure,"WebP encoder failed")
        return copy(unsafe_wrap(Vector{UInt8},output[],Int(n)))
    finally
        ccall(Vellum.Libdl.dlsym(library,:WebPFree),Cvoid,(Ptr{Cvoid},),output[])
    end
end
