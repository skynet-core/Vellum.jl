"""Compare measured output values, including owned raster pixels."""
profile_equal(a,b) = isequal(a,b)
profile_equal(a::Image,b::Image) = size(a)==size(b) && a.data==b.data

"""
    cpu_batch_timing(f, inputs...) -> NamedTuple

Warm one concrete method and measure 51 calls to `map!` over runtime inputs.
Median and nearest-rank p95 are batch wall-clock nanoseconds divided by the
number of inputs. Allocation counts and bytes refer to the entire batch.
"""
function cpu_batch_timing(f,inputs...)
    expected = map(f,inputs...)
    output = similar(expected)
    map!(f,output,inputs...)
    n = length(output)
    times = Float64[]
    allocations = Int[]
    bytes = Int[]
    for _ in 1:51
        sample = @timed map!(f,output,inputs...)
        all(profile_equal(a,b) for (a,b) in zip(output,expected)) || error("unstable results from $f")
        push!(times,1e9 * sample.time / n)
        push!(allocations,Base.gc_alloc_count(sample.gcstats))
        push!(bytes,sample.bytes)
    end
    sort!(times)
    return (;inputs=n,samples=length(times),median_ns=times[26],p95_ns=times[49],
            allocations=sort!(allocations)[26],bytes=sort!(bytes)[26])
end

"""Measure first-party codec calls and their parsing and pixel conversion helpers on real images."""
function codec_workloads(record)
    images = [Image(17,13) for _ in 1:8]
    for (i,image) in enumerate(images), k in 1:length(image)
        image[k] = rgbx(rgba(mod(k,256),mod(3k,256),mod(k+i,256),mod(5k+i,256)))
    end
    payloads = encode_webp.(images)
    for f in (encode_webp,Vellum._straight_rgba_bytes)
        record(string(nameof(f)),f,images)
    end
    for f in (decode_webp,decode_webp_dimensions,decode_image,decode_image_dimensions,
              ImageCodecs.webp_signature,ImageCodecs.webp_animated)
        record(string(nameof(f)),f,payloads)
    end
end

"""
    desktop_image_workloads(record)
    queue_kernel_workloads(record)

Time the production crop, placement and page-identity methods over distinct source rectangles.
Every batch consumes its results. Actual GPU queue and transfer timings use the device profiler.
"""
function desktop_image_workloads(record)
    gl = Vellum.OpenGLBackend
    pages = gl.RasterPages
    crops = [(x,0,x+8,8) for x in 0:63]
    image = Image(72,8)
    for y in 1:8, x in 1:72
        image[y,x] = rgbx(x,y,0,255)
    end
    dense = ImageData(image)
    frame = drawing(size=(72,8)) do e
        source = resource!(e,:image,dense)
        for (l,t,r,b) in crops
            draw_image!(e,source,(l,t,r-l,b-t);source=(l,t,r-l,b-t))
        end
    end
    nodes = collect(frame.nodes)
    ops = [n.operation::ImageRegion for n in nodes]
    record("dense RGBA8 crop",Vellum._dense_crop,fill(dense,length(crops)),crops)
    record("source crop layout",Vellum._image_crop_layout,ops,[n.id for n in nodes],
           fill(72,length(ops)),fill(8,length(ops)))
    record("desktop image placement",gl.image_placement,nodes,fill(frame,length(nodes)),fill(Transform2D(),length(nodes)))
    record("desktop tile bounds",gl.desktop_page_grid,crops)
    metadata = ImageMetadata(72,8;storage=:tiled)
    sources = [RasterReference(1,1,i,metadata) for i in eachindex(crops)]
    packed = pages.PageSource.(sources)
    record("pack source revision",pages.PageSource,sources)
    record("page source dimensions",pages.source_dimensions,packed)
    record("recover source reference",pages.reference,packed)
    keys = [pages.TileKey(src,mod(i,2),0) for (i,src) in pairs(packed)]
    record("edge page dimensions",pages.dimensions,keys)
    record("page cache partition",pages.page_partition,keys)
end

