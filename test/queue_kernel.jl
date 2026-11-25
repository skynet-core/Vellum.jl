"""Exercise the Julia shader implementation without loading Vulkan or opening a device."""
module QueueKernelTests
using Vellum, Test
using Vellum.VulkanBackend.QueueKernel: draw_pixel, PointI
import Vellum.OpenGLBackend as Packed


"""
    render_kernel(frame,size)

Construct a compact packet with physical dense-source offsets and run the authored Julia draw kernel.
"""
function render_kernel(frame,size)
    packet = Packed.pack_frame(frame,size;limits=Packed.FrameCurves.QUEUE_LIMITS,blur_radius=Packed.BoxBlurPlan.MAX_RADIUS)
    texels = UInt32[]
    base = UInt32[]
    for source in packet.assets.dense
        push!(base,length(texels))
        isnothing(source) || append!(texels,reinterpret(UInt32,codeunits(source.pixels.bytes)))
    end
    passes,bytes = Vellum.VulkanBackend.queue_dispatches(packet.words,size)
    data = (;packet.words,texels,base,pixels=zeros(UInt32,bytes÷4))
    for pass in passes, y in 0:Int(pass.height)-1, x in 0:Int(pass.width)-1
        if pass.mode == 0
            data.pixels[y*size[1]+x+1] = draw_pixel(data,PointI(x,y))
        else
            Vellum.VulkanBackend.QueueKernel.execute_pass!(data,pass,PointI(x,y))
        end
    end
    return reshape(data.pixels[1:prod(size)],size)
end

"""
    compare(frame)

Check the CPU-executable shader against Vellum's independent renderer at two physical scales.
"""
function compare(frame)
    for size in (Int.(frame.size),2 .* Int.(frame.size))
        actual = render_kernel(frame,size)
        expected = rasterize(frame;size)
        difference = abs.(Int.(reinterpret(UInt8,vec(actual))) .- Int.(expected.data))
        @test maximum(difference)<=1
    end
end
end

"""Exercise nested and sibling box filters, off-target source geometry and translucent group composition."""
function queue_filtered_frame()
    drawing(size=(28,20)) do e
        rectangle!(e,0,0,28,20;fill=Solid(0.6,0.8,0.3,0.75))
        with_group(e;opacity=0.75,blend=:multiply) do outer
            rectangle!(outer,3,4,12,10;fill=Solid(0.9,0.4,0.1))
            with_group(outer;effect=BoxBlur(1.5,2.5),opacity=0.8) do inner
                rectangle!(inner,-3,4,7,8;fill=Solid(0.8,0.3,0.5))
                with_group(inner;effect=BoxBlur(0,2)) do filtered
                    rectangle!(filtered,8,2,10,5;fill=Solid(0.2,0.3,1))
                end
            end
            rectangle!(outer,12,9,8,3;fill=Solid(0.1,1,0.4,0.5))
        end
        with_group(e;effect=BoxBlur(2,0)) do sibling
            rectangle!(sibling,21,10,4,6;fill=Solid(1,0.2,0.1))
        end
        rectangle!(e,23,11,2,3;fill=Solid(0.1,0.2,0.3))
    end
end

"""Check eight isolated levels and a command stream larger than the legacy bridge ABI."""
function queue_deep_frame(levels)
    function layer(e,remaining)
        if remaining == 0
            for i in 1:80
                rectangle!(e,mod(i,8),i÷8,1,1;fill=Solid(0.2,0.6,0.8))
            end
        else
            with_group(e;opacity=0.95) do child
                layer(child,remaining-1)
            end
        end
    end
    return drawing(e -> layer(e,levels);size=(12,12))
end

"""
    queue_paints_frame()

Exercise even-odd fill, gradient stops, stroke joins, clipped clear and multiply in one scene.
"""
function queue_paints_frame()
    gradient = LinearGradient((0,0),(32,0),(GradientStop(0,Color(0.8,0.2,0.1)),
        GradientStop(0.5,Color(0.4,0.8,0.2,0.75)),GradientStop(1,Color(0.2,0.3,0.9))))
    ring = PathData(((:move,2,2),(:line,30,2),(:line,30,22),(:line,2,22),(:close,),
        (:move,9,6),(:line,24,6),(:line,24,16),(:line,9,16),(:close,)))
    return drawing(size=(32,24)) do e
        rectangle!(e,0,0,32,24;fill=Solid(0.9,0.7,0.5))
        with_group(e;opacity=0.75,blend=:multiply) do child
            configure!(child;fill=gradient)
            draw(child,ring;winding=:evenodd)
            configure!(child;stroke=Solid(1,0.4,0.8),stroke_style=StrokeStyle(width=1.75,join=:round))
            draw(child,PathData(((:move,3,21),(:line,15,3),(:quad,19,8,29,20)));mode=:stroke)
        end
        clip(e,rectangle_path(12,9,3.5,4))
        clear_region!(e,(10,8,8,8))
    end
end

"""
    test_queue_window_geometry()

Check the packed-to-window aspect fit, native handles and legal Wayland scale
values before any Vulkan loader or display is opened.
"""
function test_queue_window_geometry()
    vk = Vellum.VulkanBackend
    @test vk.fitted_rect((320,200),(640,480)) == (x=0,y=40,width=640,height=400)
    @test vk.fitted_rect((200,320),(480,640)) == (x=40,y=0,width=400,height=640)
    @test vk.fitted_rect((1,1000),(3,2)) == (x=1,y=0,width=1,height=2)
    @test vk.fitted_rect((1000,1),(2,3)) == (x=0,y=1,width=2,height=1)
    @test vk.window_buffer_scale(nothing,(21,13)) === nothing
    @test vk.window_buffer_scale(Int32(2),(20,12)) === 2
    for scale in (0,2.5,-1,true,UInt64(typemax(Cint))+1)
        @test_throws ArgumentError vk.window_buffer_scale(scale,(20,12))
    end
    @test_throws ArgumentError vk.window_buffer_scale(2,(21,12))
    @test_throws ArgumentError vk.X11Window(C_NULL,2)
    @test_throws ArgumentError vk.X11Window(Ptr{Cvoid}(1),true)
    @test vk.X11Window(Ptr{Cvoid}(1),0xff).xid == 255
end

"""Verify slot placement, the byte ceiling and reuse of dense capacity independently of a Vulkan driver."""
function test_queue_atlas()
    vk = Vellum.VulkanBackend
    layout = vk.QueueAtlas(2,[20,5,0])
    @test vk.atlas_offset(layout,3,0) == 0
    @test vk.atlas_offset(layout,4,1) == 3*64^2
    @test vk.atlas_offset(layout,0,1) == 4*64^2+20
    @test vk.atlas_offset(layout,1,0) == 4*64^2+40
    @test vk.atlas_for_sources(layout,[nothing,(width=1,height=4),nothing]) === layout
    full = vk.QueueAtlas(0,[4096^2,0])
    compact = vk.atlas_for_sources(full,[nothing,(width=4096,height=4096)])
    @test compact.capacities == [0,4096^2]
    @test_throws ArgumentError vk.atlas_for_sources(full,fill((width=4096,height=4096),2))
end
