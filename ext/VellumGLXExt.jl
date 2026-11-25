"""First-party offscreen OpenGL renderer for X11 displays."""
module VellumGLXExt

import Vellum as V
import Skia as S
@static if Sys.islinux() || Sys.isfreebsd()
    # Resolve the same dispatch objects that the display toolkit opens by SONAME.
    """GLX dispatch library used by the native window system."""
    const libGLX = "libGLX.so.0"
    """OpenGL entry points for the bound GLX context."""
    const libGL = "libGL.so.1"
    """EGL dispatch library for saving and restoring external contexts."""
    const libEGL = "libEGL.so.1"
    using Xorg_libX11_jll: libX11
end

"""Surface-owned GPU textures for immutable dense crops and tiled source pages."""
const TextureCache = Dict{V.OpenGLBackend.DesktopTextureKey,Ptr{S.sk_image_t}}

"""Unpublished texture references and framebuffer snapshot guarded by one driver fence."""
mutable struct PendingDraw
    images::TextureCache
    snapshot::Ptr{S.sk_image_t}
    fence::Ptr{Cvoid}
    uploaded_bytes::Int
    pages::Int
end

"""Owned GLX and Skia objects. A null display marks a closed target."""
mutable struct Target
    size::Tuple{Int,Int}
    owner::Int
    display::Ptr{Cvoid}
    drawable::Culong
    context::Ptr{Cvoid}
    engine::Ptr{S.gr_direct_context_t}
    target::Ptr{S.gr_backendrendertarget_t}
    surface::Ptr{S.sk_surface_t}
    vendor::String
    renderer::String
    frames::Int
    snapshot::Ptr{S.sk_image_t}
    images::TextureCache
    pending::Union{Nothing,V.OpenGLBackend.DesktopSubmission}
    uploaded_bytes::Int
    committed_upload_bytes::Int
end

"""Turn a failed driver allocation into a named error before dereferencing it."""
checked(ptr,name) = ptr == C_NULL ? error("OpenGL could not create $name") : ptr

"""Check that the current Julia thread owns the target."""
check_thread(t) = t.owner == Threads.threadid() || throw(ArgumentError("OpenGL target belongs to another thread"))

"""Make a GLX context current on its draw and read drawables."""
function bind_glx(display,draw,read,context)
    ccall((:glXMakeContextCurrent,libGLX),Cint,(Ptr{Cvoid},Culong,Culong,Ptr{Cvoid}),
          display,draw,read,context) != 0 || error("could not bind GLX context")
end

"""Run with the target current and restore the caller's original GLX bindings on every exit."""
function with_context(f,t)
    check_thread(t)
    t.display != C_NULL || throw(ArgumentError("OpenGL target is closed"))
    egl = ccall((:eglGetCurrentContext,libEGL),Ptr{Cvoid},())
    egl_display = ccall((:eglGetCurrentDisplay,libEGL),Ptr{Cvoid},())
    egl_draw = ccall((:eglGetCurrentSurface,libEGL),Ptr{Cvoid},(Cint,),0x3059)
    egl_read = ccall((:eglGetCurrentSurface,libEGL),Ptr{Cvoid},(Cint,),0x305a)
    prior = ccall((:glXGetCurrentContext,libGLX),Ptr{Cvoid},())
    display = ccall((:glXGetCurrentDisplay,libGLX),Ptr{Cvoid},())
    draw = ccall((:glXGetCurrentDrawable,libGLX),Culong,())
    read = ccall((:glXGetCurrentReadDrawable,libGLX),Culong,())
    if egl != C_NULL
        ccall((:eglMakeCurrent,libEGL),Cuint,(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}),
              egl_display,C_NULL,C_NULL,C_NULL) != 0 || error("could not detach the host EGL context")
    end
    try
        bind_glx(t.display,t.drawable,t.drawable,t.context)
        try
            return f()
        finally
            bind_glx(prior == C_NULL ? t.display : display,draw,read,prior)
        end
    finally
        if egl != C_NULL
            ccall((:eglMakeCurrent,libEGL),Cuint,(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}),
                  egl_display,egl_draw,egl_read,egl) != 0 || error("could not restore the host EGL context")
        end
    end