"""Time individual Julia functions used by the production Vulkan compute kernel with a real draw packet."""
function queue_kernel_workloads(record)
    kernel = Vellum.VulkanBackend.QueueKernel
    image = Image(8,8)
    for i in 1:length(image)
        image[i] = rgbx(i,2i,3i,255)
    end
    gradient = LinearGradient((0,0),(64,0),(GradientStop(0,Color(0.2,0.5,1)),GradientStop(1,Color(1,0.2,0.4))))
    frame = drawing(size=(64,32)) do e
        rectangle!(e,0,0,64,32;fill=gradient)
        configure!(e;sampling=:linear)
        draw_image!(e,resource!(e,image),(8,4,48,24))
    end
    packed = Vellum.OpenGLBackend.pack_frame(frame,(64,32))
    data = (;packed.words,texels=reinterpret(UInt32,image.data),base=UInt32[0])
    t = kernel.packet_tables(data)
    n = 128
    inputs,tables = fill(data,n),fill(t,n)
    pixels = [kernel.PointI(mod(7i,64),mod(3i,32)) for i in 1:n]
    points = [kernel.PointD(p.x+0.125,p.y+0.375) for p in pixels]
    colors = repeat(data.texels,2)
    rgba = kernel.unpack_color.(colors)
    targets = [(32+2mod(i,100),24+2mod(i,123)) for i in 1:n]
    record("Vulkan fit to window",Vellum.VulkanBackend.fitted_rect,fill((80,64),n),targets)
    record("Wayland physical buffer scale",Vellum.VulkanBackend.window_buffer_scale,fill(2,n),targets)
    record("Vulkan packet offset read",kernel.at_offset,fill(packed.words,n),mod.(1:n,length(packed.words)))
    record("Vulkan fractional texel",kernel.floor_point,points)
    record("Vulkan decode color",kernel.unpack_color,colors)
    record("Vulkan encode color",kernel.pack_color,rgba)
    record("Vulkan packet integer",kernel.intword,inputs,mod.(1:n,10))
    record("Vulkan packet tables",kernel.packet_tables,inputs)
    record("Vulkan shape coverage",kernel.inside_shape,inputs,tables,mod.(1:n,2),points)
    record("Vulkan gradient stop",kernel.stop_color,inputs,fill(t.stop,n))
    record("Vulkan gradient sample",kernel.paint_color,inputs,tables,fill(10,n),points)
    record("Vulkan dense texel",kernel.texel_color,inputs,tables,fill(t.raster,n),falses(n),pixels)
    record("Vulkan filtered image",kernel.image_color,inputs,tables,fill(24,n),falses(n),points)
    record("Vulkan pixel composition",kernel.composite_pixel,rgba,reverse(rgba),isodd.(1:n))
    record("Vulkan full pixel",kernel.draw_pixel,inputs,pixels)
end

"""Write CPU workload distributions, definition locations, and all inventory gaps to TSV and HTML."""
function cpu_method_timings(dir,inventory)
    rows = NamedTuple[]
    measured = Set{Method}()
    revision = profile_revision()
    record = function (name,f,inputs...)
        method = which(f,Tuple{eltype.(inputs)...})
        push!(rows,(;name,method=string(method.sig),source=relpath(string(method.file),pkgdir(Vellum)),
                    line=Int(method.line),cpu_batch_timing(f,inputs...)...,revision,julia=string(VERSION),cpu=Sys.CPU_NAME))
        push!(measured,method)
    end
    profile_workloads(record,4096)
    codec_workloads(record)
    desktop_image_workloads(record)
    queue_kernel_workloads(record)
    open(joinpath(dir,"cpu-methods.tsv"),"w") do io
        println(io,join(string.(keys(first(rows))),'\t'))
        foreach(row->println(io,join(values(row),'\t')),rows)
    end
    open(joinpath(dir,"cpu-methods.html"),"w") do io
        report_header(io,"Vellum CPU method timings")
        println(io,"<p>",html_escape(Sys.CPU_NAME)," · Julia ",VERSION," · ",html_escape(revision),
                "</p><p>One warm-up batch and 51 timed batches per workload. Times include traversal and the output store, ",
                "in nanoseconds per input. Allocations and bytes are medians per batch. Every output was checked.</p>",
                "<p><a href='cpu-methods.tsv'>Download measurements</a> · <a href='cpu.html'>Sampled CPU stacks</a></p>",
                "<table><tr><th>Workload</th><th>Definition</th><th>Inputs per batch</th><th>Median ns</th>",
                "<th>p95 ns</th><th>Allocations</th><th>Bytes</th></tr>")
        for r in rows
            println(io,"<tr><td>",html_escape(r.name),"</td><td>",profile_source_link(dir,r.source,r.line),
                    "</td><td>",r.inputs,"</td><td>",round(r.median_ns;digits=2),"</td><td>",
                    round(r.p95_ns;digits=2),"</td><td>",r.allocations,"</td><td>",r.bytes,"</td></tr>")
        end
        missing = filter(m->m ∉ measured,inventory)
        println(io,"</table><details><summary>",length(missing)," inventoried methods without a direct measurement</summary><ul>")
        for m in missing
            println(io,"<li><code>",html_escape(m.sig),"</code> ",profile_source_link(dir,relpath(string(m.file),pkgdir(Vellum)),m.line),"</li>")
        end
        println(io,"</ul></details>")
    end
end
