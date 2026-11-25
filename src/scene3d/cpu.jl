"""
    SceneCPU(; faces=256, sample_tests=12_000_000)

Construct the synchronous depth-tested CPU backend. Set an upper bound on
triangles (1–512) and raster sample tests (1–25,000,000) for each submission.
Invalid limits or an exceeded bound raise `ModelError`.
"""
struct SceneCPU <: Backend
    faces::Int
    sample_tests::Int
    function SceneCPU(;faces::Integer=256,sample_tests::Integer=12_000_000)
        1<=faces<=512 && 1<=sample_tests<=25_000_000 || limit("invalid CPU rendering budget")
        new(Int(faces),Int(sample_tests))
    end
end
"""Report the CPU scene profile, picking support and maximum output size."""
Vetra.capabilities(::SceneCPU) = Capabilities(features=(Symbol("scene3d.opaque_triangles"),Symbol("scene3d.pick_id")),
    profiles=(:scene3d_cpu,),max_image_size=(MAX_EDGE,MAX_EDGE))

"""Resolved camera, mesh and material references for one bounded submission."""
struct Plan
    camera::Camera
    objects::Vector{Tuple{UInt32,Mesh,Color8}}
    background::Color8
    source_revision::UInt64
    sample_tests::Int
end

"""Resolve immutable scene resources and check the backend triangle budget. Stale references, mismatched resources and limits raise `ModelError`."""
function prepare_plan(backend,scene)
    camera, objects = resolve_scene(scene,backend.faces)
    return Plan(camera,objects,scene.background,scene.assets.revision,backend.sample_tests)
end

"""Resolve the exact camera and triangle resources for a bounded CPU or GPU submission."""
function resolve_scene(scene::Scene, face_limit::Int)
    camera = resource(scene.assets,scene.camera)
    camera isa Camera || invalid("camera payload mismatch")
    objects = Tuple{UInt32,Mesh,Color8}[]
    count = 0
    for entry in scene.instances
        mesh = resource(scene.assets,entry.mesh)
        material = resource(scene.assets,entry.material)
        mesh isa Mesh && material isa Material || invalid("object payload mismatch")
        count += length(mesh.triangles)
        count<=face_limit || limit("frame triangle budget exceeded")
        push!(objects,(entry.id,mesh,material.color))
    end
    return camera,objects
end

"""Owned color, reciprocal depth and object-ID planes for one target slot."""
struct Planes
    rgba::Vector{UInt8}
    depth::Vector{Float64}
    ids::Vector{UInt32}
end
"""Allocate uninitialized RGBA, Float64 depth and UInt32 ID storage for the admitted pixel count."""
Planes(size::Int) = Planes(Vector{UInt8}(undef,4size),Vector{Float64}(undef,size),Vector{UInt32}(undef,size))

"""Reusable CPU scene surface with two plane sets, clipping scratch, and one pending reservation protected by its lock."""
mutable struct Target <: Surface
    size::Tuple{Int,Int}
    guard::ReentrantLock
    front::Union{Nothing,Planes}
    back::Union{Nothing,Planes}
    positions::Vector{Vec3}
    clip_a::Vector{Vec3}
    clip_b::Vector{Vec3}
    pending::Union{Nothing,Plan}
    sequence::UInt64
    generation::UInt64
    closed::Bool
end
"""
    make_surface(backend::SceneCPU, size)

Allocate a reusable target for a positive integral `(width, height)` with
each edge at most 384 pixels. Invalid dimensions raise `ModelError`.
"""
function Vetra.make_surface(::SceneCPU,size)
    length(size)==2 && all(i -> i isa Integer && 1<=i<=MAX_EDGE,size) || limit("scene target dimensions exceed limits")
    width,height = Int.(size)
    return Target((width,height),ReentrantLock(),Planes(width*height),Planes(width*height),
        Vector{Vec3}(undef,MAX_VERTICES),Vector{Vec3}(undef,MAX_CLIPPED_VERTICES),Vector{Vec3}(undef,MAX_CLIPPED_VERTICES),nothing,0,0,false)
end

"""Submission token for a generation of a CPU target, with completion state and timings."""
mutable struct Ticket <: Submission
    target::Target
    generation::UInt64
    revision::UInt64
    state::Symbol
    prepare_ns::UInt64
    raster_ns::UInt64
    complete_ns::UInt64
end
"""
    submit!(backend::SceneCPU, target, scene::Scene) -> Ticket

Pin the resolved immutable scene in the target’s single pending slot. Call
`wait` to render and publish it. Resource validation, exceeded budgets,
closed targets and an occupied slot raise `ModelError`.
"""
function Vetra.submit!(backend::SceneCPU,target::Target,scene::Scene)
    started = time_ns()
    plan = prepare_plan(backend,scene)
    return lock(target.guard) do
        target.closed && stale("closed scene target")
        target.pending===nothing || stale("scene target already reserved")
        target.sequence<typemax(UInt64) || limit("scene generation exhausted")
        target.sequence += 1
        work = Ticket(target,target.sequence,plan.source_revision,:pending,time_ns()-started,0,0)
        target.pending = plan
        work
    end
