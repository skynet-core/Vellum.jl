"""
    SceneVulkan(library, vendor, product; faces=256)

Select the Linux Vulkan graphics backend and its exact PCI vendor and
product IDs. Pass an absolute path to the rebuilt Vellum Vulkan bridge.
The constructor validates the path, selector, and triangle limit (1–512).
The native loader and device open only when allocating a surface.
All driver calls belong to the backend's creating thread.
"""
struct SceneVulkan <: Backend
    library::String
    vendor::UInt32
    product::UInt32
    faces::Int
    owner::Int
    function SceneVulkan(library::AbstractString, vendor::Integer, product::Integer; faces::Integer=256)
        Sys.islinux() || throw(ArgumentError("the Vulkan scene adapter requires Linux"))
        isabspath(library) && isfile(library) || throw(ArgumentError("provide an absolute Vulkan bridge path"))
        0 < vendor <= typemax(UInt16) && 0 < product <= typemax(UInt16) ||
            throw(ArgumentError("invalid PCI device selector"))
        1 <= faces <= 512 || limit("invalid Vulkan triangle budget")
        return new(realpath(library),UInt32(vendor),UInt32(product),Int(faces),Threads.threadid())
    end
end

"""Report the Vulkan scene profile, color detachment, depth picking and target size."""
Vellum.capabilities(::SceneVulkan) = Capabilities(
    features=(Symbol("scene3d.opaque_triangles"),Symbol("scene3d.pick_id")),
    profiles=(:scene3d_vulkan,),max_image_size=(MAX_EDGE,MAX_EDGE))

"""
    SceneOverlay(mask::ImageData, annotations::ImageData; background=Material(17, 24, 39))

Freeze a physical viewport mask and a premultiplied sRGB8 annotation layer
for a Vulkan scene target. The mask contributes its alpha channel. The
renderer blends the clipped opaque scene over `background`, then places
the annotations above it. Both images must have the same dimensions
within the scene limit of 384 pixels per axis. A size mismatch or limit
violation raises `ModelError`. The overlay can be reused across targets.
"""
struct SceneOverlay
    size::NTuple{2,Int}
    coverage::FrozenBytes
    annotations::FrozenBytes
    background::UInt32
    function SceneOverlay(mask::ImageData, annotations::ImageData;
                          background::Material=Material(17,24,39))
        size = (mask.width,mask.height)
        size == (annotations.width,annotations.height) || invalid("scene overlay planes have different dimensions")
        all(n -> 1 <= n <= MAX_EDGE,size) || limit("scene overlay dimensions exceed limits")
        coverage = FrozenBytes(@view codeunits(mask.pixels.bytes)[4:4:end])
        r,g,b,a = UInt32.(background.color)
        return new(Int.(size),coverage,annotations.pixels,r | (g << 8) | (b << 16) | (a << 24))
    end
end

"""Native symbols negotiated together before creating a target."""
const NATIVE_OPERATIONS = (:open,:submit,:finish,:read,:pick,:stats,:close)

"""Function pointers whose library lifetime is pinned by the target."""
const VulkanCalls = NamedTuple{NATIVE_OPERATIONS,NTuple{7,Ptr{Cvoid}}}

"""Presentation call addresses pinned by a window target's loaded bridge."""
const SceneWindowCalls = NamedTuple{(:present,:window_stats),NTuple{2,Ptr{Cvoid}}}

"""One interleaved native vertex, with a Float32 position, opaque RGBA8 color, and UInt32 ID."""
struct VulkanVertex
    position::NTuple{3,Float32}
    color::Color8
    id::UInt32
end

