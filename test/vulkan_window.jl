using Test, Vellum

"""
    check_queue_window(display,window,display_type,resize)

Pass a host-owned native window to Vellum and check raw Vulkan presentation, fitted pixels and recovery.
"""
function check_queue_window(display,window,display_type,resize)
    vk = Vellum.VulkanBackend
    @test_throws ArgumentError vk.X11Window(C_NULL,1)
    @test_throws ArgumentError vk.X11Window(Ptr{Cvoid}(1),0)
    wayland = display_type == "GdkWaylandDisplay"
    host = if wayland
        d = ccall((:gdk_wayland_display_get_wl_display,TEST_GTK),Ptr{Cvoid},(Ptr{Cvoid},),display)
        w = ccall((:gdk_wayland_surface_get_wl_surface,TEST_GTK),Ptr{Cvoid},(Ptr{Cvoid},),window)
        vk.WaylandWindow(d,w)
    else
        d = ccall((:gdk_x11_display_get_xdisplay,TEST_GTK),Ptr{Cvoid},(Ptr{Cvoid},),display)
        w = ccall((:gdk_x11_surface_get_xid,TEST_GTK),Culong,(Ptr{Cvoid},),window)
        vk.X11Window(d,w)
    end
    function test_frame(color)
        drawing(size=(100,50)) do edit
            rectangle!(edit,0,0,100,50;fill=color)
            rectangle!(edit,0,0,50,25;fill=Solid(0.2,0.4,0.8))
        end
    end
    backend = vk.QueueBackend()
    first,second = test_frame(Solid(1,0,0)),test_frame(Solid(0,0.75,0.25))
    scale = ccall((:gdk_surface_get_scale,TEST_GTK),Cdouble,(Ptr{Cvoid},),window)
    # This host uses the integer Wayland buffer-scale contract, including on fractional displays.
    scale_hint = wayland ? ceil(Int,scale) : nothing
    function framebuffer(w,h)
        backing = something(scale_hint,scale)
        return round.(Int,(w*backing,h*backing))
    end
    present(s,dims) = present!(s,dims;buffer_scale=scale_hint)
    function offer(s,dims)
        @test wait_gdk() do
            result = present(s,dims)
            result in (:accepted,:busy,:resize) || error("unexpected presentation outcome $result")
            return result === :accepted
        end
    end
    resize(180,100)
    s = vk.window_surface(first,backend,host)
    try
        @test_throws ArgumentError vk.window_surface(first,backend,host)
        @test present!(s,(0,0)) === :suspended
        @test_throws ArgumentError present!(s,(-1,1))
        @test_throws ArgumentError present!(s,(180,100);buffer_scale=0)
        @test_throws ArgumentError present!(s,(181,100);buffer_scale=2)
        wayland || @test_throws ArgumentError present!(s,(180,100);buffer_scale=1)
        @test vk.window_statistics(s).swapchains == 0
        dims = framebuffer(180,100)
        draw = () -> offer(s,dims)
        wayland ? check_wayland_commit(draw,window) : draw()
        stats = vk.window_statistics(s)
        @test stats.accepted == 1 && stats.revision == first.revision && stats.swapchains == 1
        @test stats.images >= 2 && stats.transfer_bytes > 0 && stats.queue_present_ns > 0
        @test (stats.width,stats.height) == dims
        @test isnothing(stats.gpu_ns) ? iszero(vk.statistics(s).timestamp_valid_bits) : stats.gpu_ns > 0
        @test present(s,dims) === :unchanged
        if !wayland
            @test wait_gdk(() -> x11_window_rgb(display,window,18,16) == (51,102,204))
            @test x11_window_rgb(display,window,5,2) == (0,0,0)
            @test x11_window_rgb(display,window,155,68) == (255,0,0)
        end
        token = submit!(backend,s,second)
        dims = framebuffer(200,130)
        function offer_resize()
            @test present(s,dims) === :busy
            @test vk.window_statistics(s) == stats
            wait(token)
            redraw = () -> offer(s,dims)
            wayland ? check_wayland_commit(redraw,window) : redraw()
        end
        # Wayland can acknowledge a new window size after the first new-size buffer commits.
        resize(200,130;offer=offer_resize)
        after = vk.window_statistics(s)
        @test (after.width,after.height) == dims
        @test after.swapchains == 2 && after.accepted == 2 && after.transfer_bytes > stats.transfer_bytes
        @test present(s,dims) === :unchanged
        if !wayland
            @test wait_gdk(() -> x11_window_rgb(display,window,165,94) == (0,191,64))
            @test x11_window_rgb(display,window,12,4) == (0,0,0)
        end
        @test readback(s).data == rasterize(second).data
        @test present!(s,(0,0)) === :suspended
        offer(s,dims)
        @test vk.window_statistics(s).swapchains == 3
        pending = submit!(backend,s,first)
        close(s)
        @test !completed(pending)
        @test_throws ArgumentError present!(s,dims)
        println(display_type," raw Vulkan WSI: ",after)
    finally
        close(s)
    end
    replacement = vk.window_surface(first,backend,host)
    try
        offer(replacement,framebuffer(200,130))
    finally
        close(replacement)
    end
    @test ccall((:gdk_surface_is_destroyed,TEST_GTK),Cint,(Ptr{Cvoid},),window) == 0
    ccall((:gdk_surface_hide,TEST_GTK),Cvoid,(Ptr{Cvoid},),window)
end

"""
    check_glfw_window(platform)

Verify the public GLFW overload and frame callback on the selected native window system.
"""
function check_glfw_window(platform)
    gl = Vellum.GLHost
    b = Vellum.VulkanBackend.QueueBackend()
    frame = drawing(e -> rectangle!(e,0,0,50,25;fill=Solid(1,0,0));size=(50,25))
    gl.with_window(160,80,"Vellum window test";platform,client_api=:none,libdecor=platform !== :wayland) do window
        @test gl.backend(window) === platform
        s = Vellum.VulkanBackend.window_surface(frame,b,window)
        try
            @test timedwait(5) do
                gl.poll_events(window)
                present!(s,gl.framebuffer_size(window)) === :accepted
            end === :ok
            @test present!(s,gl.framebuffer_size(window)) === :unchanged
            @test readback(s).data == rasterize(frame).data
            println(platform," GLFW queue present ",Vellum.VulkanBackend.window_statistics(s))
        finally
            close(s)
        end
    end
    gl.with_frame_window(160,80,"Raw Vulkan frame API";platform,target=b) do window,present
        seen = Ref(0)
        present(frame;before_swap=image -> begin
            @test (image.width,image.height) == gl.framebuffer_size(window)
            @test image[2,2] == rgbx(255,0,0,255)
            seen[] += 1
        end)
        @test seen[] == 1
        @test isnothing(present(frame))
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    @testset "Raw GLFW Vulkan" check_glfw_window(Symbol(only(ARGS)))
end
