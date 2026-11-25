using Cairo_jll: libcairo
using Fontconfig_jll: libfontconfig
import Skia
pushfirst!(LOAD_PATH, dirname(dirname(@__DIR__)))
using Vellum, Base64, SHA

"""Glyph ID and baseline position in the memory layout expected by cairo_show_glyphs."""
struct CairoGlyph
    index::Culong
    x::Cdouble
    y::Cdouble
end

"""Fail with the native API name when a reference renderer cannot allocate a handle."""
checked(pointer, name) = pointer == C_NULL ? error("$name returned null") : pointer

"""Draw positioned glyphs using Cairo's FreeType face for a specific font file and index."""
function cairo_mask(path, size, glyphs, width, height)
    # CAIRO_FORMAT_A8 uses one coverage byte per pixel and four-byte-aligned rows.
    stride = ccall((:cairo_format_stride_for_width,libcairo),Cint,(Cint,Cint),2,width)
    stride >= width || error("invalid Cairo mask stride")
    bytes = zeros(UInt8, stride*height)
    GC.@preserve bytes begin
        surface = ccall((:cairo_image_surface_create_for_data,libcairo),Ptr{Cvoid},
                        (Ptr{UInt8},Cint,Cint,Cint,Cint),bytes,2,width,height,stride)
        cr = ccall((:cairo_create,libcairo),Ptr{Cvoid},(Ptr{Cvoid},),surface)
        pattern = face = options = C_NULL
        try
            pattern = checked(ccall((:FcFreeTypeQuery,libfontconfig),Ptr{Cvoid},
                (Cstring,Cuint,Ptr{Cvoid},Ref{Cint}),path,0,C_NULL,Ref{Cint}(0)), "FcFreeTypeQuery")
            face = ccall((:cairo_ft_font_face_create_for_pattern,libcairo),Ptr{Cvoid},(Ptr{Cvoid},),pattern)
            ccall((:cairo_set_font_face,libcairo),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),cr,face)
            options = ccall((:cairo_font_options_create,libcairo),Ptr{Cvoid},())
            ccall((:cairo_font_options_set_antialias,libcairo),Cvoid,(Ptr{Cvoid},Cint),options,2)
            ccall((:cairo_font_options_set_hint_style,libcairo),Cvoid,(Ptr{Cvoid},Cint),options,1)
            ccall((:cairo_font_options_set_hint_metrics,libcairo),Cvoid,(Ptr{Cvoid},Cint),options,1)
            ccall((:cairo_set_font_options,libcairo),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),cr,options)
            ccall((:cairo_set_font_size,libcairo),Cvoid,(Ptr{Cvoid},Cdouble),cr,size)
            ccall((:cairo_show_glyphs,libcairo),Cvoid,(Ptr{Cvoid},Ptr{CairoGlyph},Cint),cr,glyphs,length(glyphs))
            ccall((:cairo_surface_flush,libcairo),Cvoid,(Ptr{Cvoid},),surface)
            ccall((:cairo_status,libcairo),Cint,(Ptr{Cvoid},),cr) == 0 || error("Cairo glyph drawing failed")
            ccall((:cairo_surface_status,libcairo),Cint,(Ptr{Cvoid},),surface) == 0 || error("Cairo image surface failed")
            return vec(copy(reshape(bytes,Int(stride),height)[1:width,:]))
        finally
            ccall((:cairo_destroy,libcairo),Cvoid,(Ptr{Cvoid},),cr)
            ccall((:cairo_surface_destroy,libcairo),Cvoid,(Ptr{Cvoid},),surface)
            options == C_NULL || ccall((:cairo_font_options_destroy,libcairo),Cvoid,(Ptr{Cvoid},),options)
            face == C_NULL || ccall((:cairo_font_face_destroy,libcairo),Cvoid,(Ptr{Cvoid},),face)
            pattern == C_NULL || ccall((:FcPatternDestroy,libfontconfig),Cvoid,(Ptr{Cvoid},),pattern)
        end
    end
end

"""Render the same glyph IDs at the same device positions to a Skia premultiplied raster surface."""
function skia_mask(face, size, glyphs, width, height)
    pixels = zeros(UInt8,4*width*height)
    info = Ref(Skia.sk_image_info_t(C_NULL,Skia.SK_COLOR_TYPE_RGBA_8888,Skia.SK_ALPHA_TYPE_PREMUL,width,height))
    GC.@preserve pixels begin
        surface = checked(Skia.sk_surface_make_raster_direct(info,pixels,Csize_t(4width),C_NULL), "Skia surface")
        paint = font = C_NULL
        try
            canvas = checked(Skia.sk_surface_get_canvas(surface),"Skia canvas")
            paint = checked(Skia.sk_paint_new(),"Skia paint")
            font = checked(Skia.sk_font_new_with_values(face,Float32(size),1f0,0f0),"Skia font")
            Skia.sk_font_set_hinting(font,Skia.SK_FONT_HINTING_NONE)
            # SkFont defaults to grayscale antialiasing on this raster surface.
            Skia.sk_font_set_subpixel(font,true)
            for glyph in glyphs
                Skia.sk_canvas_draw_simple_text(canvas,Ref(UInt16(glyph.index)),Csize_t(2),
                    Skia.SK_TEXT_ENCODING_GLYPH_ID,Float32(glyph.x),Float32(glyph.y),font,paint)
            end
            return pixels[4:4:end]
        finally
            font == C_NULL || Skia.sk_font_delete(font)
            paint == C_NULL || Skia.sk_paint_delete(paint)
            Skia.sk_surface_unref(surface)
        end
    end
