include("../report_html.jl")

"""Profile the production DataDrawing replay on its WebGL2 context. Times are collected inside the browser."""
const webgl_profile_driver = @browser host -> begin
    @var gl = host.canvas.getContext("webgl2")
    @var ext = gl.getExtension("EXT_disjoint_timer_query_webgl2")
    @var info = gl.getExtension("WEBGL_debug_renderer_info")
    @var query = nothing
    @var pixel = @new Uint8Array(4)
    host.update(host.config)
    window.vellumTiming = d(
        renderer=gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER),
        browser=navigator.userAgent, width=host.canvas.width, height=host.canvas.height,
        supported=Boolean(ext),
        submit=()->begin
            if gl.isContextLost() || gl.getParameter(ext.GPU_DISJOINT_EXT)
                throw(@new Error("WebGL timer interrupted before submission"))
            end
            query = gl.createQuery()
            gl.beginQuery(ext.TIME_ELAPSED_EXT,query)
            @var start = performance.now()
            host.update(host.config)
            @var stop = performance.now()
            gl.endQuery(ext.TIME_ELAPSED_EXT)
            @var readStart = performance.now()
            gl.readPixels(1,host.canvas.height-2,1,1,gl.RGBA,gl.UNSIGNED_BYTE,pixel)
            @var readStop = performance.now()
            return [start,stop,readStart,readStop,Array.from(pixel)]
        end,
        result=()->begin
            @var available = gl.getQueryParameter(query,gl.QUERY_RESULT_AVAILABLE)
            if gl.isContextLost() || gl.getParameter(ext.GPU_DISJOINT_EXT)
                gl.deleteQuery(query)
                throw(@new Error("WebGL device timer became disjoint"))
            end
            if available
                @var elapsed = gl.getQueryParameter(query,gl.QUERY_RESULT)
                gl.deleteQuery(query)
                query = nothing
                return elapsed
            end
            return nothing
        end)
end

"""Time the Canvas 2D Wasm update and read the composited pixel through its built-in context."""
const canvas_profile_driver = @browser host -> begin
    @var ctx = host.canvas.getContext("2d")
    host.update(host.config)
    window.vellumTiming = d(renderer="Canvas 2D",browser=navigator.userAgent,width=host.canvas.width,height=host.canvas.height,
        supported=true,submit=()->begin
            @var start = performance.now()
            host.update(host.config)
            @var stop = performance.now()
            @var p = ctx.getImageData(1,1,1,1)
            return [start,stop,stop,performance.now(),Array.from(p.data)]
        end)
end

"""Enable timestamp queries on the profiling page's adapter, preserving its original device options."""
const enable_webgpu_timing = @browser () -> begin
    @var proto = GPUAdapter.prototype
    @var original = proto.requestDevice
    proto.requestDevice = @new Proxy(original,d(apply=(f,adapter,args)->begin
        window.vellumTimerAvailable = adapter.features.has("timestamp-query")
        if window.vellumTimerAvailable
            @var desc = Object.assign(d(),args[0])
            desc.requiredFeatures = Array.from(@new Set((desc.requiredFeatures || []).concat(["timestamp-query"])))
            return Reflect.apply(f,adapter,[desc])
        end
        return Reflect.apply(f,adapter,args)
    end))
end