"""An owner-thread Vulkan surface with a pending fence and two native publication slots."""
mutable struct VulkanTarget <: Surface
    backend::SceneVulkan
    size::NTuple{2,Int}
    library::Ptr{Cvoid}
    calls::VulkanCalls
    handle::Ptr{Cvoid}
    window_calls::Union{Nothing,SceneWindowCalls}
    coverage::Union{Nothing,FrozenBytes}
    mesh::Vector{Tuple{UInt32,Mesh,Color8}}
    sequence::UInt64
    pending::UInt64
    published::UInt64
    healthy::Bool
end

"""A Vulkan submission generation with its exact projection planes and measured CPU phases."""
mutable struct VulkanTicket <: Submission
    surface::VulkanTarget
    generation::UInt64
    revision::UInt64
    near::Float32
    far::Float32
    state::Symbol
    prepare_ns::UInt64
    submit_ns::UInt64
    complete_ns::UInt64
    gpu_ns::UInt64
end

"""Raise ArgumentError if the caller is outside the backend's driver-owning thread."""
function require_owner(backend::SceneVulkan)
    Threads.threadid() == backend.owner || throw(ArgumentError("use the Vulkan scene on its owner thread"))
    return nothing
end

"""Resolve a required bridge entry point or raise ArgumentError before allocating native resources."""
function scene_call(library::Ptr{Cvoid}, name::Symbol)
    address = Libdl.dlsym_e(library,Symbol("vetra_vulkan_scene_",name))
    address != C_NULL || throw(ArgumentError("rebuild the Vulkan bridge with scene $name support"))
    return address
end

"""
    make_surface(backend::SceneVulkan, (width, height); overlay=nothing)

Allocate two native framebuffer slots with color, depth, and object IDs.
An optional `SceneOverlay` with matching physical dimensions is uploaded
once and composed on the GPU for every completed scene.
Wrong-thread use, missing bridge symbols, or invalid dimensions throw.
Device and driver failures raise an error after releasing partial resources.
"""
Vellum.make_surface(backend::SceneVulkan,size;overlay::Union{Nothing,SceneOverlay}=nothing) =
    open_surface(backend,size,overlay,nothing)

"""
    window_surface(backend::SceneVulkan, size, window::WaylandWindow; overlay=nothing)

Open a scene target that borrows a live Wayland window. Call `submit!` and
`wait` for the first frame, then `VulkanBackend.present!` with the window's
physical extent. The host owns window events and keeps the native handles
alive until the target closes. Size, ownership, device, and exclusive
window borrowing errors propagate.
"""
function window_surface(backend::SceneVulkan,size,window::VulkanBackend.WaylandWindow;
                        overlay::Union{Nothing,SceneOverlay}=nothing)
    return open_surface(backend,size,overlay,window)
end

"""Open a plain or configured target. Validate its extent and ABI before the native call."""
function open_surface(backend::SceneVulkan,size,overlay,window)
    require_owner(backend)
    length(size) == 2 && all(n -> n isa Integer && 1 <= n <= MAX_EDGE,size) ||
        limit("scene target dimensions exceed limits")
    width,height = Int.(size)
    overlay === nothing || overlay.size == (width,height) || invalid("scene overlay does not match target dimensions")
    library = Libdl.dlopen(backend.library)
    try
        calls = NamedTuple{NATIVE_OPERATIONS}(map(name -> scene_call(library,name),NATIVE_OPERATIONS))
        window_calls = window === nothing ? nothing :
            (present=scene_call(library,:present),window_stats=scene_call(library,:window_stats))
        if overlay === nothing && window === nothing
            handle = ccall(calls.open,Ptr{Cvoid},(UInt32,UInt32,UInt32,UInt32),
                           width,height,backend.vendor,backend.product)
        else
            display,surface = window === nothing ? (C_NULL,C_NULL) : (window.display,window.surface)
            coverage,annotations,count,background = overlay === nothing ? (C_NULL,C_NULL,0,0) :
                (overlay.coverage.bytes,overlay.annotations.bytes,width*height,overlay.background)
            open = scene_call(library,:open_configured)
            handle = ccall(open,Ptr{Cvoid},
                (UInt32,UInt32,UInt32,UInt32,Ptr{Cvoid},Ptr{Cvoid},Ptr{UInt8},Ptr{UInt8},Csize_t,UInt32),
                width,height,backend.vendor,backend.product,display,surface,coverage,annotations,count,background)
        end
        handle != C_NULL || error("the requested Vulkan scene surface could not be opened")
        retained_mask = overlay === nothing ? nothing : overlay.coverage
        return VulkanTarget(backend,(width,height),library,calls,handle,window_calls,retained_mask,
                            Tuple{UInt32,Mesh,Color8}[],0,0,0,true)
    catch
        Libdl.dlclose(library)
        rethrow()
    end
