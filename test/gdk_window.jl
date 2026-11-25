using Test, Vellum

"""GTK symbols used by the independent test window host."""
const TEST_GTK = Vellum.VulkanBackend.GTK
"""Wayland ABI used by the GTK test host to observe compositor frame callbacks."""
const TEST_WAYLAND = "libwayland-client.so.0"

"""Supply the host's requested window dimensions to GDK's compute-size signal."""
function test_toplevel_size(::Ptr{Cvoid},size::Ptr{Cvoid},dimensions::Ptr{Cint})::Cvoid
    ccall((:gdk_toplevel_size_set_min_size,TEST_GTK),Cvoid,(Ptr{Cvoid},Cint,Cint),
          size,unsafe_load(dimensions,1),unsafe_load(dimensions,2))
    ccall((:gdk_toplevel_size_set_size,TEST_GTK),Cvoid,(Ptr{Cvoid},Cint,Cint),
          size,unsafe_load(dimensions,1),unsafe_load(dimensions,2))
    return nothing
end

"""Check that attaching and closing Vellum preserves a caller-owned GDK GL context and its bound texture."""
function check_borrowed_gl_context(display,window)
    current() = ccall((:gdk_gl_context_get_current,TEST_GTK),Ptr{Cvoid},())
    prior = current()
    context = ccall((:gdk_display_create_gl_context,TEST_GTK),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid}),display,C_NULL)
    context != C_NULL || error("could not create the host GL context")
    texture = Ref{Cuint}(0)
    try
        ccall((:gdk_gl_context_realize,TEST_GTK),Cint,(Ptr{Cvoid},Ptr{Cvoid}),context,C_NULL) != 0 ||
            error("could not realize the host GL context")
        ccall((:gdk_gl_context_make_current,TEST_GTK),Cvoid,(Ptr{Cvoid},),context)
        ccall((:glGenTextures,"libGL.so.1"),Cvoid,(Cint,Ref{Cuint}),1,texture)
        ccall((:glBindTexture,"libGL.so.1"),Cvoid,(Cuint,Cuint),0x0de1,texture[])
        p = GdkPresenter(window;target=:opengl)
        try
            @test current() == context
        finally
            close(p)
        end
        @test current() == context
        binding = Ref{Cint}()
        ccall((:glGetIntegerv,"libGL.so.1"),Cvoid,(Cuint,Ref{Cint}),0x8069,binding)
        @test binding[] == texture[] != 0
    finally
        if texture[] != 0
            ccall((:gdk_gl_context_make_current,TEST_GTK),Cvoid,(Ptr{Cvoid},),context)
            ccall((:glDeleteTextures,"libGL.so.1"),Cvoid,(Cint,Ref{Cuint}),1,texture)
        end
        if prior == C_NULL
            ccall((:gdk_gl_context_clear_current,TEST_GTK),Cvoid,())
        else
            ccall((:gdk_gl_context_make_current,TEST_GTK),Cvoid,(Ptr{Cvoid},),prior)
        end
        ccall((:g_object_unref,TEST_GTK),Cvoid,(Ptr{Cvoid},),context)
    end
end

"""Mark receipt of the compositor's wl_surface.frame event."""
function test_wayland_frame_done(received::Ptr{Cint},::Ptr{Cvoid},::UInt32)::Cvoid
    unsafe_store!(received,1)
    return nothing
end

"""Request independent compositor feedback for the next commit to the test's own window."""
function check_wayland_commit(redraw,window)
    surface = ccall((:gdk_wayland_surface_get_wl_surface,TEST_GTK),Ptr{Cvoid},(Ptr{Cvoid},),window)
    iface = cglobal((:wl_callback_interface,TEST_WAYLAND))
    version = ccall((:wl_proxy_get_version,TEST_WAYLAND),UInt32,(Ptr{Cvoid},),surface)
    callback = ccall((:wl_proxy_marshal_array_flags,TEST_WAYLAND),Ptr{Cvoid},
                     (Ptr{Cvoid},UInt32,Ptr{Cvoid},UInt32,UInt32,Ref{UInt}),surface,3,iface,version,0,Ref(UInt(0)))
    callback != C_NULL || error("could not request Wayland frame feedback")
    listener = Ref(@cfunction(test_wayland_frame_done,Cvoid,(Ptr{Cint},Ptr{Cvoid},UInt32)))
    received = Ref{Cint}(0)
    GC.@preserve listener received try
        result = ccall((:wl_proxy_add_listener,TEST_WAYLAND),Cint,
                       (Ptr{Cvoid},Ref{Ptr{Cvoid}},Ref{Cint}),callback,listener,received)
        iszero(result) || error("could not observe Wayland frame feedback")
        redraw()
        @test wait_gdk(() -> received[] == 1)
    finally
        ccall((:wl_proxy_destroy,TEST_WAYLAND),Cvoid,(Ptr{Cvoid},),callback)
    end
