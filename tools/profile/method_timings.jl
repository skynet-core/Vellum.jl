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