end

"""Reject closed or failed surfaces and foreign-thread calls before entering the driver."""
function require_target(target::VulkanTarget)
    require_owner(target.backend)
    target.handle != C_NULL && target.healthy || stale("Vulkan scene surface is unavailable")
    return nothing
end

"""Pass through success flags. A driver failure retires the target; rejected work raises ModelError."""
function scene_status(target::VulkanTarget, status::Cint, operation)
    status == 0 && return nothing
    if status == 3
        target.healthy = false
        error("Vulkan scene $operation failed")
    end
    status == 4 && throw(ArgumentError("use the Vulkan scene on its native owner thread"))
    stale("Vulkan scene $operation is unavailable")
end

"""Pack resident vertices and zero-based indices. Draw larger IDs first to settle exact depth ties."""
function pack_mesh(objects)
    vertices = VulkanVertex[]
    indices = UInt32[]
    for (id,mesh,color) in sort!(copy(objects);by=first,rev=true)
        offset = length(vertices)
        for point in mesh.positions
            push!(vertices,VulkanVertex(map(Float32,point),color,id))
        end
        for triangle in mesh.triangles, index in triangle
            push!(indices,UInt32(offset+index-1))
        end
    end
    return vertices,indices
end

"""Pack a camera in shader order. Reject clip planes that coincide at shader precision."""
function native_camera(camera::Camera, size)
    w,h = size
    values = map(Float32,(camera.eye...,0,camera.right...,0,camera.up...,0,camera.forward...,0,
        camera.half_height*w/h,camera.half_height,camera.near,camera.far))
    values[19] < values[20] || invalid("Vulkan clip planes coincide at Float32 precision")
    return values
end

"""
    submit!(backend::SceneVulkan, target, scene::Scene) -> VulkanTicket

Queue a hardware draw in a separate candidate slot. Reuse resident mesh
bytes when the resolved mesh, object IDs and colors match. Call `wait`
to publish and `cancel!` to discard. A foreign backend, stale resource,
occupied target or exceeded limit raises an error before publication.
"""
function Vellum.submit!(backend::SceneVulkan,target::VulkanTarget,scene::Scene)
    started = time_ns()
    target.backend === backend || invalid("foreign Vulkan scene backend")
    require_target(target)
    target.pending == 0 || stale("Vulkan scene already has a pending draw")
    target.sequence < typemax(UInt64) || limit("scene generation exhausted")
    camera, objects = resolve_scene(scene,backend.faces)
    lens = native_camera(camera,target.size)
    changed = objects != target.mesh
    vertices,indices = changed ? pack_mesh(objects) : (VulkanVertex[],UInt32[])
    prepared = time_ns()
    status = ccall(target.calls.submit,Cint,
        (Ptr{Cvoid},Ref{NTuple{20,Float32}},Ref{Color8},Ptr{VulkanVertex},Csize_t,Ptr{UInt32},Csize_t),
        target.handle,lens,scene.background,vertices,length(vertices),indices,length(indices))
    scene_status(target,status,"submission")
    changed && (target.mesh = objects)
    target.sequence += 1
    target.pending = target.sequence
    return VulkanTicket(target,target.pending,scene.assets.revision,lens[19],lens[20],:pending,
                        prepared-started,time_ns()-prepared,0,0)