end

"""Check symbolic vendor selectors or query the driver's exact PCI IDs when available."""
function match_device(t,screen,selector)
    selector === :auto && return
    if selector isa Symbol
        vendor = lowercase(t.vendor)
        matches = selector === :amd ? (occursin("amd",vendor) || occursin("ati",vendor)) :
                                      occursin(String(selector),vendor)
        matches || throw(ArgumentError("the X11 OpenGL device reports vendor $(t.vendor)"))
        return
    end
    extensions = ccall((:glXQueryExtensionsString,libGLX),Cstring,(Ptr{Cvoid},Cint),t.display,screen)
    extensions != C_NULL && "GLX_MESA_query_renderer" in split(unsafe_string(extensions)) ||
        throw(ArgumentError("the X11 driver cannot identify its device by PCI ID"))
    query = checked(ccall((:glXGetProcAddress,libGLX),Ptr{Cvoid},(Cstring,),
                          "glXQueryCurrentRendererIntegerMESA"),"GLX device query")
    for (key,expected) in zip((0x8183,0x8184),selector)
        value = Ref{Cuint}()
        ccall(query,Cint,(Cint,Ref{Cuint}),key,value) != 0 && value[] == expected ||
            throw(ArgumentError("the X11 OpenGL device does not match PCI selector $selector"))
    end
end

"""Allocate a private pixel buffer on the X11 display and wrap its framebuffer in Skia."""
function open_target(size,device)
    width,height = size
    max(width,height) <= typemax(Cint) || throw(ArgumentError("OpenGL surface extent exceeds the GLX ABI"))
    display = ccall((:XOpenDisplay,libX11),Ptr{Cvoid},(Cstring,),C_NULL)
    display != C_NULL || throw(ArgumentError("desktop OpenGL requires an accessible X11 display"))
    t = Target(size,Threads.threadid(),display,0,C_NULL,C_NULL,C_NULL,C_NULL,"","",0,C_NULL,TextureCache(),nothing,0,0)
    try
        screen = ccall((:XDefaultScreen,libX11),Cint,(Ptr{Cvoid},),display)
        # Pbuffer, RGBA rendering, single buffer, RGBA8, eight stencil bits.
        attributes = Cint[0x8010,4,0x8011,1,5,0,8,8,9,8,10,8,11,8,13,8,0]
        count = Ref{Cint}()
        configs = ccall((:glXChooseFBConfig,libGLX),Ptr{Ptr{Cvoid}},
            (Ptr{Cvoid},Cint,Ptr{Cint},Ref{Cint}),display,screen,attributes,count)
        checked(configs,"GLX framebuffer configurations")
        config = try
            count[] > 0 || error("no GLX RGBA8 pbuffer configuration")
            unsafe_load(configs)
        finally
            ccall((:XFree,libX11),Cint,(Ptr{Cvoid},),configs)
        end
        for (key,extent) in zip((0x8016,0x8017),size)
            limit = Ref{Cint}()
            status = ccall((:glXGetFBConfigAttrib,libGLX),Cint,
                (Ptr{Cvoid},Ptr{Cvoid},Cint,Ref{Cint}),display,config,key,limit)
            status == 0 || error("could not query the GLX pbuffer limit")
            limit[] > 0 && extent > limit[] && throw(ArgumentError("extent exceeds the GLX pbuffer limit"))
        end
        t.context = checked(ccall((:glXCreateNewContext,libGLX),Ptr{Cvoid},
            (Ptr{Cvoid},Ptr{Cvoid},Cint,Ptr{Cvoid},Cint),display,config,0x8014,C_NULL,1),"GLX context")
        t.drawable = ccall((:glXCreatePbuffer,libGLX),Culong,(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cint}),
                           display,config,Cint[0x8041,width,0x8040,height,0x801c,1,0])
        t.drawable != 0 || error("could not create GLX pbuffer")
        # Some drivers report zero limits. GLX_LARGEST_PBUFFER permits a smaller
        # allocation in that case. Check its actual size before wrapping the target.
        for (key,expected) in zip((0x801d,0x801e),size)
            actual = Ref{Cuint}()
            ccall((:glXQueryDrawable,libGLX),Cvoid,(Ptr{Cvoid},Culong,Cint,Ref{Cuint}),
                  display,t.drawable,key,actual)
            actual[] == expected || throw(ArgumentError("driver could not allocate the requested GLX extent"))
        end
        with_context(t) do
            t.vendor = unsafe_string(checked(ccall((:glGetString,libGL),Cstring,(Cuint,),0x1f00),"vendor string"))
            t.renderer = unsafe_string(checked(ccall((:glGetString,libGL),Cstring,(Cuint,),0x1f01),"renderer string"))
            match_device(t,screen,device)
            interface = checked(S.gr_glinterface_create_native_interface(),"GL interface")
            try
                t.engine = checked(S.gr_direct_context_make_gl(interface),"Skia GL context")
            finally
                S.gr_glinterface_unref(interface)
            end
            stencil = Ref{Cint}()
            ccall((:glGetIntegerv,libGL),Cvoid,(Cuint,Ref{Cint}),0x0d57,stencil)
            info = Ref(S.gr_gl_framebufferinfo_t(0,0x8058,false))
            t.target = checked(S.gr_backendrendertarget_new_gl(Cint(width),Cint(height),Cint(0),stencil[],info),"GL render target")
            drawable_surface = checked(S.sk_surface_new_backend_render_target(t.engine,t.target,
                S.GR_SURFACE_ORIGIN_BOTTOM_LEFT,S.SK_COLOR_TYPE_RGBA_8888,C_NULL,C_NULL),"GL drawing surface")
            try
                # A texture-backed surface provides immutable GPU snapshots as the next draw begins.
                t.surface = checked(S.sk_surface_make_surface(drawable_surface,Cint(width),Cint(height)),"offscreen texture")
            finally
                S.sk_surface_unref(drawable_surface)
            end
        end
        return t
    catch
        release!(t)
        rethrow()
    end
