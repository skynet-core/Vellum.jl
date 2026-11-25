using Test, Vellum
include("gdk_window.jl")
include("../tools/report_html.jl")

"""
    capture_compositor(display,xid)

Read Weston's complete test output from its private X server into an owned RGBA image.
"""
function capture_compositor(display,xid)
    img = ccall((:XGetImage,"libX11.so.6"),Ptr{XImageHeader},
        (Ptr{Cvoid},Culong,Cint,Cint,Cuint,Cuint,Culong,Cint),display,xid,0,0,320,200,typemax(Culong),2)
    img != C_NULL || error("could not capture the private compositor output")
    try
        masks = unsafe_load(img).masks
        all(!iszero,masks) || error("the virtual output must have a true-color visual")
        shifts = trailing_zeros.(masks)
        image = Image(320,200)
        for y in 0:199, x in 0:319
            pixel = ccall((:XGetPixel,"libX11.so.6"),Culong,(Ptr{XImageHeader},Cint,Cint),img,x,y)
            channels = map(masks,shifts) do mask,shift
                round(Int,255*((pixel & mask) >> shift)/(mask >> shift))
            end
            image[y+1,x+1] = rgbx(channels...,255)
        end
        return image
    finally
        ccall((:XDestroyImage,"libX11.so.6"),Cint,(Ptr{XImageHeader},),img)
    end
end

"""
    window_reference(frame)

Render the 160 × 80 fixture on CPU and fit it at 2× in the center of the 320 × 200 output.
"""
function window_reference(frame)
    pixels = rasterize(frame)
    expected = Image(320,200)
    for y in 0:199, x in 0:319
        expected[y+1,x+1] = 20 <= y < 180 ? pixels[(y-20)÷2+1,x÷2+1] : rgbx(0,0,0,255)
    end
    return expected
end

"""Return the largest channel error across the entire captured physical output."""
window_error(actual,expected) = maximum(abs(Int(a)-Int(b)) for (a,b) in zip(actual.data,expected.data))

"""
    window_report(frames,stats)

Write the independent compositor captures, CPU references, measured channel errors and device identity.
"""
function window_report(frames,stats)
    dir = joinpath(pkgdir(Vellum),"reports","vulkan-windows")
    mkpath(dir)
    open(joinpath(dir,"index.html"),"w") do io
        report_header(io,"Wayland compositor pixels")
        println(io,"<p>",html_escape(stats.renderer)," · Julia ",VERSION," · ",html_escape(profile_revision()),
            " · 320 × 200 output from Weston on a private X server</p>","<table><tr><th>Frame</th><th>CPU reference</th><th>Wayland output</th><th>Maximum channel error (0–255)</th></tr>")
        for (i,row) in pairs(frames)
            for (source,image) in (("cpu",row.expected),("wayland",row.actual))
                savepng(joinpath(dir,"frame-$i-$source.png"),image)
            end
            println(io,"<tr><th>",i,"</th><td><img alt='CPU frame ",i,"' src='frame-",i,"-cpu.png'></td>",
                "<td><img alt='Wayland compositor frame ",i,"' src='frame-",i,"-wayland.png'></td><td>",row.error,"</td></tr>")
        end
        println(io,"</table><p>Both captures include the black letterbox bars. Cancelling the second frame was checked before its successful resubmission.</p></html>")
    end
    open(joinpath(dir,"measurements.tsv"),"w") do io
        println(io,"frame\tpixels\tmax_channel_error\tgpu_transfer_ns\trenderer\trevision")
        for (i,row) in pairs(frames)
            println(io,join((i,320*200,row.error,something(row.gpu_ns,"unavailable"),stats.renderer,profile_revision()),'\t'))
        end
    end
end

"""
    check_compositor_pixels(private_display)

Verify the compositor's output after an edit and a cancelled candidate on a real Wayland swapchain.
"""
function check_compositor_pixels(private_display)
    host = Vellum.GLHost
    display = ccall((:XOpenDisplay,"libX11.so.6"),Ptr{Cvoid},(Cstring,),private_display)
    display != C_NULL || error("the test X display is unavailable")
    try
        xid = ccall((:XDefaultRootWindow,"libX11.so.6"),Culong,(Ptr{Cvoid},),display)
        frames = map((Solid(0.8,0.2,0.4),Solid(0.1,0.8,0.6))) do fill
            drawing(size=(160,80)) do e
                rectangle!(e,0,0,160,80;fill)
                rectangle!(e,0,0,45,34;fill=Solid(1,1,0))
            end
        end
        b = Vellum.VulkanBackend.QueueBackend()
        host.with_window(320,200,"Vellum isolated output";platform=:wayland,client_api=:none,libdecor=false,decorated=false) do window
            @test host.backend(window) === :wayland
            s = Vellum.VulkanBackend.window_surface(first(frames),b,window)
            try
                captures = NamedTuple[]
                for (i,frame) in pairs(frames)
                    if i == 2
                        abandoned = submit!(b,s,frame)
                        cancel!(abandoned)
                        @test present!(s,(320,200)) === :unchanged
                        @test window_error(capture_compositor(display,xid),first(captures).expected) <= 1
                        wait(submit!(b,s,frame))
                    end
                    @test timedwait(5;pollint=0.02) do
                        host.poll_events(window)
                        present!(s,(320,200)) === :accepted
                    end === :ok
                    expected = window_reference(frame)
                    actual = capture_compositor(display,xid)
                    @test timedwait(5;pollint=0.02) do
                        host.poll_events(window)
                        actual = capture_compositor(display,xid)
                        window_error(actual,expected) <= 1
                    end === :ok
                    push!(captures,(;expected,actual,error=window_error(actual,expected),Vellum.VulkanBackend.window_statistics(s).gpu_ns))
                end
                @test Vellum.VulkanBackend.window_statistics(s).accepted == 2
                window_report(captures,Vellum.VulkanBackend.statistics(s))
                println("Compared both 320 × 200 Wayland compositor outputs with CPU pixels on ",Vellum.VulkanBackend.statistics(s).renderer)
            finally
                close(s)
            end
        end
    finally
        ccall((:XCloseDisplay,"libX11.so.6"),Cint,(Ptr{Cvoid},),display)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    @testset "Wayland compositor pixels" check_compositor_pixels(only(ARGS))
end