end

"""Ordered keys for the fixed native statistics record."""
const VULKAN_STATS = (:renders,:mesh_upload_bytes,:color_read_bytes,:pick_read_bytes,
                      :allocated_bytes,:gpu_ns,:queue_submit_ns,:wait_ns)

"""Statistics keys for the configured target's extra immutable layer transfer."""
const VULKAN_OVERLAY_STATS = (VULKAN_STATS...,:overlay_upload_bytes)

"""Decode one fixed-length native counter record. An unavailable target or failed call raises."""
function scene_statistics(target::VulkanTarget,call::Ptr{Cvoid},::Val{Keys}) where Keys
    count = length(Keys)
    values = Ref{NTuple{count,UInt64}}()
    status = ccall(call,Cint,(Ptr{Cvoid},Ptr{Cvoid},Csize_t),target.handle,values,count)
    scene_status(target,status,"statistics")
    return NamedTuple{Keys}(values[])
end

"""
    vulkan_statistics(target) -> NamedTuple

Report completed publications, mesh and explicit readback bytes, native
allocation, GPU interval, queue-submit time and fence wait. Times are
nanoseconds. Use on the creating thread before closing the surface.
An overlay target also returns its cumulative `overlay_upload_bytes`.
"""
function vulkan_statistics(target::VulkanTarget)
    require_target(target)
    keys = target.coverage === nothing ? Val(VULKAN_STATS) : Val(VULKAN_OVERLAY_STATS)
    return scene_statistics(target,target.calls.stats,keys)
end

"""
    VulkanBackend.present!(target::VulkanTarget, extent) -> Symbol

Offer the most recently published scene to its borrowed Wayland surface.
`extent` is the physical framebuffer size. The GPU fits the image to the
window with letterboxing. Returns `:accepted`, `:busy`, `:unchanged`,
`:resize` or `:suspended`. The host owns retries and event dispatch.
An accepted frame entered the queue. Invalid extent, ownership, closed
target or driver failures raise. This call does not read pixels back.
"""
function VulkanBackend.present!(target::VulkanTarget,extent::Tuple{Integer,Integer})
    require_target(target)
    calls = target.window_calls
    calls === nothing && throw(ArgumentError("scene surface is not bound to a Wayland window"))
    all(0 .<= extent .<= VulkanBackend.MAX_WINDOW_EXTENT) ||
        throw(ArgumentError("Wayland framebuffer extent outside profile"))
    status = ccall(calls.present,Cint,(Ptr{Cvoid},UInt32,UInt32),target.handle,extent[1],extent[2])
    status == 1 && return :busy
    status == 5 && return :unchanged
    status == 6 && return :resize
    status == 7 && return :suspended
    scene_status(target,status,"presentation")
    return :accepted
end

"""
    VulkanBackend.window_statistics(target::VulkanTarget) -> NamedTuple

Report the latest accepted publication ordinal, current swapchain, copied
bytes and queue-present duration in nanoseconds. This reads
counters without waiting on the GPU. Offscreen, closed and wrong-thread
targets raise an error.
"""
function VulkanBackend.window_statistics(target::VulkanTarget)
    require_target(target)
    calls = target.window_calls
    calls === nothing && throw(ArgumentError("scene surface is not bound to a Wayland window"))
    return scene_statistics(target,calls.window_stats,Val(VulkanBackend.WINDOW_KEYS))
end

"""Settle a Vulkan fence without losing its ticket on timeout. Publish only when requested."""
function finish(ticket::VulkanTicket, publish::Bool)
    target = ticket.surface
    require_target(target)
    ticket.state === :pending && target.pending == ticket.generation || stale("Vulkan scene ticket is unavailable")
    started = time_ns()
    status = ccall(target.calls.finish,Cint,(Ptr{Cvoid},UInt32),target.handle,publish)
    ticket.complete_ns = time_ns()-started
    status == 1 && error("Vulkan scene fence timed out")
    scene_status(target,status,"completion")
    target.pending = 0
    if publish
        target.published = ticket.generation
        ticket.state = :completed
        ticket.gpu_ns = vulkan_statistics(target).gpu_ns
    else
        ticket.state = :cancelled
    end
    return ticket