end

"""Destroy native resources in reverse acquisition order. May also unwind a partly constructed target."""
function release!(t)
    check_thread(t)
    t.display == C_NULL && return
    !isnothing(t.pending) && t.pending.state === :recording && throw(ArgumentError("OpenGL draw is recording"))
    if t.engine != C_NULL
        with_context(t) do
            S.gr_direct_context_flush_and_submit(t.engine,true)
            if t.pending !== nothing
                discard!(t.pending,:cancelled)
            end
            foreach(S.sk_image_unref,values(t.images))
            empty!(t.images)
            t.snapshot == C_NULL || S.sk_image_unref(t.snapshot)
            t.snapshot = C_NULL
            t.surface == C_NULL || S.sk_surface_unref(t.surface)
            t.target == C_NULL || S.gr_backendrendertarget_delete(t.target)
            S.gr_direct_context_unref(t.engine)
        end
    end
    t.drawable == 0 || ccall((:glXDestroyPbuffer,libGLX),Cvoid,(Ptr{Cvoid},Culong),t.display,t.drawable)
    t.context == C_NULL || ccall((:glXDestroyContext,libGLX),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),t.display,t.context)
    ccall((:XCloseDisplay,libX11),Cint,(Ptr{Cvoid},),t.display)
    t.display = C_NULL
    return nothing
end

"""Build a device path in physical pixels and release it after the callback."""
function with_path(f,geom)
    path = checked(S.sk_path_new(),"path")
    try
        rule = geom.winding === :evenodd ? S.SK_PATH_FILLTYPE_EVENODD : S.SK_PATH_FILLTYPE_WINDING
        S.sk_path_set_filltype(path,rule)
        for points in V.OpenGLBackend.device_contours(geom)
            isempty(points) && continue
            S.sk_path_move_to(path,first(points)...)
            for i in 2:length(points)
                S.sk_path_line_to(path,points[i]...)
            end
            S.sk_path_close(path)
        end
        return f(path)
    finally
        S.sk_path_delete(path)
    end
