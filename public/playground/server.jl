# This file serves the editor or brokers fixed, isolated container jobs.
pushfirst!(LOAD_PATH,@__DIR__)
push!(LOAD_PATH,normpath(joinpath(@__DIR__,"..","..")))
import HTTP, JSON
using UUIDs
include("page.jl")

"""Maximum submitted Julia source bytes and worker response bytes."""
const input_limit = 32_768
const output_limit = 10*1024^2
"""Allow one compilation per broker, returning HTTP 429 while it is occupied."""
const busy = Threads.Atomic{Bool}(false)

"""Launch an isolated worker with no mounts. Stop and remove this job on timeout or excess output."""
function container_run(source,target)
    engine = get(ENV,"VELLUM_ENGINE","docker")
    target in ("canvas","webgl2") || throw(ArgumentError("Unknown renderer"))
    name = "vellum-sketch-"*string(uuid4())
    image = get(ENV,"VELLUM_WORKER_IMAGE","vellum-playground-worker:local")
    cmd = `$engine run --rm -i --pull=never --name $name --network=none --read-only --cap-drop=ALL
        --security-opt=no-new-privileges --user=65532:65532 --pids-limit=64 --memory=1g --memory-swap=1g
        --cpus=1 --ulimit=nofile=256:256 --log-driver=none --tmpfs=/tmp:rw,noexec,nosuid,nodev,size=96m,mode=1777
        $image julia --startup-file=no --heap-size-hint=300M /opt/playground/worker.jl $target`
    pipe = Pipe()
    process = run(pipeline(cmd;stdin=IOBuffer(source),stdout=pipe,stderr=devnull);wait=false)
    close(pipe.in)
    readjob = @async read(pipe,output_limit+1)
    try
        timedwait(()->istaskdone(readjob),60;pollint=0.05) == :ok || error("Julia exceeded the 60-second run limit.")
        output = fetch(readjob)
        length(output) <= output_limit || error("Worker output exceeded the preview limit.")
        # EOF alone does not mean a user program has exited.
        timedwait(()->process_exited(process),2;pollint=0.05) == :ok || error("Worker did not exit after producing its result.")
        success(process) || error("Julia worker exited without a result. Check the worker image, engine and memory limit.")
        result = JSON.parse(String(output))
        if get(result,"error",nothing) isa String
            return (;error=first(result["error"],4000))
        end
        get(result,"html",nothing) isa String || error("Worker returned an invalid preview.")
        return (;html=result["html"])
    finally
        if process_running(process)
            run(pipeline(ignorestatus(`$engine rm -f $name`);stdout=devnull,stderr=devnull))
            process_running(process) && kill(process)
        end
        close(pipe)
        wait(process)
    end
end

"""Write an HTTP response and keep private editor submissions out of caches."""
function respond(stream,status,body,type="application/json")
    HTTP.setstatus(stream,status)
    HTTP.setheader(stream,"Content-Type"=>type)
    HTTP.setheader(stream,"Cache-Control"=>"no-store")
    HTTP.setheader(stream,"X-Content-Type-Options"=>"nosniff")
    HTTP.setheader(stream,"Referrer-Policy"=>"no-referrer")
    HTTP.setheader(stream,"X-Frame-Options"=>"DENY")
    HTTP.setheader(stream,"Content-Length"=>string(ncodeunits(body)))
    HTTP.startwrite(stream)
    write(stream,body)
end

"""Serve only the editor, health check and bounded, same-origin render requests."""
function handle(stream,mode,page,broker,previews)
    req = stream.message
    if req.method=="GET" && req.target=="/health"
        return respond(stream,200,"ok","text/plain")
    elseif mode!="broker" && req.method=="GET" && req.target=="/"
        return respond(stream,200,page,"text/html; charset=utf-8")
    end
    if mode!="broker" && req.method=="GET" && haskey(previews,req.target)
        file = previews[req.target]
        isfile(file) && return respond(stream,200,read(file,String),endswith(file,".ipynb") ? "application/x-ipynb+json" : "text/html; charset=utf-8")
    end
    fail(status,message) = respond(stream,status,JSON.json((;error=message)))
    req.method=="POST" && req.target in ("/api/run/canvas","/api/run/webgl2") || return fail(404,"Unknown endpoint.")
    HTTP.header(req,"Content-Type","")=="application/julia" || return fail(415,"Send a Julia source buffer.")
    origin = HTTP.header(req,"Origin","")
    host = HTTP.header(req,"Host","")
    isempty(origin) || origin in ("http://"*host,"https://"*host) || return fail(403,"Origin does not match this editor.")
    count = tryparse(Int,HTTP.header(req,"Content-Length",""))
    !isnothing(count) && 0<count<=input_limit && isempty(HTTP.header(req,"Transfer-Encoding","")) ||
        return fail(413,"Submit between 1 byte and 32 KiB of Julia code.")
    Threads.atomic_cas!(busy,false,true) && return fail(429,"A Julia run is in progress. Try again shortly.")
    try
        # HTTP can deliver the declared body in several packets.
        source = read!(stream,Vector{UInt8}(undef,count))
        isvalid(String,source) || return fail(400,"Invalid UTF-8 source.")
        if mode=="web"
            response = HTTP.post(broker*req.target,["Content-Type"=>"application/julia"],source;
                                 readtimeout=72,connect_timeout=5,retry=false,status_exception=false)
            respond(stream,response.status,String(response.body))
        else
            target = last(split(req.target,"/"))
            result = container_run(source,target)
            respond(stream,hasproperty(result,:error) ? 422 : 200,JSON.json(result))
        end
    catch err
        # HTTP request exceptions can contain the entire submitted Julia buffer.
        @warn "Playground request failed" mode path=req.target exception_type=typeof(err)
        fail(503,"The drawing worker could not finish. Check that the engine and worker image are available, then retry.")
    finally
        busy[] = false
    end
end

"""Listen on loopback by default. The Compose frontend and broker have separate network and engine access."""
function serve()
    mode = get(ENV,"VELLUM_MODE","local")
    mode in ("local","web","broker") || error("Unknown server mode")
    host = get(ENV,"VELLUM_BIND","127.0.0.1")
    port = parse(Int,get(ENV,"VELLUM_PORT","8080"))
    page = mode=="broker" ? "" : editor_page()
    previews = mode=="broker" ? Dict() : Dict("/tutorial/$(lesson.id)/$target"=>joinpath(preview_dir(),"$(lesson.id)-$target.html") for lesson in playground_lessons() for target in (:canvas,:webgl2))
    if mode!="broker"
        for lesson in playground_lessons()
            previews["/notebook/"*lesson.id] = joinpath(pkgdir(Vellum),"tutorials",lesson.id*".ipynb")
        end
    end
    broker = get(ENV,"VELLUM_BROKER","http://broker:8081")
    @info "Vellum playground" mode host port
    HTTP.serve(stream->handle(stream,mode,page,broker,previews),host,port;stream=true,readtimeout=90)
end
if abspath(PROGRAM_FILE)==@__FILE__
    serve()
end
