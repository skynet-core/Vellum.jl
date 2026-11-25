using Profile
import JSON
include("../report_html.jl")
include("workloads.jl")
include("method_timings.jl")

"""Identify shipped package and extension methods by their source directories."""
package_source(path, roots) = any(root -> startswith(path,root),roots)

"""Inventory loaded package methods, including closures and extensions of external generics."""
function package_methods(roots)
    matches = Base._methods_by_ftype(Tuple, -1, Base.get_world_counter())
    return Set(m.method for m in matches if package_source(string(m.method.file),roots))
end

"""Capture warmed package call stacks, inventory method definitions and time the matched CPU workloads."""
function cpu_profile(workload, dir)
    roots = [joinpath(pkgdir(Vellum),dir,"") for dir in ("src","ext")]
    (Sys.islinux() || Sys.isfreebsd()) && Vellum.OpenGLBackend.glx_extension()
    mkpath(dir)
    period = 0.0005
    Profile.init(n=10^7, delay=period)
    Profile.clear()
    Profile.@profile workload()
    data, lookup = Profile.retrieve()
    counts = Dict{Method,Int}()
    methods_seen = package_methods(roots)
    frames = Dict{Tuple{String,String,Int},Int}()
    stacks = Vector{Vector{Int}}()
    stack = Int[]
    sample_methods = Set{Method}()
    first_ip = 1
    for i in eachindex(data)
        Profile.is_block_end(data,i) || continue
        addresses = @view data[first_ip:i-Profile.nmeta-2]
        first_ip = i+1
        data[i-Profile.META_OFFSET_SLEEPSTATE] == 1 || continue
        empty!(stack)
        empty!(sample_methods)
        for ip in addresses, frame in get(lookup,ip,())
            path = string(frame.file)
            package_source(path,roots) || continue
            key = (string(frame.func), relpath(path,Base.pkgdir(Vellum)), frame.line)
            push!(stack, get!(() -> length(frames), frames, key))
            method = frame.linfo
            method isa Core.CodeInstance && (method = method.def)
            method isa Core.MethodInstance && (method = method.def)
            method isa Method && push!(sample_methods,method)
        end
        isempty(stack) || push!(stacks,reverse(stack))
        for m in sample_methods
            counts[m] = get(counts,m,0)+1
        end
    end
    union!(methods_seen, keys(counts))
    ordered = sort!(collect(methods_seen);by=m->(-get(counts,m,0),string(m.file),m.line,string(m.sig)))
    open(joinpath(dir,"cpu.tsv"),"w") do io
        println(io,"method\tsource\tline\tinclusive_samples")
        for m in ordered
            println(io,m.sig,'\t',relpath(string(m.file),Base.pkgdir(Vellum)),'\t',m.line,'\t',get(counts,m,0))
        end
    end
    cpu_method_timings(dir,ordered)
    # Speedscope sampled profile format, one stack per sample that entered package code.
    orderedframes = sort!(collect(frames);by=last)
    shared = [(name=k[1],file=k[2],line=k[3]) for (k,_) in orderedframes]
    cpuprofile(joinpath(dir,"cpu.cpuprofile"),shared,stacks,period)
    profile = (;type="sampled",name="Vellum unit tests",unit="seconds",startValue=0,
               endValue=period*length(stacks),samples=stacks,weights=fill(period,length(stacks)))
    open(joinpath(dir,"cpu.speedscope.json"),"w") do io
        JSON.print(io,(;shared=(frames=shared,),profiles=[profile],activeProfileIndex=0,
                       exporter="Vellum / Julia Profile",name="Vellum CPU"))
    end
    open(joinpath(dir,"cpu.html"),"w") do io
        report_header(io,"Vellum CPU profile")
        println(io,"<p>",html_escape(Sys.CPU_NAME)," · Julia ",VERSION," · ",length(stacks),
                " samples within Vellum · sampling interval ",1000period," ms</p>",
                "<p>The sampler observed ",length(counts)," of ",length(ordered),
                " inventoried methods in the warm unit test workload. Inclusive counts include callees. Zero means the sampler did not observe this method.</p>",
                "<p>The stack views retain time sampled inside Vellum. Gaps between package samples are omitted.</p>",
                "<p><a href=\"cpu-methods.html\">Direct CPU method timings and allocations</a> · <a href=\"cpu.cpuprofile\">Open the CPU profile in VS Code</a> · ",
                "<a href=\"cpu.speedscope.json\">Speedscope profile</a></p>",
                "<table><tr><th>Inclusive samples</th><th>Method</th><th>Defined at</th></tr>")
        peak = maximum(values(counts);init=1)
        for m in ordered
            count = get(counts,m,0)
            println(io,"<tr><td><meter max=",peak," value=",count,"></meter> ",count,
                    "</td><td>",html_escape(m.sig),"</td><td>",profile_source_link(dir,relpath(string(m.file),Base.pkgdir(Vellum)),m.line),"</td></tr>")
        end
        println(io,"</table></html>")
    end
    gpu = joinpath(dir,"gpu.tsv")
    isfile(gpu) && gpu_html(gpu)
end

function cpuprofile(path,frames,stacks,period)
    nodes = Any[]
    function add_node(name,url,line)
        id = length(nodes)+1
        callFrame = (functionName=name, scriptId="0", url=url, lineNumber=line-1, columnNumber=0)
        push!(nodes,(; id,callFrame,children=Int[]))
        return id
    end
    root = add_node("(root)","",0)
    children = Dict{Tuple{Int,Int},Int}()
    samples = map(stacks) do stack
        parent = root
        for frame in stack
            parent = get!(children,(parent,frame)) do
                loc = frames[frame+1]
                id = add_node(loc.name,loc.file,loc.line)
                push!(nodes[parent].children,id)
                id
            end
        end
        parent
    end
    step = round(Int,1e6period)
    open(path,"w") do io
        JSON.print(io,(;nodes,samples,startTime=0,endTime=step*length(samples),
                       timeDeltas=fill(step,length(samples))))
    end
end