end

"""Clip a polygon against one camera-space plane into a second scratch buffer. Return the output vertex count, including zero when fully outside."""
function plane_cut!(out,from,count,plane)
    written = 0
    prev = from[count]
    prev_value = dot3(prev,plane) + plane[4]
    for i in 1:count
        item = from[i]
        value = dot3(item,plane) + plane[4]
        if (value < 0) != (prev_value < 0) && value!=0 && prev_value!=0
            t = prev_value/(prev_value-value)
            written += 1
            out[written] = ntuple(j -> prev[j]+t*(item[j]-prev[j]),3)
        end
        if value>=0
            written += 1
            out[written] = item
        end
        prev,prev_value = item,value
    end
    return written
end

"""Project an admitted camera-space point to fixed-point sample coordinates and reciprocal depth."""
function project(point,width,height,slope_x,slope_y)
    inverse = 1/point[3]
    x = clamp((1+point[1]*inverse/slope_x)*width/2,0,width)
    y = clamp((1-point[2]*inverse/slope_y)*height/2,0,height)
    return (round(Int,x*SUBPIXEL),round(Int,y*SUBPIXEL),inverse)
end

"""Return the signed edge function in Int64 even on a 32-bit host."""
edge(a,b,x,y) = Int64(b[1]-a[1])*(y-a[2])-Int64(b[2]-a[2])*(x-a[1])
"""Choose inclusive top and left edges for adjacent triangles on a downward-growing pixel axis."""
top_left(a,b) = b[2]<a[2] || (b[2]==a[2] && b[1]>a[1])
"""Test a sample against one edge with the caller’s boundary rule."""
inside(value,include_edge) = value>0 || (value==0 && include_edge)
"""Store a complete premultiplied pixel in the prevalidated RGBA plane."""
@inline function pixel!(rgba,pixel,color)
    offset = 4(pixel-1)
    @inbounds for channel in 1:4
        rgba[offset+channel] = color[channel]
    end
end

"""Depth-test one projected triangle and return its bounding-box sample count. Raise `ModelError` when the remaining work budget is exceeded."""
function triangle!(buffers,p,q,r,object,color,width,height,budget)
    area = edge(p,q,r[1],r[2])
    if area<0
        q,r = r,q
        area = -area
    end
    area==0 && return 0
    lx = max(0,cld(min(p[1],q[1],r[1])-HALF_SAMPLE,SUBPIXEL))
    rx = min(width-1,fld(max(p[1],q[1],r[1])-HALF_SAMPLE,SUBPIXEL))
    ty = max(0,cld(min(p[2],q[2],r[2])-HALF_SAMPLE,SUBPIXEL))
    by = min(height-1,fld(max(p[2],q[2],r[2])-HALF_SAMPLE,SUBPIXEL))
    tests = max(0,rx-lx+1)*max(0,by-ty+1)
    tests<=budget || limit("raster sample budget exceeded")
    flags = (top_left(q,r),top_left(r,p),top_left(p,q))
    @inbounds for y in ty:by, x in lx:rx
        sx,sy = x*SUBPIXEL+HALF_SAMPLE,y*SUBPIXEL+HALF_SAMPLE
        a,b,c = edge(q,r,sx,sy),edge(r,p,sx,sy),edge(p,q,sx,sy)
        inside(a,flags[1]) && inside(b,flags[2]) && inside(c,flags[3]) || continue
        invz = (a*p[3]+b*q[3]+c*r[3])/area
        index = y*width+x+1
        old = buffers.depth[index]
        if invz>old || (invz==old && object<buffers.ids[index])
            buffers.depth[index] = invz
            buffers.ids[index] = object
            pixel!(buffers.rgba,index,color)
        end
    end
    return tests
end

