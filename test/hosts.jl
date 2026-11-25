"""Exercise the first-party offscreen path through explicit and default backend selection."""
function test_desktop_opengl()
    backend = Vellum.OpenGLBackend.DesktopBackend()
    @test_throws ArgumentError Vellum.OpenGLBackend.DesktopBackend(device=(true,1))
    @test :clip in capabilities(backend).features
    get(ENV,"VELLUM_TEST_OPENGL","") == "required" || return
    frame = drawing(size=(32,24)) do edit
        rectangle!(edit,0,0,32,24;fill=Solid(0,0,1))
        with_group(edit;opacity=0.5) do child
            clip(child,rectangle_path(2,2,12,8))
            rectangle!(child,0,0,12,12;fill=Solid(1,0,0))
            rectangle!(child,6,0,20,12;fill=Solid(1,0,0))
        end
    end
    withenv("VELLUM_OPENGL_LIBRARY"=>nothing) do
        for scale in (1,2)
            extent = (32scale,24scale)
            reference = rasterize(frame;size=extent)
            gpu = rasterize(frame;target=:opengl,size=extent)
            @test size(gpu) == size(reference)
            @test maximum(abs.(Int.(gpu.data) .- Int.(reference.data))) <= 1
        end
    end
    surface = render(frame;backend)
    try
        stats = Vellum.OpenGLBackend.statistics(surface)
        @test stats.frames == 1 && !isempty(stats.vendor) && !isempty(stats.renderer)
        @test readback(surface)[24,1] == rgbx(0,0,255,255)
        fill!(readback(surface),rgba(0,0,0,0))
        @test readback(surface)[24,1] == rgbx(0,0,255,255)
        emptyframe = snapshot(Canvas(size=(32,24)))
        plan = prepare(backend,emptyframe)
        try
            execute!(backend,surface,plan)
            @test all(iszero,readback(surface).data)
            @test Vellum.OpenGLBackend.statistics(surface).frames == 2
        finally
            close(plan)
        end
    finally
        close(surface)
    end
    @test_throws ArgumentError readback(surface)
    close(surface)
end

"""Check graphics device selection, native rendering and window ownership."""
function test_hosts()
    @testset "Retained native revisions" begin
        test_retained_backends()
    end
    @testset "First-party desktop OpenGL" begin
        test_desktop_opengl()
    end
    @testset "Graphics device selection" begin
        mktempdir() do dir
            sysfs,devdir = joinpath(dir,"sys"),joinpath(dir,"dev")
            mkpath(devdir)
            @test_throws ArgumentError Vellum._drawing_device(:auto;sysfs,devdir)
            function node(n,vendor,product)
                path = joinpath(sysfs,n,"device")
                mkpath(path)
                write(joinpath(devdir,n),"")
                write(joinpath(path,"vendor"),vendor)
                write(joinpath(path,"device"),product)
            end
            node("renderD128","0x1002","0x1234")
            node("renderD129","0x10de","0x4321")
            node("renderD130","broken","0x5555")
            @test Vellum._drawing_device(:amd;sysfs,devdir) == (0x1002,0x1234)
            @test Vellum._drawing_device(:nvidia;sysfs,devdir) == (0x10de,0x4321)
            @test_throws ArgumentError Vellum._drawing_device(:intel;sysfs,devdir)
            @test_throws ArgumentError Vellum._drawing_device(:auto;sysfs,devdir)
            for option in (true,(true,1),(0,1),:unknown)
                @test_throws ArgumentError Vellum._drawing_device(option;sysfs,devdir)
            end
        end
        frame = snapshot(Canvas(size=(4,4)))
        @test_throws ArgumentError rasterize(frame;target=:cpu,device=:auto)
        @test_throws ArgumentError rasterize(frame;target=:webgl2)
        @test_throws ArgumentError rasterize(frame;backend=:none)
        @test_throws ArgumentError rasterize(frame;backend=:none,device=:auto)
        @test_throws ArgumentError Vellum._drawing_native_backend(:opengl,(1,2);linux=false)
        if Sys.islinux()
            for api in (:opengl,:vulkan)
                var = "VELLUM_$(uppercase(String(api)))_LIBRARY"
                withenv(var=>joinpath(tempdir(),"vellum-missing-bridge.so")) do
                    @test_throws ArgumentError rasterize(frame;target=api,device=(1,2))
                end
            end
        end
    end
    @testset "GLFW window lifetime" begin
        host = Vellum.GLHost
        @test_throws ArgumentError host.open_window(0,1,"test")
        @test_throws ArgumentError host.open_window(1,1,"test";client_api=:unknown)
        @test_throws ArgumentError host.open_window(1,1,"test";platform=:unknown)
        if get(ENV,"VELLUM_TEST_GLFW","") == "true"
            platform = Sys.islinux() ? :x11 : nothing
            win = host.with_window(32,24,"Vellum test";platform,visible=false) do window
                @test host.glfw_version(window) >= (3,3,0)
                @test host.window_size(window) == (32,24)
                @test all(>(0),host.framebuffer_size(window))
                @test all(isfinite,host.cursor_position(window))
                @test host.key_state(window,65) == 0 && host.mouse_button_state(window,0) == 0
                @test host.proc_address(window,"glGetString") != C_NULL
                @test_throws ArgumentError host.proc_address(window,"invalid\0name")
                if platform !== nothing
                    @test host.backend(window) == platform
                end
                host.swap_interval!(window,0)
                host.poll_events(window)
                host.swap_buffers(window)
                @test !host.should_close(window)
                host.request_close!(window)
                @test host.should_close(window)
                window
            end
            @test_throws ArgumentError host.window_size(win)
            host.close!(win)
        end
    end
end

include("fixtures/retained_panel.jl")

"""Require actual native renderers and compare retained revision pixels on the same owned surface."""
function test_retained_backends()
    frames = retained_panel()
    @test frames[1].nodes[2] === frames[3].nodes[2]
    @test frames[1].nodes[3].id == frames[2].nodes[3].id
    @test frames[1].nodes[3].revision < frames[2].nodes[3].revision
    @test_throws ArgumentError Vellum.VulkanBackend.DesktopBackend(device=:nvidia)
    for (flag,provider) in (("VULKAN",Vellum.VulkanBackend),("OPENGL",Vellum.OpenGLBackend))
        get(ENV,"VELLUM_TEST_"*flag,"") == "required" || continue
        backend = provider.DesktopBackend()
        surface = make_surface(backend,first(frames).size)
        try
            for (index,frame) in pairs(frames)
                plan = prepare(backend,frame)
                try
                    execute!(backend,surface,plan)
                finally
                    close(plan)
                end
                actual = readback(surface)
                if index == 1
                    @test actual[16,12].r > 200 && actual[16,116].g > 200
                else
                    @test actual[16,12] == (index==2 ? rgbx(0,0,255,255) : rgbx(30,36,56,255))
                end
                @test actual[90,170] == rgbx(30,36,56,255)
                @test count(>(200),[actual[y,x].r for y in 45:79,x in 16:146]) > 250
                stats = provider.statistics(surface)
                @test stats.frames == index
                if flag=="VULKAN"
                    @test stats.renderer == "GskVulkanRenderer"
                    @test stats.reused == (index==1 ? 0 : 2)
                else
                    @test !isempty(stats.renderer) && !isempty(stats.vendor)
                end
            end
            println(flag," retained revisions: ",provider.statistics(surface))
        finally
            close(surface)
        end
        @test_throws ArgumentError readback(surface)
    end
end