end

"""Dispatch the host event queue until the compositor applies a request or the test times out."""
function wait_gdk(f)
    return timedwait(5;pollint=0.02) do
        ccall((:g_main_context_iteration,TEST_GTK),Cint,(Ptr{Cvoid},Cint),C_NULL,0)
        f()
    end == :ok
end

"""Xlib XImage fields through the color masks, used to decode the window visual in a test."""
struct XImageHeader
    geometry::NTuple{4,Cint}
    data::Ptr{Cvoid}
    format::NTuple{7,Cint}
    masks::NTuple{3,Culong}
end

"""Read one pixel from the mapped X11 window, independently of the Vellum and GSK renderers."""
function x11_window_rgb(display,window,x,y)
    xdpy = ccall((:gdk_x11_display_get_xdisplay,TEST_GTK),Ptr{Cvoid},(Ptr{Cvoid},),display)
    xid = ccall((:gdk_x11_surface_get_xid,TEST_GTK),Culong,(Ptr{Cvoid},),window)
    scale = ccall((:gdk_surface_get_scale,TEST_GTK),Cdouble,(Ptr{Cvoid},),window)
    img = ccall((:XGetImage,"libX11.so.6"),Ptr{XImageHeader},(Ptr{Cvoid},Culong,Cint,Cint,Cuint,Cuint,Culong,Cint),
                xdpy,xid,floor(Int,x*scale),floor(Int,y*scale),1,1,typemax(Culong),2)
    img != C_NULL || error("XGetImage failed")
    try
        pixel = ccall((:XGetPixel,"libX11.so.6"),Culong,(Ptr{XImageHeader},Cint,Cint),img,0,0)
        return map(unsafe_load(img).masks) do mask
            mask != 0 || error("X11 test window requires a true-color visual")
            shift = trailing_zeros(mask)
            round(Int,255*((pixel & mask) >> shift)/(mask >> shift))
        end
    finally
        ccall((:XDestroyImage,"libX11.so.6"),Cint,(Ptr{XImageHeader},),img)
    end
end

"""Present two tiled revisions at the current window size and check the transfer delta and visible output."""
function check_window_images(p,registry,display,window,display_type)
    tiles = Vellum.ImageTiles
    page(color) = tiles.RgbaTile(64,1,repeat(UInt8[color...],64))
    left = page((255,0,0,255))
    for (i,color) in enumerate(((0,0,255,255),(0,255,0,255)))
        source = tiles.OwnedTileRevision(128,1,[((0,0),left),((1,0),page(color))];tile_size=64,share_pages=true)
        ref,pin = tiles.publish_revision!(registry,source)
        frame = drawing(size=(128,1)) do e
            draw_image!(e,resource!(e,:image,ref),(0,0,128,1))
        end
        before = presentation_statistics(p)
        try
            queue() = (@test present!(p,frame) === :queued)
            display_type == "GdkWaylandDisplay" ? check_wayland_commit(queue,window) : queue()
            @test wait_gdk(() -> presentation_statistics(p).frames > before.frames)
            after = presentation_statistics(p)
            @test after.resident_images == 2
            @test after.uploaded_bytes-before.uploaded_bytes == (i==1 ? 2 : 1)*64*4
            if display_type == "GdkX11Display"
                @test wait_gdk(() -> x11_window_rgb(display,window,220,60)==color[1:3])
                @test x11_window_rgb(display,window,50,60)==(255,0,0)
            end
        finally
            close(pin)
        end
    end
end

