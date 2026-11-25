import JSON
include("../report_html.jl")

"""
    percentile(values,p)

Return the nearest-rank percentile in the units of the supplied observations.
"""
percentile(values,p) = sort(values)[cld(length(values)*p,100)]

"""
    write_device_profile(dir,rows,stats,api)

Write sample timings, an offline HTML view and a Chrome Trace Event timeline.
"""
function write_device_profile(dir,rows,stats,api)
    mkpath(dir)
    slug = lowercase(api)
    revision = profile_revision()
    fields = keys(first(rows))
    open(joinpath(dir,slug*".tsv"),"w") do io
        println(io,join(fields,'\t'))
        foreach(r -> println(io,join(values(r),'\t')),rows)
    end
    open(joinpath(dir,slug*".html"),"w") do io
        report_header(io,api*" frame profile")
        println(io,"<p>",html_escape(stats.renderer)," · ",html_escape(stats.vendor)," · Julia ",VERSION,
            " · ",html_escape(revision)," · 256 × 192 physical pixels · 32 paths · 5 warm-ups · ",length(rows)," measured frames</p>",
            "<p>Host submission includes path preparation and the nonblocking driver submission. ",
            "Device timestamps enclose the queued frame commands, including any input transfers. ",
            "Readback starts after the final timestamp is available.</p>",
            "<table><tr><th>Operation</th><th>Median (µs)</th><th>p95 (µs)</th><th>Median Julia allocation (bytes)</th></tr>")
        for (name,times,allocs) in (
                ("Host submission",[r.stop-r.start for r in rows],[r.submit_bytes for r in rows]),
                ("GPU timestamp interval",[r.last_gpu-r.first_gpu for r in rows],nothing),
                ("Host readback",[r.read_stop-r.read_start for r in rows],[r.read_bytes for r in rows]))
            println(io,"<tr><td>",name,"</td><td>",round(percentile(times,50)/1000;digits=2),
                "</td><td>",round(percentile(times,95)/1000;digits=2),"</td><td>",
                isnothing(allocs) ? "—" : percentile(allocs,50),"</td></tr>")
        end
        println(io,"</table>")
        api == "Vulkan" && println(io,"<p><a href='vulkan-methods.html'>Per-function Vulkan device timings</a></p>")
        println(io,"<p><a href='",slug,".trace.json'>Trace Event timeline</a> · ",
            "<a href='",slug,".tsv'>Raw timestamps (ns) and allocations (bytes)</a></p>",
            "<p>Open the timeline in Perfetto. CPU and GPU lanes each start at their first ",
            "measurement. Compare durations within each clock domain.</p></html>")
    end
    events = Any[(;name="process_name",ph="M",pid=pid,tid=1,args=(;name))
                 for (pid,name) in enumerate(("CPU host clock",api*" device clock"))]
    for (i,r) in pairs(rows)
        for (name,lane,start,stop,origin) in (
                ("submit_frame!",1,r.start,r.stop,rows[1].start),
                ("readback",1,r.read_start,r.read_stop,rows[1].start),
                (api*" draw",2,r.first_gpu,r.last_gpu,rows[1].first_gpu))
            push!(events,(;name,ph="X",pid=lane,tid=1,ts=(start-origin)/1000,
                           dur=(stop-start)/1000,args=(frame=i,)))
        end
    end
    open(joinpath(dir,slug*".trace.json"),"w") do io
        JSON.print(io,(;traceEvents=events,displayTimeUnit="ns",
            metadata=(;api,revision,renderer=stats.renderer,vendor=stats.vendor,julia=string(VERSION),clock_origins="independent")))
    end
end

"""
    profile_frame()

Build the same 32-path benchmark for both native graphics APIs.
"""
function profile_frame()
    return drawing(size=(256,192)) do edit
        for i in 0:31
            rectangle!(edit,8mod(i,16),64div(i,16),9,32;fill=Solid(i/32,0.5,1-i/32))
        end
    end
end