end

"""Wait for and publish the scene. Timeout leaves the pending ticket available for a retry."""
function Base.wait(ticket::VulkanTicket)
    require_owner(ticket.surface.backend)
    return ticket.state === :completed ? ticket : finish(ticket,true)
end

"""Whether this ticket completed successfully, even if another ticket later replaced its pixels."""
Vellum.completed(ticket::VulkanTicket) = ticket.state === :completed

"""Drain a pending render and leave the previously published image intact."""
function Vellum.cancel!(ticket::VulkanTicket)
    require_owner(ticket.surface.backend)
    ticket.state === :pending && finish(ticket,false)
    return nothing
end

"""Require this ticket's published slot and an idle queue before reading its native planes."""
function readable(ticket::VulkanTicket)
    target = ticket.surface
    require_target(target)
    ticket.state === :completed && ticket.generation == target.published && target.pending == 0 ||
        stale("Vulkan scene pixels require the current completed ticket and an idle target")
    return target
end

"""
    pick(ticket::VulkanTicket, x, y)

Read one object ID and one depth value from zero-based physical pixels.
Background, coordinates outside the target, and fully masked pixels
return `nothing`. Annotations do not intercept picking. The depth is in
camera-space units. Reading requires the current completed ticket and an
idle target on its owner thread. Driver errors propagate.
"""
function pick(ticket::VulkanTicket,x::Integer,y::Integer)
    target = readable(ticket)
    width,height = target.size
    0 <= x < width && 0 <= y < height || return nothing
    coverage = target.coverage
    coverage === nothing || coverage[Int(y)*width+Int(x)+1] != 0 || return nothing
    id, depth = Ref{UInt32}(), Ref{Float32}()
    status = ccall(target.calls.pick,Cint,(Ptr{Cvoid},UInt32,UInt32,Ref{UInt32},Ref{Float32}),
                   target.handle,x,y,id,depth)
    scene_status(target,status,"pick")
    iszero(id[]) && return nothing
    near,far = Float64(ticket.near),Float64(ticket.far)
    return (id=id[],depth=far*near/(near+Float64(depth[])*(far-near)))
end

"""Copy the completed (optionally composited) native RGBA plane to ImageData. Stale or busy targets raise."""
function detached_image(ticket::VulkanTicket)
    target = readable(ticket)
    pixels = Vector{UInt8}(undef,4*prod(target.size))
    status = ccall(target.calls.read,Cint,(Ptr{Cvoid},Ptr{UInt8},Csize_t),target.handle,pixels,length(pixels))
    scene_status(target,status,"color readback")
    return ImageData(Image(target.size...,pixels))
end

"""Measured preparation, host queue submission, fence wait and GPU execution in nanoseconds."""
timings(ticket::VulkanTicket) = (;ticket.prepare_ns,ticket.submit_ns,ticket.complete_ns,ticket.gpu_ns)

"""Retire the queue and release both slots on their owner thread. A timed-out close can be retried."""
function Base.close(target::VulkanTarget)
    require_owner(target.backend)
    target.handle == C_NULL && return nothing
    status = ccall(target.calls.close,Cint,(Ptr{Cvoid},),target.handle)
    status == 1 && error("Vulkan scene close timed out")
    scene_status(target,status,"close")
    target.handle = C_NULL
    target.pending = target.published = 0
    target.coverage = target.window_calls = nothing
    empty!(target.mesh)
    Libdl.dlclose(target.library)
    target.library = C_NULL
    return nothing
end