"""Exercise the public presenters on one caller-owned GDK toplevel, including resize and reattachment."""
function test_gdk_window()
    @test_throws ArgumentError GdkPresenter(C_NULL;target=:vulkan)
    @test_throws ArgumentError GdkPresenter(Ptr{Cvoid}(1);target=:cpu)
    targets = [t for t in (:opengl,:vulkan) if get(ENV,"VELLUM_TEST_"*uppercase(String(t)),"") == "required"]
    Sys.islinux() && !isempty(targets) || return
    ccall((:gtk_init_check,TEST_GTK),Cint,()) != 0 || error("GDK test requires a desktop display")
    display = ccall((:gdk_display_get_default,TEST_GTK),Ptr{Cvoid},())
    display_type = unsafe_string(ccall((:g_type_name_from_instance,TEST_GTK),Cstring,(Ptr{Cvoid},),display))
    host = get(ENV,"GDK_BACKEND","")
    host in ("x11","wayland") && @test display_type == (host=="x11" ? "GdkX11Display" : "GdkWaylandDisplay")
    window = ccall((:gdk_surface_new_toplevel,TEST_GTK),Ptr{Cvoid},(Ptr{Cvoid},),display)
    window != C_NULL || error("could not create test toplevel")
    layout = ccall((:gdk_toplevel_layout_new,TEST_GTK),Ptr{Cvoid},())
    frames = retained_panel()
    registry = Vellum.ImageTiles.RasterRegistry(namespace=32,source_bytes=65536,max_assets=8,max_revisions=8,max_leases=32)
    dims = Cint[180,100]
    GC.@preserve dims try
        callback = @cfunction(test_toplevel_size,Cvoid,(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cint}))
        ccall((:g_signal_connect_data,TEST_GTK),Culong,(Ptr{Cvoid},Cstring,Ptr{Cvoid},Ptr{Cint},Ptr{Cvoid},Cint),
              window,"compute-size",callback,dims,C_NULL,0)
        function resize_window(w,h)
            dims .= (w,h)
            ccall((:gdk_toplevel_present,TEST_GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),window,layout)
            ccall((:gdk_surface_request_layout,TEST_GTK),Cvoid,(Ptr{Cvoid},),window)
            @test wait_gdk() do
                ccall((:gdk_surface_get_mapped,TEST_GTK),Cint,(Ptr{Cvoid},),window) != 0 &&
                ccall((:gdk_surface_get_width,TEST_GTK),Cint,(Ptr{Cvoid},),window) == w &&
                ccall((:gdk_surface_get_height,TEST_GTK),Cint,(Ptr{Cvoid},),window) == h
            end
        end
        for target in targets
            offscreen = rasterize(frames[2];target)
            @test offscreen[13,11] == rasterize(frames[2])[13,11] == rgbx(0,0,255,255)
            p = GdkPresenter(window;target,raster_registry=registry)
            try
                @test_throws ArgumentError GdkPresenter(window;target)
                @test present!(p,first(frames)) === :suspended
                resize_window(180,100)
                for (i,frame) in pairs(frames)
                    @test present!(p,frame) === (i==1 ? :unchanged : :queued)
                    @test wait_gdk(() -> presentation_statistics(p).revision == frame.revision)
                    stats = presentation_statistics(p)
                    @test stats.frames >= i
                    i>1 && @test stats.reused >= 2
                    @test stats.size == (180,100)
                    @test stats.renderer in (target===:vulkan ? ("GskVulkanRenderer",) : ("GskGLRenderer","GskNglRenderer"))
                    if display_type == "GdkX11Display"
                        pixel = rasterize(frame)[13,11]
                        expected = Int.((pixel.r,pixel.g,pixel.b))
                        @test wait_gdk() do
                            actual = x11_window_rgb(display,window,10,12)
                            maximum(abs.(actual .- expected)) <= 2
                        end
                    end
                end
                unsupported = drawing(e -> clear_region!(e,(1,1,2,2));size=(180,100))
                @test_throws CapabilityError present!(p,unsupported)
                @test present!(p,frames[3]) === :unchanged
                function redraw()
                    before = presentation_statistics(p).frames
                    @test present!(p,frames[1]) === :queued
                    @test present!(p,frames[2]) === :queued
                    @test presentation_statistics(p).frames == before
                    resize_window(360,200)
                end
                display_type == "GdkWaylandDisplay" ? check_wayland_commit(redraw,window) : redraw()
                @test wait_gdk() do
                    stats = presentation_statistics(p)
                    stats.revision == frames[2].revision && stats.size == (360,200)
                end
                @test present!(p,frames[2]) === :unchanged
                if display_type == "GdkX11Display"
                    @test wait_gdk(() -> x11_window_rgb(display,window,240,35)==(0,0,255))
                end
                println(display_type," window resize and retained edits: ",presentation_statistics(p))
                check_window_images(p,registry,display,window,display_type)
            finally
                close(p)
            end
            @test_throws ArgumentError present!(p,first(frames))
            @test ccall((:gdk_surface_is_destroyed,TEST_GTK),Cint,(Ptr{Cvoid},),window) == 0
            close(p)
            ccall((:gdk_surface_hide,TEST_GTK),Cvoid,(Ptr{Cvoid},),window)
        end
        :opengl in targets && check_borrowed_gl_context(display,window)
    finally
        close(registry)
        ccall((:gdk_toplevel_layout_unref,TEST_GTK),Cvoid,(Ptr{Cvoid},),layout)
        ccall((:gdk_surface_destroy,TEST_GTK),Cvoid,(Ptr{Cvoid},),window)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    include("fixtures/retained_panel.jl")
    @testset "Caller-owned GDK window" test_gdk_window()
end