"""Attach pass timestamps to the production WebGPU encoder and map a checked pixel after submission."""
const webgpu_profile_driver = @browser host -> begin
    @var ctx = host.canvas.getContext("webgpu")
    @var cfg = ctx.getConfiguration()
    @var device = cfg.device
    @var info = device.adapterInfo
    @var supported = device.features.has("timestamp-query")
    @var timing = d(renderer=info.description || (info.vendor+" "+info.architecture),browser=navigator.userAgent,
        width=host.canvas.width,height=host.canvas.height,supported=supported)
    window.vellumTiming = timing
    if !supported
        return
    end
    cfg.usage = GPUTextureUsage.RENDER_ATTACHMENT + GPUTextureUsage.COPY_SRC
    ctx.configure(cfg)
    @var queries = device.createQuerySet(d(type="timestamp",count=2))
    @var resolved = device.createBuffer(d(size=16,usage=GPUBufferUsage.QUERY_RESOLVE+GPUBufferUsage.COPY_SRC))
    @var read = device.createBuffer(d(size=20,usage=GPUBufferUsage.COPY_DST+GPUBufferUsage.MAP_READ))
    @var timed = false
    @var passes = 0
    @var original = device.createCommandEncoder.bind(device)
    device.createCommandEncoder = desc->begin
        @var encoder = original(desc)
        if timed
            @var beginPass = encoder.beginRenderPass.bind(encoder)
            encoder.beginRenderPass = options->begin
                passes = passes+1
                options.timestampWrites = d(querySet=queries,beginningOfPassWriteIndex=0,endOfPassWriteIndex=1)
                return beginPass(options)
            end
        end
        return encoder
    end
    host.update(host.config)
    timing.submit = ()->begin
        passes = 0
        timed = true
        @var start = performance.now()
        host.update(host.config)
        @var stop = performance.now()
        timed = false
        if passes!==1
            throw(@new Error("Expected one timed render pass for this drawing"))
        end
        @var readStart = performance.now()
        @var encoder = original()
        encoder.resolveQuerySet(queries,0,2,resolved,0)
        encoder.copyBufferToBuffer(resolved,0,read,0,16)
        encoder.copyTextureToBuffer(d(texture=ctx.getCurrentTexture(),origin=[1,1,0]),d(buffer=read,offset=16),[1,1,1])
        device.queue.submit([encoder.finish()])
        return read.mapAsync(GPUMapMode.READ).then(()->begin
            @var readStop = performance.now()
            @var buffer = read.getMappedRange()
            @var ns = @new BigUint64Array(buffer,0,2)
            @var elapsed = Number(ns[1]-ns[0])
            @var b = @new Uint8Array(buffer,16,4)
            @var pixel = cfg.format==="bgra8unorm" ? [b[2],b[1],b[0],b[3]] : Array.from(b)
            read.unmap()
            return [start,stop,readStart,readStop,pixel,elapsed]
        end)
    end
end