"""Render into the unpublished planes and leave the displayed slot untouched. Clip every triangle in camera space before projection. Budget errors propagate."""
function rasterize!(target,plan,buffers)
    width,height = target.size
    camera = plan.camera
    sy = camera.half_height
    sx = sy*width/height
    planes = ((1.,0.,sx,0.),(-1.,0.,sx,0.),(0.,1.,sy,0.),(0.,-1.,sy,0.),
        (0.,0.,1.,-camera.near),(0.,0.,-1.,camera.far))
    fill!(buffers.depth,0)
    fill!(buffers.ids,0)
    for i in eachindex(buffers.ids)
        pixel!(buffers.rgba,i,plan.background)
    end
    budget = plan.sample_tests
    for (id,mesh,color) in plan.objects
        for (i,p) in enumerate(mesh.positions)
            at = sub3(p,camera.eye)
            target.positions[i] = (dot3(at,camera.right),dot3(at,camera.up),dot3(at,camera.forward))
        end
        for (a,b,c) in mesh.triangles
            from,to = target.clip_a,target.clip_b
            from[1],from[2],from[3] = target.positions[a],target.positions[b],target.positions[c]
            count = 3
            for plane in planes
                count = plane_cut!(to,from,count,plane)
                from,to = to,from
                count>=3 || break
            end
            count>=3 || continue
            p = project(from[1],width,height,sx,sy)
            q = project(from[2],width,height,sx,sy)
            for i in 3:count
                r = project(from[i],width,height,sx,sy)
                budget -= triangle!(buffers,p,q,r,id,color,width,height,budget)
                q = r
            end
        end
    end
    return nothing
end

"""
    wait(ticket::Ticket) -> Ticket

Render a pending ticket on the calling thread and publish the planes after
successful completion. Repeating the wait on a completed ticket is safe.
Cancellation, closure or an exceeded work budget raises `ModelError`.
A failed render preserves the previously published planes.
"""
function Base.wait(ticket::Ticket)
    target = ticket.target
    started = time_ns()
    return lock(target.guard) do
        ticket.state===:completed && return ticket
        !target.closed && ticket.state===:pending && target.sequence==ticket.generation && target.pending!==nothing ||
            stale("scene submission unavailable")
        try
            raster_started = time_ns()
            rasterize!(target,target.pending,target.back)
            ticket.raster_ns = time_ns()-raster_started
            target.front,target.back = target.back,target.front
            target.generation = ticket.generation
            ticket.state = :completed
            ticket.complete_ns = time_ns()-started
            ticket
        catch
            ticket.state = :failed
            rethrow()
        finally
            target.pending = nothing
        end
    end
end

"""Return whether a CPU scene ticket successfully completed."""
Vetra.completed(ticket::Ticket) = lock(ticket.target.guard) do
    ticket.state===:completed
end
"""Release a pending scene reservation. Completed or already cancelled tickets are unchanged."""
function Vetra.cancel!(ticket::Ticket)
    target = ticket.target
    return lock(target.guard) do
        if ticket.state===:pending
            target.sequence==ticket.generation && (target.pending=nothing)
            ticket.state = :cancelled
        end
        nothing
    end
end
"""Release both plane sets and scratch, retiring any pending submission. Calling `close` again is safe."""
function Base.close(target::Target)
    lock(target.guard) do
        target.closed = true
        target.pending = target.front = target.back = nothing
        target.positions = target.clip_a = target.clip_b = Vec3[]
    end
    return nothing
end

"""Return the current planes with the target locked. Raise `ModelError` for closed, uncompleted or superseded tickets."""
function published(ticket)
    target = ticket.target
    !target.closed && ticket.state===:completed && target.generation==ticket.generation || stale("scene result is unavailable or stale")
    return target.front::Planes
end

"""
    pick(ticket, x, y) -> Union{Nothing,NamedTuple}

Read the visible object ID and positive camera-space depth at a zero-based
physical pixel coordinate. Background and out-of-range pixels return
`nothing`. An unpublished or superseded ticket raises `ModelError`.
"""
function pick(ticket::Ticket,x::Integer,y::Integer)
    target = ticket.target
    return lock(target.guard) do
        result = published(ticket)
        width,height = target.size
        0<=x<width && 0<=y<height || return nothing
        index = Int(y)*width+Int(x)+1
        id = result.ids[index]
        iszero(id) ? nothing : (id=id,depth=1/result.depth[index])
    end
end

"""
    detached_image(ticket) -> ImageData

Copy completed RGBA pixels into an immutable 2D raster resource. The
capture outlives subsequent renders and target closure. An unpublished
or superseded ticket raises `ModelError`.
"""
function detached_image(ticket::Ticket)
    return lock(ticket.target.guard) do
        result = published(ticket)
        ImageData(Image(ticket.target.size...,result.rgba))
    end
end

"""
    attach!(edit, image::ImageData, destination) -> UInt64

Record the detached image under the edit’s 2D transform, clip and sampling
settings, returning its node ID. `destination` is `(x, y, width, height)`.
Drawing transaction and resource errors propagate.
"""
function attach!(edit,image::ImageData,destination)
    ref = resource!(edit,:image,image)
    draw_image!(edit,ref,destination)
end

"""Return preparation, raster and inclusive wait durations in nanoseconds. Unrecorded phases are zero."""
timings(ticket::Ticket) = lock(ticket.target.guard) do
    (;prepare_ns=ticket.prepare_ns,raster_ns=ticket.raster_ns,complete_ns=ticket.complete_ns)
end
