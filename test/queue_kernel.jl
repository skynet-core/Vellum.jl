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
    packet = Packed.pack_frame(frame,size)
    texels = UInt32[]
    base = UInt32[]
    for source in packet.assets.dense
        push!(base,length(texels))
        isnothing(source) || append!(texels,reinterpret(UInt32,codeunits(source.pixels.bytes)))
    end
    data = (;packet.words,texels,base)
    return UInt32[draw_pixel(data,PointI(x,y)) for x in 0:size[1]-1,y in 0:size[2]-1]
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
