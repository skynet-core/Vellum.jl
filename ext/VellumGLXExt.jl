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
    valid::Bool
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
    t = Target(size,Threads.threadid(),display,0,C_NULL,C_NULL,C_NULL,C_NULL,"","",0,false)
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
            t.surface = checked(S.sk_surface_new_backend_render_target(t.engine,t.target,
                S.GR_SURFACE_ORIGIN_BOTTOM_LEFT,S.SK_COLOR_TYPE_RGBA_8888,C_NULL,C_NULL),"GL drawing surface")
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
    if t.engine != C_NULL
        with_context(t) do
            t.surface == C_NULL || S.sk_surface_unref(t.surface)
            t.target == C_NULL || S.gr_backendrendertarget_delete(t.target)
            S.gr_direct_context_unref(t.engine)
        end
    end
    t.drawable == 0 || ccall((:glXDestroyPbuffer,libGLX),Cvoid,(Ptr{Cvoid},Culong),t.display,t.drawable)
    t.context == C_NULL || ccall((:glXDestroyContext,libGLX),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),t.display,t.context)
    ccall((:XCloseDisplay,libX11),Cint,(Ptr{Cvoid},),t.display)
    t.display = C_NULL
    t.valid = false
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

"""Draw a cropped premultiplied RGBA image on the current OpenGL canvas."""
function draw_image_node(canvas,node,frame,viewport,paint)
    p = V.OpenGLBackend.image_placement(node,frame,viewport)
    isnothing(p) && return
    if !isnothing(p.mask)
        with_path(path->S.sk_canvas_clip_path_with_operation(canvas,path,S.SK_CLIP_OP_INTERSECT,true),p.mask)
    end
    a,b,c,d,x,y = p.transform.coefficients
    S.sk_canvas_concat(canvas,Ref(S.sk_matrix_t(a,c,x,b,d,y,0,0,1)))
    image = p.image
    info = Ref(S.sk_image_info_t(C_NULL,S.SK_COLOR_TYPE_RGBA_8888,S.SK_ALPHA_TYPE_PREMUL,image.width,image.height))
    data = checked(S.sk_data_new_with_copy(image.data,Csize_t(length(image.data))),"image storage")
    try
        texture = checked(S.sk_image_new_raster_data(info,data,Csize_t(4image.width)),"image")
        try
            S.sk_paint_set_shader(paint,C_NULL)
            S.sk_paint_set_color(paint,argb(V.Color(1,1,1),node.operation.state.opacity))
            filter = node.operation.state.sampling===:nearest ? S.SK_FILTER_MODE_NEAREST : S.SK_FILTER_MODE_LINEAR
            sampling = Ref(S.sk_sampling_options_t(0,false,S.sk_cubic_resampler_t(0,0),filter,S.SK_MIPMAP_MODE_NONE))
            rect = Ref(S.sk_rect_t(0,0,image.width,image.height))
            S.sk_canvas_draw_image_rect(canvas,texture,rect,rect,sampling,paint,S.SRC_RECT_CONSTRAINT_STRICT)
        finally
            S.sk_image_unref(texture)
        end
    finally
        S.sk_data_unref(data)
    end
end

"""Pack straight sRGB and drawing opacity for Skia."""
function argb(color,opacity)
    r,g,b,a = color.channels
    return round(UInt32,255a*opacity)<<24 | round(UInt32,255r)<<16 | round(UInt32,255g)<<8 | round(UInt32,255b)
end

"""Render one prepared semantic operation inside the current Skia canvas state."""
function draw_node(canvas,node,viewport,paint,frame)
    op = node.operation
    level = S.sk_canvas_get_save_count(canvas)
    try
        if op isa V.CompositeGroup
            S.sk_canvas_save_layer_alpha(canvas,C_NULL,round(UInt8,255op.opacity))
            foreach(child -> draw_node(canvas,child,viewport,paint,frame),op.nodes)
            return
        end
        S.sk_canvas_save(canvas)
        state = op.state
        for clip in state.clips
            with_path(V.OpenGLBackend.device_geometry(clip.path,viewport*clip.transform,clip.winding)) do path
                S.sk_canvas_clip_path_with_operation(canvas,path,S.SK_CLIP_OP_INTERSECT,true)
            end
        end
        op isa V.ImageRegion && return draw_image_node(canvas,node,frame,viewport,paint)
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

"""Record a frame into the current OpenGL target and submit its commands. Optionally wait for the device."""
function submit_frame!(t,frame,synchronize)
    canvas = checked(S.sk_surface_get_canvas(t.surface),"canvas")
    paint = checked(S.sk_paint_new(),"paint")
    try
        S.sk_canvas_clear(canvas,UInt32(0))
        S.sk_paint_set_antialias(paint,true)
        viewport = V.Transform2D(t.size[1]/frame.size[1],0,0,t.size[2]/frame.size[2],0,0)
        foreach(node -> draw_node(canvas,node,viewport,paint,frame),frame.nodes)
        S.gr_direct_context_flush_and_submit(t.engine,synchronize)
    finally
        S.sk_paint_delete(paint)
    end
end

"""Draw a complete frame and publish it after its submitted work has finished."""
function draw_frame!(t,frame)
    with_context(t) do
        t.valid = false
        submit_frame!(t,frame,true)
        t.frames += 1
        t.valid = true
    end
end

"""Read RGBA8 pixels once and convert the GL bottom-up rows to Vellum image order."""
function capture(t)
    return with_context(t) do
        t.valid || throw(ArgumentError("OpenGL surface has no completed frame"))
        width,height = t.size
        image = V.Image(width,height)
        ccall((:glBindFramebuffer,libGL),Cvoid,(Cuint,Cuint),0x8ca8,0)
        ccall((:glReadPixels,libGL),Cvoid,(Cint,Cint,Cint,Cint,Cuint,Cuint,Ptr{UInt8}),
              0,0,width,height,0x1908,0x1401,image.data)
        ccall((:glGetError,libGL),Cuint,()) == 0 || error("OpenGL framebuffer readback failed")
        stride = 4width
        row = Vector{UInt8}(undef,stride)
        for y in 0:height÷2-1
            top,bottom = y*stride+1,(height-y-1)*stride+1
            copyto!(row,1,image.data,top,stride)
            copyto!(image.data,top,image.data,bottom,stride)
            copyto!(image.data,bottom,row,1,stride)
        end
        return image
    end
end

end