end

"""Encode a coverage mask as an opaque black-on-white PNG for inspection at any zoom."""
function mask_png(mask,width,height)
    image = Image(width,height)
    for (i,alpha) in pairs(mask)
        level = 0xff-alpha
        image[i] = rgbx(level,level,level,0xff)
    end
    return "data:image/png;base64," * base64encode(encode_png(image))
end

"""Compare coverage over the union of the ink regions and write actual-size and enlarged masks."""
function render_case(io, path, bytes, face, text, size, origin)
    width,height = 180,40
    frame = drawing(size=(width,height)) do edit
        font = resource!(edit,:font,FontData("Liberation Sans",bytes))
        configure!(edit;font,font_size=size,fill=Solid(0,0,0))
        Vellum.capture_text!(edit,text,origin)
    end
    glyphs = CairoGlyph[]
    for node in only(frame.nodes).operation.nodes
        run = node.operation
        for (id,x,y,_) in run.glyphs
            push!(glyphs,CairoGlyph(id,run.position[1]+x,run.position[2]+y))
        end
    end
    masks = (Vellum=rasterize(frame).data[4:4:end],Cairo=cairo_mask(path,size,glyphs,width,height),
             Skia=skia_mask(face,size,glyphs,width,height))
    println(io,"<h2 dir=auto>",text," · ",size," px</h2><table><tr>")
    for (name,mask) in pairs(masks)
        any(!iszero,mask) || error("$name produced a blank mask for $text")
        png = mask_png(mask,width,height)
        println(io,"<td><b>",name,"</b><br><img src='",png,"'><br><img width='360' src='",png,"'></td>")
    end
    println(io,"</tr></table>")
    for (name,reference) in pairs((Cairo=masks.Cairo,Skia=masks.Skia))
        difference = UInt8.(abs.(Int.(masks.Vellum) .- Int.(reference)))
        ink_pixels = count(i -> !iszero(reference[i]) || !iszero(masks.Vellum[i]),eachindex(reference))
        mean_error = round(sum(difference)/ink_pixels;digits=2)
        println(io,"<p>Vellum / ",name," · mean absolute alpha error over ink ",mean_error,
                " / 255 · peak ",Int(maximum(difference))," / 255</p><img width='360' src='",
                mask_png(difference,width,height),"'>")
    end
end

"""Generate a self-contained comparison report from the pinned font and the installed reference binaries."""
function compare_fonts(output)
    path = joinpath(pkgdir(Vellum),"test","fixtures","LiberationSans-Regular.ttf")
    bytes = read(path)
    # This binding exposes a process-lifetime font manager and no manager release call.
    manager = checked(Skia.sk_fontmgr_ref_default(),"Skia font manager")
    data = checked(Skia.sk_data_new_with_copy(bytes,Csize_t(length(bytes))),"Skia font bytes")
    face = C_NULL
    try
        face = checked(Skia.sk_fontmgr_create_from_data(manager,data,Cint(0)),"Skia typeface")
        mkpath(dirname(output))
        mktemp(dirname(output)) do temporary,io
            cairo_version = unsafe_string(ccall((:cairo_version_string,libcairo),Cstring,()))
            println(io,"<!doctype html><meta charset=utf-8><title>Vellum glyph comparisons</title>",
                    "<style>body{font:16px system-ui;margin:2rem}td{padding:.5rem}img{image-rendering:pixelated}</style>",
                    "<h1>Positioned glyph comparisons</h1><p>Cairo ",cairo_version," · Skia.jl ",pkgversion(Skia),
                    " · Julia ",VERSION,"</p><p>Liberation Sans face 0 · grayscale · unhinted · font SHA-256 ",
                    bytes2hex(sha256(bytes)),"</p>")
            for (text,size,origin) in (("office AV",9,(3.0,24.0)),("Á ffi",12,(3.25,24.0)),
                                      ("AV אבג",16,(3.5,26.0)))
                render_case(io,path,bytes,face,text,size,origin)
            end
            close(io)
            Base.Filesystem.rename(temporary,output)
        end
    finally
        face == C_NULL || Skia.sk_typeface_unref(face)
        Skia.sk_data_unref(data)
    end
end

compare_fonts(isempty(ARGS) ? joinpath(pkgdir(Vellum),"reports","fonts.html") : abspath(only(ARGS)))