"""Measure 51 warmed Wasm replays, verify a framebuffer pixel on every submission, and write offline reports."""
function profile_browser(ws,dir,target)
    layer = drawing_layer(:cells) do edit,row,model
        rectangle!(edit,row.x,row.y,16,12;fill=row.color)
    end
    cells = [(x=16*(i%16),y=12*(i÷16),color=iseven(i) ? 0x2858a8 : 0xff9944) for i in 0:255]
    font = FontData("Liberation Sans",read(joinpath(pkgdir(Vellum),"test","fixtures","LiberationSans-Regular.ttf")))
    title,driver = if target===:canvas
        "Canvas 2D",canvas_profile_driver
    elseif target===:webgl2
        "WebGL2",webgl_profile_driver
    else
        "WebGPU",webgpu_profile_driver
    end
    drawing = DataDrawing("$title frame timing",(256,192),font,[layer])
    path = savehtml(joinpath(dir,"profile-$target.html"),drawing;target,config=(;cells),driver)
    if target===:webgpu
        protocol(ws,"Page.enable")
        hook = protocol(ws,"Page.addScriptToEvaluateOnNewDocument",(source=enable_webgpu_timing*"()",))
    end
    try
        navigate(ws,"file://"*path)
        ready = timedwait(()->evaluate(ws,"location.pathname.endsWith('/profile-$target.html') && !!window.vellumTiming"),15)
        ready===:ok || error("$title profiler could not open: "*string(evaluate(ws,"document.querySelector('output')?.textContent")))
    finally
        target===:webgpu && protocol(ws,"Page.removeScriptToEvaluateOnNewDocument",(identifier=hook["identifier"],))
    end
    device = evaluate(ws,@browser begin
        @var p = window.vellumTiming
        return [p.renderer,p.browser,p.width,p.height,p.supported]
    end)
    if target===:webgpu && isnothing(evaluate(ws,"window.vellumTimerAvailable"))
        error("WebGPU profiling script did not observe the device request")
    end
    device[5] || error("$title device timing is unavailable on $(device[1])")
    rows = NamedTuple[]
    for frame in 1:56
        response = protocol(ws,"Runtime.evaluate",(expression="window.vellumTiming.submit()",returnByValue=true,awaitPromise=true))
        haskey(response,"exceptionDetails") && error(response["exceptionDetails"])
        sample = response["result"]["value"]
        start,stop,read_start,read_stop,pixel = sample
        pixel == [40,88,168,255] || error("unexpected pixel from profiled $title Wasm replay: $pixel")
        elapsed = if target===:webgpu
            sample[6]
        elseif target===:webgl2
            result = nothing
            ready = timedwait(10;pollint=0.005) do
                result = evaluate(ws,@browser window.vellumTiming.result())
                return !isnothing(result)
            end
            ready===:ok || error("WebGL2 did not complete timer query for frame $frame")
            result
        end
        isnothing(elapsed) || elapsed>=0 || error("invalid $title device timestamp interval")
        (start <= stop <= read_start <= read_stop) || error("non-monotonic browser clock on $title")
        if frame>5
            push!(rows,(;frame=frame-5,host_ms=stop-start,device_ns=isnothing(elapsed) ? missing : Int(elapsed),read_ms=read_stop-read_start))
        end
    end
    if target!==:canvas && all(r->iszero(r.device_ns),rows)
        error("$title device timings were all below the browser clock resolution")
    end
    output = mkpath(joinpath(pkgdir(Vellum),"profiles"))
    revision = profile_revision()
    metadata = join((device[1],device[2],"$(device[3]) × $(device[4]) physical pixels","Julia $VERSION",revision)," · ")
    open(joinpath(output,"$target.tsv"),"w") do io
        println(io,"# ",metadata)
        println(io,join(keys(first(rows)),'\t'))
        foreach(r->println(io,join(values(r),'\t')),rows)
    end
    open(joinpath(output,"$target.html"),"w") do io
        report_header(io,"$title Wasm frame profile")
        println(io,"<p>",html_escape(metadata),"</p><p>256 retained rectangles per frame. Five warm-ups and 51 measured replays. ",
                "Each replay verified an RGBA pixel. Host submission covers the synchronous Wasm update and driver calls. ",
                target===:canvas ? "Canvas 2D exposes host timings only. " : "Device intervals include the timed graphics commands at the precision exposed by the browser. ",
                "Readback includes synchronization and one pixel",target===:webgpu ? " plus the query result" : "",".</p>",
                "<table><tr><th>Operation</th><th>Median (µs)</th><th>p95 (µs)</th><th>Samples in order</th><th>Peak (µs)</th></tr>")
        for (label,values) in (("Host submission",[1000*r.host_ms for r in rows]),
                               ("GPU elapsed",Float64[r.device_ns/1000 for r in rows if !ismissing(r.device_ns)]),
                               ("Host readback",[1000*r.read_ms for r in rows]))
            isempty(values) && continue
            peak = maximum(values)
            points = join((string(i-1,",",round(23-22*v/max(peak,eps());digits=2)) for (i,v) in pairs(values))," ")
            sort!(values)
            println(io,"<tr><td>",label,"</td><td>",round(values[26];digits=2),"</td><td>",
                    round(values[49];digits=2),"</td><td><svg viewBox='0 0 50 24' width='150' height='30' preserveAspectRatio='none'>",
                    "<title>",label," runs from zero to ",round(peak;digits=2)," microseconds</title><polyline points='",
                    points,"' fill='none' stroke='currentColor' vector-effect='non-scaling-stroke'/></svg></td><td>",
                    round(peak;digits=2),"</td></tr>")
        end
        println(io,"</table><p><a href='$target.tsv'>All 51 samples</a></p></html>")
    end
    navigate(ws,"file://"*joinpath(output,"$target.html"))
    plots = target===:canvas ? 2 : 3
    @test timedwait(()->evaluate(ws,@browser document.querySelectorAll("table svg polyline").length)==plots,10)===:ok
    @info "Measured $title Wasm replays" renderer=device[1] frames=length(rows) output
end