end

"""
    upload_texture(target, bytes, size)

Copy packed premultiplied RGBA8 texels to an owned Skia GPU texture in the bound context.
"""
function upload_texture(target,bytes,size)
    width,height = size
    info = Ref(S.sk_image_info_t(C_NULL,S.SK_COLOR_TYPE_RGBA_8888,S.SK_ALPHA_TYPE_PREMUL,width,height))
    data = GC.@preserve bytes checked(S.sk_data_new_with_copy(pointer(bytes),Csize_t(sizeof(bytes))),"image storage")
    raster = try
        checked(S.sk_image_new_raster_data(info,data,Csize_t(4width)),"source image")
    finally
        S.sk_data_unref(data)
    end
    try
        return checked(S.sk_image_texture_from_image(target.engine,raster,false,false),"resident texture")
    finally
        S.sk_image_unref(raster)
    end
end

"""Reuse a published texture or upload the supplied bytes once for this candidate."""
function resident_texture!(load,target,candidate,key,extent)
    return get!(candidate.images,key) do
        V.OpenGLBackend.reserve_desktop_page!(candidate,key)
        haskey(target.images,key) && return target.images[key]
        bytes = load()
        texture = upload_texture(target,bytes,extent)
        target.uploaded_bytes += sizeof(bytes)
        candidate.uploaded_bytes += sizeof(bytes)
        return texture
    end
end

"""Draw cached source pages into one crop texture so linear interpolation crosses page boundaries."""
function tiled_texture(target,candidate,p,retention)
    surface = checked(S.sk_surface_make_surface(target.surface,Cint(p.size[1]),Cint(p.size[2])),"tiled crop texture")
    try
        canvas = S.sk_surface_get_canvas(surface)
        S.sk_canvas_clear(canvas,UInt32(0))
        nearest = Ref(S.sk_sampling_options_t(0,false,S.sk_cubic_resampler_t(0,0),S.SK_FILTER_MODE_NEAREST,S.SK_MIPMAP_MODE_NONE))
        V.OpenGLBackend.visit_desktop_pages(retention,p) do key,(x,y),load
            w,h = V.OpenGLBackend.RasterPages.dimensions(key)
            tex = resident_texture!(load,target,candidate,key,(w,h))
            src = Ref(S.sk_rect_t(0,0,w,h))
            dst = Ref(S.sk_rect_t(x,y,x+w,y+h))
            S.sk_canvas_draw_image_rect(canvas,tex,src,dst,nearest,C_NULL,S.SRC_RECT_CONSTRAINT_STRICT)
        end
        return checked(S.sk_surface_make_image_snapshot(surface),"tiled crop snapshot")
    finally
        S.sk_surface_unref(surface)
    end
end

"""Draw a cropped image and reuse its GPU texture across placements and consecutive frames."""
function draw_image_node(canvas,node,frame,viewport,paint,target,candidate,retention)
    p = V.OpenGLBackend.image_placement(node,frame,viewport)
    isnothing(p) && return
    if !isnothing(p.mask)
        with_path(path->S.sk_canvas_clip_path_with_operation(canvas,path,S.SK_CLIP_OP_INTERSECT,true),p.mask)
    end
    a,b,c,d,x,y = p.transform.coefficients
    S.sk_canvas_concat(canvas,Ref(S.sk_matrix_t(a,c,x,b,d,y,0,0,1)))
    tiled = p.source isa V.RasterReference
    texture = if tiled
        tiled_texture(target,candidate,p,retention)
    else
        resident_texture!(() -> V._dense_crop(p.source,p.crop).data,target,candidate,(p.source,p.crop),p.size)
    end
    try
        S.sk_paint_set_shader(paint,C_NULL)
        S.sk_paint_set_color(paint,argb(V.Color(1,1,1),node.operation.state.opacity))
        filter = node.operation.state.sampling===:nearest ? S.SK_FILTER_MODE_NEAREST : S.SK_FILTER_MODE_LINEAR
        sampling = Ref(S.sk_sampling_options_t(0,false,S.sk_cubic_resampler_t(0,0),filter,S.SK_MIPMAP_MODE_NONE))
        rect = Ref(S.sk_rect_t(0,0,p.size...))
        S.sk_canvas_draw_image_rect(canvas,texture,rect,rect,sampling,paint,S.SRC_RECT_CONSTRAINT_STRICT)
    finally
        tiled && S.sk_image_unref(texture)
    end
