"""Batched device workloads that call the same Julia functions as the Vulkan renderer."""
module VulkanMethodWorkloads

using Vellum
import Vellum.VulkanBackend.QueueKernel as Kernel
using Vellum.VulkanBackend.QueueKernel: PointI, PointD, Pixel, at_offset, floor_point, pack_color, unpack_color,
    intword, inside_shape, packet_tables, stop_color, paint_color, image_color, texel_color, composite_pixel, draw_pixel

"""
One output expression per profiled method. Each invocation consumes device input indexed by pixel position.
Conversion and output stores are included in the measured dispatch. The same expression executes in Julia
for comparison, including the buffer-access and normalized-color intrinsics.
"""
const EXPRESSIONS = (
    at_offset = :(UInt32(at_offset(data.words,p.x%9))),
    floor_point = :(UInt32(floor_point(PointD(p.x*0.48,p.y*0.27)).x)),
    unpack_color = :(UInt32(floor(233f0*unpack_color(at_offset(data.texels,Int(at_offset(data.base,0))+(p.x+p.y)%64))[2]))),
    pack_color = :(pack_color(Pixel(Float32(p.x)/128,Float32(p.y)/64,0.125f0,1f0))),
    intword = :(UInt32(intword(data,p.x%9))),
    packet_tables = :(UInt32(packet_tables(data).raster+p.x)),
    inside_shape = :(UInt32(inside_shape(data,packet_tables(data),p.x%2,PointD(p.x+0.125,p.y+0.375)))),
    stop_color = :(pack_color(stop_color(data,packet_tables(data).stop+5*(p.x%2)))),
    paint_color = :(pack_color(paint_color(data,packet_tables(data),10,PointD(p.x+0.125,p.y+0.375)))),
    texel_color = :(pack_color(texel_color(data,packet_tables(data),packet_tables(data).raster,false,PointI(p.x%8,p.y%8)))),
    image_color = :(pack_color(image_color(data,packet_tables(data),24,false,PointD(p.x+0.125,p.y+0.375)))),
    composite_pixel = :(pack_color(composite_pixel(unpack_color(at_offset(data.texels,Int(at_offset(data.base,0))+p.x%64)),
        unpack_color(at_offset(data.texels,Int(at_offset(data.base,0))+p.y%64)),(p.x%2)==0))),
    draw_pixel = :(draw_pixel(data,p)),
)

"""
    reference

Evaluate the named workload as Julia code for an independent host-side comparison.
"""
function reference end
for (name,expr) in pairs(EXPRESSIONS)
    @eval reference(::Val{$(QuoteNode(name))},data,p) = $expr
end

"""
    fixture()

Build one real drawing packet with a gradient and an 8 × 8 premultiplied source.
"""
function fixture()
    image = Image(8,8)
    for i in 1:length(image)
        image[i] = rgbx(rgba(i,2i,3i,128+i))
    end
    stops = (GradientStop(0,Color(0.8,0.2,0.1)),GradientStop(1,Color(0.2,0.3,0.9)))
    frame = drawing(size=(128,64)) do e
        rectangle!(e,0,0,128,64;fill=LinearGradient((0,0),(128,0),stops))
        configure!(e;sampling=:linear)
        draw_image!(e,resource!(e,image),(16,8,96,48))
    end
    packed = Vellum.OpenGLBackend.pack_frame(frame,(128,64))
    return frame,(;packed.words,texels=reinterpret(UInt32,image.data),base=UInt32[0])
end

"""
    measure(ext,b,plan,frame,data,name,expr)

Collect 51 queue timestamp intervals for one specialized dispatch after five checked warm-ups.
"""
function measure(ext,b,plan,frame,data,name,expr)
    size = Int.(frame.size)
    expected = UInt32[reference(Val(name),data,PointI(x,y)) for x in 0:size[1]-1,y in 0:size[2]-1]
    native = ext.open_target(b.device,size;program=ext.draw_program(Kernel.shader_expr(expr)))
    surface = Vellum.VulkanBackend.QueueSurface(b,native)
    try
        samples = Float64[]
        want = reinterpret(UInt8,vec(expected))
        tolerance = name in (:pack_color,:stop_color,:paint_color,:texel_color,:image_color,:composite_pixel,:draw_pixel) ? 1 : 0
        for i in 1:56
            wait(submit!(b,surface,plan))
            stats = Vellum.VulkanBackend.statistics(surface)
            isnothing(stats.gpu_ns) && error("Vulkan queue has no timestamp support")
            stats.gpu_ns > 0 || error("Vulkan timestamp did not advance for $name")
            actual = readback(surface).data
            mismatch = findfirst(j -> abs(Int(want[j])-Int(actual[j]))>tolerance,eachindex(want))
            isnothing(mismatch) || error("Vulkan $name differs at byte $mismatch: GPU $(actual[mismatch]), Julia $(want[mismatch])")
            i>5 && push!(samples,stats.gpu_ns)
        end
        method = only(methods(getproperty(Kernel,name)))
        return (;name=String(name),method=string(method.sig),source=relpath(string(method.file),pkgdir(Vellum)),
            line=Int(method.line),inputs=length(expected),samples=length(samples),median_device_ns=sort!(samples)[26],
            p95_device_ns=samples[49],renderer=native.renderer)
    finally
        close(surface)
    end
end
end

"""
    profile_vulkan_methods(dir)

Write machine-readable and offline HTML tables of warmed, numerically checked Vulkan kernel workloads.
"""
function profile_vulkan_methods(dir)
    bench = VulkanMethodWorkloads
    frame,data = bench.fixture()
    backend = Vellum.VulkanBackend.QueueBackend()
    ext = Vellum.VulkanBackend.queue_extension()
    plan = prepare(backend,frame)
    rows = try
        [Base.invokelatest(bench.measure,ext,backend,plan,frame,data,name,expr) for (name,expr) in pairs(bench.EXPRESSIONS)]
    finally
        close(plan)
    end
    revision = profile_revision()
    open(joinpath(dir,"vulkan-methods.tsv"),"w") do io
        println(io,join(keys(first(rows)),'\t'),"\trevision\tjulia")
        foreach(r -> println(io,join(values(r),'\t'),'\t',revision,'\t',VERSION),rows)
    end
    open(joinpath(dir,"vulkan-methods.html"),"w") do io
        report_header(io,"Vulkan device method timings")
        println(io,"<p>",html_escape(first(rows).renderer)," · Julia ",VERSION," · ",html_escape(revision),
            "</p><p>51 timed dispatches after five warm-ups for each 8,192-input workload. Device time includes ",
            "argument preparation inside the shader, inlined callees and the output store. ",
            "Each readback was checked against the Julia implementation.</p>",
            "<p><a href='vulkan-methods.tsv'>Measurements</a> · <a href='vulkan.html'>Production frame timeline and timings</a></p>",
            "<table><tr><th>Device function</th><th>Julia definition</th><th>Median (µs/batch)</th><th>p95 (µs/batch)</th></tr>")
        for row in rows
            println(io,"<tr><td>",html_escape(row.name),"</td><td>",profile_source_link(dir,row.source,row.line),
                "</td><td>",row.median_device_ns/1000,"</td><td>",row.p95_device_ns/1000,"</td></tr>")
        end
        println(io,"</table></html>")
    end
    cuda = joinpath(dir,"gpu.tsv")
    isfile(cuda) && gpu_html(cuda)
    return rows
end
