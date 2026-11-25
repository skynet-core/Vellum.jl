using Vellum
import JSON
include("../report_html.jl")

"""The installed first-party GLX renderer, loaded without opening a drawable."""
const GLXRenderer = Vellum.OpenGLBackend.glx_extension()
"""OpenGL library used by the renderer and the timer queries on its context."""
const timer_gl = GLXRenderer.libGL

"""Collect one submission between GPU timestamps and measure host readback after completion."""
function timed_draw(surface, frame, queries)
    native = surface.native
    sample = GLXRenderer.with_context(native) do
        native.valid = false
        ccall((:glQueryCounter,timer_gl),Cvoid,(Cuint,Cuint),queries[1],0x8e28)
        start = time_ns()
        submit = @timed GLXRenderer.submit_frame!(native,frame,false)
        stop = time_ns()
        ccall((:glQueryCounter,timer_gl),Cvoid,(Cuint,Cuint),queries[2],0x8e28)
        first_gpu,last_gpu = map(queries) do id
            timestamp = Ref{UInt64}()
            ccall((:glGetQueryObjectui64v,timer_gl),Cvoid,(Cuint,Cuint,Ref{UInt64}),id,0x8866,timestamp)
            timestamp[]
        end
        ccall((:glGetError,timer_gl),Cuint,()) == 0 || error("GL timestamp query failed")
        last_gpu > first_gpu || error("OpenGL timestamps did not advance")
        native.valid = true
        native.frames += 1
        (;start,stop,first_gpu,last_gpu,submit_bytes=submit.bytes)
    end
    read_start = time_ns()
    transfer = @timed readback(surface)
    read_stop = time_ns()
    return (;sample...,read_start,read_stop,read_bytes=transfer.bytes),transfer.value
end

"""Return the nearest-rank percentile in the units of the supplied observations."""
percentile(values,p) = sort(values)[cld(length(values)*p,100)]

"""Write sample timings, an offline HTML view and a Chrome Trace Event timeline."""
function write_gl_profile(dir,rows,stats)
    mkpath(dir)
    fields = keys(first(rows))
    open(joinpath(dir,"opengl.tsv"),"w") do io
        println(io,join(fields,'\t'))
        foreach(r -> println(io,join(values(r),'\t')),rows)
    end
    open(joinpath(dir,"opengl.html"),"w") do io
        report_header(io,"OpenGL frame profile")
        println(io,"<p>",html_escape(stats.renderer)," · ",html_escape(stats.vendor)," · Julia ",VERSION,
            " · 256 × 192 physical pixels · 32 paths · 5 warm-ups · ",length(rows)," measured frames</p>",
            "<p>Host submission includes path preparation and the nonblocking driver submission. ",
            "The two device timestamps enclose the queued drawing commands and may include idle time. ",
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
        println(io,"</table><p><a href='opengl.trace.json'>Trace Event timeline</a> · ",
            "<a href='opengl.tsv'>Raw timestamps (ns) and allocations (bytes)</a></p>",
            "<p>Open the timeline in Perfetto. CPU and GPU lanes each start at their first ",
            "measurement. Compare durations within each clock domain.</p></html>")
    end
    events = Any[(;name="process_name",ph="M",pid=pid,tid=1,args=(;name))
                 for (pid,name) in enumerate(("CPU host clock","OpenGL device clock"))]
    for (i,r) in pairs(rows)
        for (name,lane,start,stop,origin) in (
                ("submit_frame!",1,r.start,r.stop,rows[1].start),
                ("readback",1,r.read_start,r.read_stop,rows[1].start),
                ("OpenGL draw",2,r.first_gpu,r.last_gpu,rows[1].first_gpu))
            push!(events,(;name,ph="X",pid=lane,tid=1,ts=(start-origin)/1000,
                           dur=(stop-start)/1000,args=(frame=i,)))
        end
    end
    open(joinpath(dir,"opengl.trace.json"),"w") do io
        JSON.print(io,(;traceEvents=events,displayTimeUnit="ns",
            metadata=(renderer=stats.renderer,vendor=stats.vendor,julia=string(VERSION),clock_origins="independent")))
    end
end

"""Profile solid paths on a real OpenGL target and check every readback against the CPU image."""
function profile_gl(dir)
    frame = drawing(size=(256,192)) do edit
        for i in 0:31
            rectangle!(edit,8mod(i,16),64div(i,16),9,32;fill=Solid(i/32,0.5,1-i/32))
        end
    end
    expected = rasterize(frame)
    surface = render(frame;backend=Vellum.OpenGLBackend.DesktopBackend())
    try
        rows = GLXRenderer.with_context(surface.native) do
            bits = Ref{Cint}()
            ccall((:glGetQueryiv,timer_gl),Cvoid,(Cuint,Cuint,Ref{Cint}),0x8e28,0x8864,bits)
            bits[] > 0 || error("OpenGL timestamp queries unavailable on this device")
            ids = zeros(Cuint,2)
            ccall((:glGenQueries,timer_gl),Cvoid,(Cint,Ptr{Cuint}),2,ids)
            try
                samples = map(1:35) do _
                    row,image = timed_draw(surface,frame,ids)
                    all(i -> abs(Int(expected.data[i])-Int(image.data[i])) <= 1,eachindex(image.data)) ||
                        error("profiled GPU output differs from the reference")
                    row
                end
                return samples[6:end]
            finally
                ccall((:glDeleteQueries,timer_gl),Cvoid,(Cint,Ptr{Cuint}),2,ids)
            end
        end
        write_gl_profile(dir,rows,Vellum.OpenGLBackend.statistics(surface))
    finally
        close(surface)
    end
end

profile_gl(isempty(ARGS) ? joinpath(pkgdir(Vellum),"profiles") : abspath(only(ARGS)))