end

"""Pack straight sRGB and drawing opacity for Skia."""
function argb(color,opacity)
    r,g,b,a = color.channels
    return round(UInt32,255a*opacity)<<24 | round(UInt32,255r)<<16 | round(UInt32,255g)<<8 | round(UInt32,255b)
end

"""Render one prepared semantic operation inside the current Skia canvas state."""
function draw_node(canvas,node,viewport,paint,frame,target,candidate,retention)
    op = node.operation
    level = S.sk_canvas_get_save_count(canvas)
    try
        if op isa V.CompositeGroup
            S.sk_canvas_save_layer_alpha(canvas,C_NULL,round(UInt8,255op.opacity))
            foreach(child -> draw_node(canvas,child,viewport,paint,frame,target,candidate,retention),op.nodes)
            return
        end
        S.sk_canvas_save(canvas)
        state = op.state
        for clip in state.clips
            with_path(V.OpenGLBackend.device_geometry(clip.path,viewport*clip.transform,clip.winding)) do path
                S.sk_canvas_clip_path_with_operation(canvas,path,S.SK_CLIP_OP_INTERSECT,true)
            end
        end
        op isa V.ImageRegion && return draw_image_node(canvas,node,frame,viewport,paint,target,candidate,retention)
        stroke = op isa V.StrokePath
        brush = stroke ? state.stroke : state.fill
        S.sk_paint_set_shader(paint,C_NULL)
        if brush isa V.LinearGradient
            points = S.sk_point_t[S.sk_point_t(p...) for p in V.OpenGLBackend.gradient_axis(brush,state,viewport)]
            colors = UInt32[argb(stop.color,1) for stop in brush.stops]
            positions = Float32[stop.position for stop in brush.stops]
            shader = checked(S.sk_shader_new_linear_gradient(points,colors,positions,Cint(length(colors)),S.SK_TILE_MODE_CLAMP,C_NULL),"gradient")
            try
                S.sk_paint_set_shader(paint,shader)
            finally
                S.sk_shader_unref(shader)
            end
            S.sk_paint_set_color(paint,argb(V.Color(1,1,1),state.opacity))
        else
            S.sk_paint_set_color(paint,argb(brush.color,state.opacity))
        end
        geom = V.OpenGLBackend.node_geometry(node,frame,viewport)
        with_path(path -> S.sk_canvas_draw_path(canvas,path,paint),geom)
    finally
        S.sk_canvas_restore_to_count(canvas,level)
    end
end

"""
    record_frame!(target, frame, candidate, retention)

Draw into the private GPU surface and capture its contents before placing the completion fence.
Existing snapshots remain readable even when a later source or draw raises.
"""
function record_frame!(t,frame,candidate,retention)
    canvas = checked(S.sk_surface_get_canvas(t.surface),"canvas")
    paint = checked(S.sk_paint_new(),"paint")
    try
        S.sk_canvas_clear(canvas,UInt32(0))
        S.sk_paint_set_antialias(paint,true)
        viewport = V.Transform2D(t.size[1]/frame.size[1],0,0,t.size[2]/frame.size[2],0,0)
        foreach(node -> draw_node(canvas,node,viewport,paint,frame,t,candidate,retention),frame.nodes)
        candidate.snapshot = checked(S.sk_surface_make_image_snapshot(t.surface),"frame snapshot")
        S.gr_direct_context_flush_and_submit(t.engine,false)
        candidate.fence = checked(ccall((:glFenceSync,libGL),Ptr{Cvoid},(Cuint,Cuint),0x9117,0),"draw fence")
        ccall((:glFlush,libGL),Cvoid,())
    finally
        S.sk_paint_delete(paint)
    end
end

"""Release exactly the GPU references exclusive to the retired set of textures."""
function drop_unused!(retired,kept)
    for (key,texture) in retired
        haskey(kept,key) || S.sk_image_unref(texture)
    end
    empty!(retired)
end

"""Release candidate resources with the context bound and put a pending token in its terminal state."""
function discard!(item,state)
    target,candidate = item.target,item.candidate
    drop_unused!(candidate.images,target.images)
    candidate.snapshot == C_NULL || S.sk_image_unref(candidate.snapshot)
    candidate.fence == C_NULL || ccall((:glDeleteSync,libGL),Cvoid,(Ptr{Cvoid},),candidate.fence)
    candidate.snapshot = candidate.fence = C_NULL
    item.state = state
    target.pending = nothing
    return nothing
end

"""Queue one frame on its GLX device. An unsuccessful submission rolls back all candidate allocations."""
function submit_frame!(t,plan)
    return with_context(t) do
        t.pending === nothing || throw(ArgumentError("OpenGL surface has a pending submission"))
        candidate = PendingDraw(TextureCache(),C_NULL,C_NULL,0,0)
        item = V.OpenGLBackend.DesktopSubmission(t,candidate,:recording)
        retention = V.execution_retention(plan)
        t.pending = item
        try
            record_frame!(t,plan.frame,candidate,retention)
            item.state = :pending
            return item
        catch
            discard!(item,:failed)
            rethrow()
        finally
            V.close_retention(retention)
        end
    end
end

"""Observe an actual GL fence, publishing its snapshot and texture cache together on completion."""
function advance!(item,timeout)
    t = item.target
    check_thread(t)
    item.state === :pending || return item.state === :complete
    return with_context(t) do
        t.pending === item || throw(ArgumentError("stale OpenGL submission"))
        candidate = item.candidate
        status = ccall((:glClientWaitSync,libGL),Cuint,(Ptr{Cvoid},Cuint,UInt64),candidate.fence,0,timeout)
        status == 0x911b && return false # GL_TIMEOUT_EXPIRED
        if !(status in (0x911a,0x911c)) # GL_ALREADY_SIGNALED or GL_CONDITION_SATISFIED
            discard!(item,:failed)
            error("OpenGL fence wait failed (status $status)")
        end
        t.images,candidate.images = candidate.images,t.images
        t.snapshot,candidate.snapshot = candidate.snapshot,t.snapshot
        t.frames += 1
        t.committed_upload_bytes += candidate.uploaded_bytes
        discard!(item,:complete)
        return true
    end
end

"""Discard this draw without changing the published frame. Repeated cancellation is harmless."""
function cancel_draw!(item)
    t = item.target
    check_thread(t)
    item.state === :cancelled && return
    with_context(t) do
        item.state === :pending && t.pending === item || throw(ArgumentError("OpenGL submission is $(item.state)"))
        discard!(item,:cancelled)
    end
end

"""Copy the published GPU snapshot into an independently owned top-down RGBA8 image."""
function capture(t)
    return with_context(t) do
        t.snapshot != C_NULL || throw(ArgumentError("OpenGL surface has no completed frame"))
        width,height = t.size
        image = V.Image(width,height)
        info = Ref(S.sk_image_info_t(C_NULL,S.SK_COLOR_TYPE_RGBA_8888,S.SK_ALPHA_TYPE_PREMUL,width,height))
        S.sk_image_read_pixels(t.snapshot,info,image.data,Csize_t(4width),Cint(0),Cint(0),
                               S.SK_IMAGE_CACHING_HINT_DISALLOW) || error("OpenGL snapshot readback failed")
        return image
    end
end

end
