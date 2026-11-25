"""
Render Vellum vector frames on a desktop OpenGL device. `DesktopBackend`
owns an offscreen GLX context. The extended legacy adapter accepts a native
bridge and PCI selector and can present textures in a host-owned EGL drawable.
Importing this module defers graphics driver loading until a native request.
"""
module OpenGLBackend

import Libdl
import ..Vellum

include("raster_assets.jl")
include("tiled_raster.jl")
include("frame_curves.jl")
include("captured_text.jl")
include("box_blur.jl")

"""Maximum width and height in physical pixels negotiated with an extended bridge."""
const MAX_EXTENT = (1920,1080)

"""Upper bound in bytes for one packed plan and the resident record buffer."""
const RECORD_BYTES = RasterPages.RECORD_BYTES

"""Maximum duration in nanoseconds of a native wait or teardown drain."""
const WAIT_NS = UInt64(1_000_000_000)

"""Exact operation requirements admitted by the packed shader profile."""
const FEATURES = (:fill_path,:stroke_path,:clear,:group,:float64,:clip,:curve_paths,
    :gradient,:multiply,:text,:text_captured_glyphs_v1,:effect_box_blur_v1,:image,:linear_sampling)

"""High-water mark for process-local fence token namespaces."""
const EPOCH = Threads.Atomic{UInt32}(0)

"""Entry points exported by the fixed-size bridge ABI."""
const ENTRY_POINTS = (:open, :submit, :wait, :abandon, :pixels, :stats, :close)

"""Native status for a target whose context could not be made current."""
const CONTEXT_UNAVAILABLE = Cint(5)

"""Named fields in the ABI's 26-word diagnostics record."""
const STATS_KEYS = (:revision,:token,:uploaded,:dispatches,:submitted,:completed,:readbacks,
    :fences,:healthy,:program,:buffer,:texture,:first_word,:uploaded_words,:upload_kind,
    :enqueue_ns,:wait_ns,:committed_words,
    :damage_x,:damage_y,:damage_width,:damage_height,:scratch_bytes,:child_buffer,
    :horizontal_buffer,:effect_passes)

"""
    bridge_profile(library, transport) -> NamedTuple

Read optional physical extent and blur radius markers without opening a device.
Older or unloadable libraries keep the original physical profile and normal
startup error handling. The query temporarily opens and closes the library.
"""
function bridge_profile(library::String,transport::Symbol)
    extent, radius = RasterPages.COMPACT_EXTENT, BoxBlurPlan.LEGACY_RADIUS
    handle = Libdl.dlopen_e(library)
    handle == C_NULL && return (;extent,radius)
    try
        name = transport === :vulkan ? :vetra_vulkan_target_extent : :vetra_vector_target_extent
        entry = Libdl.dlsym_e(handle,name)
        if entry != C_NULL
            bits = ccall(entry,UInt32,())
            candidate = (Int(bits>>16),Int(bits&0xffff))
            candidate == MAX_EXTENT && (extent = candidate)
        end
        name = transport === :vulkan ? :vetra_vulkan_box_blur_radius : :vetra_vector_box_blur_radius
        entry = Libdl.dlsym_e(handle,name)
        entry == C_NULL || (radius = min(Int(ccall(entry,UInt32,())),BoxBlurPlan.MAX_RADIUS))
        return (;extent,radius)
    finally
        Libdl.dlclose(handle)
    end
end

"""
    check_stream_bridge(path, pool)

Require the Vulkan stream ABI and its expected active-page limit without
opening a GPU. A missing or incompatible bridge raises `ArgumentError`.
"""
function check_stream_bridge(path,pool)
    library = Libdl.dlopen_e(path)
    library != C_NULL || throw(ArgumentError("cannot load the Vulkan source stream bridge"))
    try
        layered = pool === :streamed_layers
        entry = raster_entry(library,:vulkan,layered ? :layer_stream_capacity : :stream_capacity)
        ccall(entry,Cuint,()) == (layered ? RasterPages.LAYER_ACTIVE : RasterPages.STREAM_ACTIVE) ||
            throw(ArgumentError("incompatible Vulkan source stream capacity"))
    finally
        Libdl.dlclose(library)
    end
    return nothing
end

"""
    NativeBackend{Transport}(library, vendor, product; raster_registry=nothing, source_pool=:standard)

Create a device selector on the owning Julia thread. Supply the absolute
shared-library path and unsigned 16-bit nonzero PCI IDs. The selector can
create independent surfaces within the bridge's four-target process limit.
Supply an `ImageTiles` raster resolver to use immutable tiled source revisions.
Vulkan can opt into `source_pool=:streamed_8k` or `:streamed_layers`
on a compatible bridge.
The selector reads the library's physical profile without opening a GPU
device. The constructor throws `ArgumentError` for invalid arguments.
"""
mutable struct NativeBackend{Transport} <: Vellum.Backend
    library::String
    vendor::UInt32
    product::UInt32
    owner::Int
    raster_registry::Union{Nothing,Vellum.ImageTiles.AbstractRasterResolver}
    extent::NTuple{2,Int}
    source_pool::Symbol
    blur_radius::Int

    function NativeBackend{Transport}(library::AbstractString, vendor::Integer, product::Integer;
        raster_registry::Union{Nothing,Vellum.ImageTiles.AbstractRasterResolver}=nothing,
        source_pool::Symbol=:standard) where Transport
        Transport in (:opengl, :vulkan) || throw(ArgumentError("unknown native vector transport"))
        Sys.islinux() || throw(ArgumentError("the offscreen native vector adapter requires Linux"))
        isabspath(library) && isfile(library) ||
            throw(ArgumentError("provide the absolute vector bridge path"))
        0 < vendor <= typemax(UInt16) && 0 < product <= typemax(UInt16) ||
            throw(ArgumentError("invalid PCI selector"))
        path = realpath(library)
        profile = bridge_profile(path,Transport)
        if source_pool !== :standard
            Transport === :vulkan && source_pool in (:streamed_8k,:streamed_layers) ||
                throw(ArgumentError("choose :standard or a supported Vulkan source stream"))
            check_stream_bridge(path,source_pool)
        end
        return new{Transport}(path,UInt32(vendor),UInt32(product),Threads.threadid(),
                              raster_registry,profile.extent,source_pool,profile.radius)
    end
end

"""
    Backend(library, vendor, product; raster_registry=nothing)

Select the OpenGL device by exact PCI IDs and an absolute bridge path.
Optionally configure the source revision resolver for tiled images. A
wrong path, invalid selector or unsupported operating system throws.
"""
const Backend = NativeBackend{:opengl}

"""
    Session

Own the library, native handle and resolved entry points of a live context.
The adapter creates and releases sessions on the backend's owner thread.
"""
struct Session
    library::Ptr{Cvoid}
    handle::Ptr{Cvoid}
    entry::NamedTuple{ENTRY_POINTS,NTuple{7,Ptr{Cvoid}}}
end

include("async_source.jl")

"""
    Token

Track one native submission and the immutable Frame staged for it. The
owning surface keeps the token until completion, cancellation or failure.
"""
mutable struct Token{S} <: Vellum.Submission
    surface::S
    frame::Vellum.Frame
    assets::RasterPages.Resident
    value::UInt64
    state::Symbol
end

"""
    NativeSurface

A resident target with fixed render extent. Initialization opens an offscreen
session or attaches the native session to the host window. The adapter
retains the last completed Frame until the next fence completes. Close
initialized targets on their owner thread. The host also retains one
bounded cache of physical geometry from the latest submitted packet.
Each surface keeps private owner-thread packing scratch until native
teardown succeeds.
"""
mutable struct NativeSurface{B<:NativeBackend} <: Vellum.Surface
    backend::B
    size::NTuple{2,Int}
    session::Union{Nothing,Session}
    committed::Union{Nothing,Vellum.Frame}
    assets::RasterPages.Resident
    shapes::FrameCurves.ShapeCache
    """Exclusive intermediate tables for synchronous native submissions."""
    workspace::Union{Nothing,FrameCurves.Workspace}
    item::Union{Nothing,Token{NativeSurface{B}}}
    sources::Union{Nothing,SourceQueue}
    preparing::Bool
    closed::Bool
    valid::Bool
end

"""Resident OpenGL render surface, with optional host window drawing."""
const Surface = NativeSurface{Backend}

"""
    require_owner(backend) -> nothing

Verify use on the thread that created the backend. Throw `ArgumentError`
before native access on a different thread.
"""
function require_owner(backend::NativeBackend)
    Threads.threadid() == backend.owner || throw(ArgumentError("wrong native renderer owner thread"))
    return nothing
end

"""
    next_epoch() -> UInt32

Reserve a unique fence-token high word. Throw `ArgumentError` on exhaustion.
"""
function next_epoch()
    while true
        old = EPOCH[]
        old != typemax(UInt32) || throw(ArgumentError("GPU session epochs exhausted"))
        new = old + UInt32(1)
        Threads.atomic_cas!(EPOCH,old,new) == old && return new
    end
end

"""
    Vellum.capabilities(backend::NativeBackend) -> Vellum.Capabilities

Return the vector, raster and text capability set. A configured resolver
adds paged sources and their admitted storage formats. `target_extent`
reports the separately negotiated maximum physical target.
"""
function Vellum.capabilities(backend::NativeBackend)
    backend.raster_registry === nothing &&
        return Vellum.Capabilities(features=FEATURES,max_image_size=target_extent(backend))
    return Vellum.Capabilities(features=(FEATURES...,:image_provider_revision_v1,
        Symbol("image_storage.tiled"),:linear_srgb_image),formats=(:rgba8,:bgra8,:rgb8,:bgr8,:gray8),
        max_image_size=(RasterPages.SOURCE_SIDE,RasterPages.SOURCE_SIDE))
end

"""
    target_extent(backend) -> NTuple{2,Int}

Return the maximum physical `(width, height)` of the bridge profile.
This is separate from logical raster-source limits. No GPU work occurs.
Hardware and frame-work checks still apply when initializing a target.
"""
target_extent(backend::NativeBackend) = backend.extent

"""
    box_blur_radius(backend) -> Int

Return the largest physical BoxBlur radius per axis for this backend's
bridge, without opening a device or reading pixels. Bridges without a
radius query use the original 16-pixel limit.
"""
box_blur_radius(backend::NativeBackend) = backend.blur_radius

"""
    validate_nodes(nodes, [depth]) -> nothing

Check captured glyph counts and group depth. Throw `ArgumentError` for
deferred glyphs, ordered fallback faces, or overbudget runs or nesting.
"""
function validate_nodes(nodes, depth::Int=0)
    for node in nodes
        operation = node.operation
        if operation isa Vellum.TextRun
            0 < length(operation.glyphs) <= 32 && isempty(operation.fallback_fonts) ||
                throw(ArgumentError("capture up to 32 glyphs from one face"))
        elseif operation isa Vellum.CompositeGroup
            depth < 2 || throw(ArgumentError("Native group depth exceeds two"))
            validate_nodes(operation.nodes, depth + 1)
        end
    end
    return nothing
end

"""
    Vellum.prepare_retention(backend::NativeBackend, frame) -> nothing

Validate frame revision and resource count from any Julia thread. The prepared Frame
owns its font and dense image bytes. For tiled sources, return exact pins
from the configured revision resolver. Unsupported resources or unavailable
revisions raise before acquiring a native target.
"""
function Vellum.prepare_retention(backend::NativeBackend, frame::Vellum.Frame)
    0 < frame.revision <= 2^48 && length(frame.nodes) <= FrameCurves.MAX_COMMANDS ||
        throw(ArgumentError("frame revision or count is outside the native vector profile"))
    length(frame.resources) <= 16 &&
        all(record -> record.payload isa Union{Vellum.FontData,Vellum.ImageData,Vellum.RasterReference},frame.resources) ||
        throw(ArgumentError("a maximum of 16 font and image resources are supported"))
    validate_nodes(frame.nodes)
    BoxBlurPlan.validate(frame.nodes)
    any(record -> record.payload isa Vellum.RasterReference,frame.resources) || return nothing
    registry = backend.raster_registry
    registry === nothing && Vellum.model_error(:resource_unavailable,"GPU renderer has no raster resolver")
    return Vellum.ImageTiles.retain_frame(registry,frame)
end

"""
    pack_vectors(frame, size, dense, resident, halo; streamed, layered, shared, shapes, workspace)

Compute paged source footprints and encode already outlined vector
and image descriptors. Return drawing words, resulting slots and the geometry cache.
The physical target can be up to 1920 × 1080. Throws for unsupported
geometry or nonfinite and overbudget records. Native admission also
bounds coordinates and estimated shader work.
An optional exclusive `workspace` reuses intermediate tables. The returned
packet owns its words.
"""
function pack_vectors(frame::Vellum.Frame,size::NTuple{2,Int},dense,resident,halo;
                      streamed=false,layered=false,shared=nothing,shapes=FrameCurves.EMPTY_SHAPES,
                      workspace=nothing,limits=FrameCurves.BRIDGE_LIMITS)
    resolved = workspace === nothing ? Int[] : workspace.page_slots
    width, height = size
    1 <= width <= MAX_EXTENT[1] && 1 <= height <= MAX_EXTENT[2] ||
        throw(ArgumentError("invalid physical target size"))
    viewport = Vellum.Transform2D(width/frame.size[1],0,0,height/frame.size[2])
    capacity = streamed ? (layered ? RasterPages.LAYER_ACTIVE : RasterPages.STREAM_ACTIVE) : RasterPages.page_capacity(size)
    data = workspace === nothing ? FrameCurves.Packing(capacity,shared,shapes;limits) :
        FrameCurves.Packing(workspace,capacity,shared,shapes;limits)
    FrameCurves.encode_nodes!(data,frame.nodes,viewport,frame,dense,size,halo)
    selection = data.page_selection
    assets = RasterPages.allocate_slots!(selection,resident,dense,resolved;streamed)
    paged = streamed || selection.has_paged_draws
    magic = streamed ? (layered ? RasterPages.LAYER_MAGIC : RasterPages.STREAM_MAGIC) :
        paged ? RasterPages.MAGIC : FrameCurves.MAGIC
    header = Float64[magic,width,height,frame.revision,
        length(data.commands)÷FrameCurves.COMMAND,
        length(data.shapes)÷FrameCurves.SHAPE,length(data.contours)÷FrameCurves.CONTOUR,
        length(data.points)÷2,length(data.stops)÷FrameCurves.STOP,4]
    words = vcat(header,data.commands,data.shapes,data.contours,data.points,data.stops)
    paged && append!(words,
        (length(data.rasters)÷RasterAssets.RECORD_WORDS,length(selection.ordered)))
    append!(words,data.rasters)
    sizeof(words)+sizeof(Float64)*RasterPages.PAGE_WORDS*length(selection.ordered) <= limits.bytes ||
        throw(ArgumentError("packed native vector record budget exceeded"))
    RasterPages.append_pages!(words,selection,resolved)
    all(isfinite,words) ||
        throw(ArgumentError("packed native vector record budget exceeded"))
    return (;words,assets,shapes=data.retained_shapes)
end

"""
    pack_frame(frame, size, [resident]; streamed=false, layered=false, shared=nothing, shapes, blur_radius, workspace=nothing)

Outline captured text and pack vector, dense, tiled and BoxBlur work at a physical size. Preserve
overlapping source slots. Streamed packets isolate replacement source slots.
Use the backend's negotiated `blur_radius`; direct callers default to 16.
Read the optional previous shape cache, and return the new cache with the packet.
Invalid geometry or exceeded limits throw before pixel-region reads.
Use a `workspace` for one pack at a time. Packing resets it at the start
of each call. Each output owns its words and shape cache.
"""
function pack_frame(frame::Vellum.Frame,size,resident::RasterPages.Resident=RasterPages.EMPTY;
                    streamed=false,layered=false,shared=nothing,
                    shapes=streamed ? nothing : FrameCurves.EMPTY_SHAPES,blur_radius=BoxBlurPlan.LEGACY_RADIUS,
                    workspace=nothing,limits=FrameCurves.BRIDGE_LIMITS)
    try
        dense = RasterAssets.select_slots(frame,resident.dense;max_side=limits.image_side)
        pack = (derived,extent,halo) -> pack_vectors(derived,extent,dense,resident,halo;streamed,layered,shared,shapes,workspace,limits)
        outline = GLText.outline_frame(frame,limits)
        return limits === FrameCurves.QUEUE_LIMITS ? BoxBlurPlan.pack_queue(pack,outline,size,blur_radius) :
            BoxBlurPlan.pack(pack,outline,size,blur_radius)
    catch
        workspace === nothing || empty!(workspace.page_slots)
        rethrow()
    end
end

"""Select the command and memory limits understood by a prepared draw's native provider."""
packet_limits(::Vellum.Backend) = FrameCurves.BRIDGE_LIMITS

"""
    pack_frame(plan::Vellum.PreparedFrame, size, [resident]; streamed=false, layered=false, shapes, blur_radius, workspace=nothing)

Keep exact execution pins while lowering the frame's optional validated
sparse page indices. Close the pins after packing, including on failure.
Generic or unindexed providers keep per-revision cache keys.
Optional exclusive `workspace` has the same ownership and limits as the Frame overload.
"""
function pack_frame(plan::Vellum.PreparedFrame,size,resident::RasterPages.Resident=RasterPages.EMPTY;
                     streamed=false,layered=false,shapes=streamed ? nothing : FrameCurves.EMPTY_SHAPES,
                     blur_radius=BoxBlurPlan.LEGACY_RADIUS,workspace=nothing)
    try
        limits = packet_limits(plan.backend)
        plan.retention isa Vellum.ImageTiles.RevisionLease ||
            return pack_frame(plan.frame,size,resident;streamed,layered,shapes,blur_radius,workspace,limits)
        pins = Vellum.execution_retention(plan)
        try
            shared = Vellum.ImageTiles.shared_tile_sources(pins,RasterPages.SIDE)
            return pack_frame(plan.frame,size,resident;streamed,layered,shared,shapes,blur_radius,workspace,limits)
        finally
            close(pins)
        end
    catch
        workspace === nothing || empty!(workspace.page_slots)
        rethrow()
    end
end

"""
    Vellum.make_surface(backend::NativeBackend, size) -> Surface

Create a logical target for a physical pixel extent. Throws for wrong
thread or invalid extents. Initial execute opens the
device so failed plans cannot reserve a native slot.
"""
function Vellum.make_surface(backend::NativeBackend, size)
    require_owner(backend)
    dimensions = Vellum.checked_dimensions(size...)
    all(dimensions .<= target_extent(backend)) ||
        throw(ArgumentError("Native target exceeds maximum extent"))
    return NativeSurface(backend,dimensions,nothing,nothing,RasterPages.EMPTY,FrameCurves.EMPTY_SHAPES,
        FrameCurves.Workspace(),
        nothing,nothing,false,false,false)
end

"""
    require_plan(backend, surface, plan) -> nothing

Require an owner-thread, open logical target and a plan for the same
backend. Violations raise `ArgumentError` before packing or native work.
"""
function require_plan(backend::NativeBackend, surface::NativeSurface, plan::Vellum.PreparedFrame)
    require_owner(backend)
    surface.backend === backend && plan.backend === backend && !surface.closed && !surface.preparing ||
        throw(ArgumentError("closed or preparing surface, or foreign backend"))
    return nothing
end

"""
    require_session(surface) -> Session

Get an initialized session on its owner thread. Throws before initialization
or after close. Quarantined sessions remain reachable for teardown.
"""
function require_session(surface::NativeSurface)
    require_owner(surface.backend)
    session = surface.session
    !surface.closed && session !== nothing || throw(ArgumentError("surface is not initialized"))
    return session
end

"""
    require_context_status(status) -> nothing

Throw `ArgumentError` when native work could not acquire its owner-thread
context. The operation leaves the current Frame and pending fence intact.
The caller may retry on the owner thread with its required context binding.
"""
function require_context_status(status::Cint)
    status == CONTEXT_UNAVAILABLE &&
        throw(ArgumentError("the target OpenGL context is unavailable on this thread"))
    return nothing
end

"""
    raster_statistics(surface) -> NamedTuple

Return cumulative raster asset bytes uploaded and the number of source
pages in the last completed frame. Counters exclude geometry packets,
GPU readbacks and Vulkan staging. Throws if the surface is closed, used
from another thread, uninitialized, or backed by an older bridge.
"""
function raster_statistics(surface::NativeSurface{NativeBackend{Transport}}) where Transport
    session = require_session(surface)
    call = raster_entry(session.library,Transport,:raster_stats)
    value = Ref{UInt64}(0)
    status = ccall(call,Cint,(Ptr{Cvoid},Ref{UInt64}),session.handle,value)
    status == 0 || error("native raster statistics failed with status $status")
    return (;uploaded_bytes=value[],resident_pages=length(surface.assets.pages))
end

"""
    raster_entry(library, transport, operation) -> Ptr{Cvoid}

Resolve a versioned raster entry from the selected bridge. An older vector
library raises `ArgumentError` with a rebuild instruction.
"""
function raster_entry(library, transport, operation)
    prefix = transport === :vulkan ? "vetra_vulkan_" : "vetra_vector_"
    entry = Libdl.dlsym_e(library,Symbol(prefix,operation))
    entry != C_NULL || throw(ArgumentError("rebuild the native $transport bridge for $operation"))
    return entry
end

"""
    open_session(backend, words, staged; window=nothing, current_context=false) -> Session

Open the selected hardware and finish the initial compute dispatch. Throw
when the library, packed plan, GPU selector or initial render fails. The
native startup owns a copy of the supplied words. The Vulkan native entry
point can borrow a `(wl_display, wl_surface)` pointer pair from the host.
OpenGL can borrow the host's current desktop EGL context. Any initial
source slots are uploaded while their owned staging storage is preserved.
The streamed Vulkan profile opens a provisional target and leaves its
first source transfer and render to `initialize_stream!`.
"""
function open_session(backend::NativeBackend{Transport}, words::Vector{Float64}, staged::Vector{RasterAssets.StagedUpload};
                      window::Union{Nothing,Tuple{Ptr{Cvoid},Ptr{Cvoid}}}=nothing,
                      current_context::Bool=false) where Transport
    lib = Libdl.dlopen(backend.library)
    try
        prefix = Transport === :vulkan ? "vetra_vulkan_" : "vetra_vector_"
        entry = NamedTuple{ENTRY_POINTS}(map(name -> Libdl.dlsym(lib,Symbol(prefix,name)),
            ENTRY_POINTS))
        handle = if backend.source_pool !== :standard
            call = raster_entry(lib,Transport,:open_stream)
            display, drawable = window === nothing ? (C_NULL,C_NULL) : window
            ccall(call,Ptr{Cvoid},(Ptr{Cdouble},Csize_t,UInt32,UInt32,UInt32,Ptr{Cvoid},Ptr{Cvoid}),
                words,length(words),backend.vendor,backend.product,next_epoch(),display,drawable)
        elseif !isempty(staged)
            call = raster_entry(lib,Transport,:open_raster)
            GC.@preserve staged begin
                uploads = RasterAssets.describe(staged)
                if Transport === :vulkan
                    display, drawable = window === nothing ? (C_NULL,C_NULL) : window
                    ccall(call,Ptr{Cvoid},(Ptr{Cdouble},Csize_t,UInt32,UInt32,UInt32,Ptr{Cvoid},Ptr{Cvoid},Ptr{RasterAssets.Upload},Csize_t),
                        words,length(words),backend.vendor,backend.product,next_epoch(),display,drawable,uploads,length(uploads))
                else
                    ccall(call,Ptr{Cvoid},(Ptr{Cdouble},Csize_t,UInt32,UInt32,UInt32,Cuchar,Ptr{RasterAssets.Upload},Csize_t),
                        words,length(words),backend.vendor,backend.product,next_epoch(),current_context,uploads,length(uploads))
                end
            end
        elseif isnothing(window)
            current_context && Transport !== :opengl && throw(ArgumentError("only OpenGL borrows the current EGL context"))
            open = current_context ? Libdl.dlsym(lib,:vetra_vector_open_window) : entry.open
            ccall(open,Ptr{Cvoid},(Ptr{Cdouble},Csize_t,UInt32,UInt32,UInt32),
                words,length(words),backend.vendor,backend.product,next_epoch())
        else
            Transport === :vulkan || throw(ArgumentError("Wayland binding requires the Vulkan adapter"))
            bind = Libdl.dlsym(lib,:vetra_vulkan_open_wayland)
            ccall(bind,Ptr{Cvoid},(Ptr{Cdouble},Csize_t,UInt32,UInt32,UInt32,Ptr{Cvoid},Ptr{Cvoid}),
                words,length(words),backend.vendor,backend.product,next_epoch(),window[1],window[2])
        end
        handle != C_NULL || error("native vector startup rejected the target, device or open-surface limit")
        return Session(lib,handle,entry)
    catch
        Libdl.dlclose(lib)
        rethrow()
    end
end

"""
    initialize!(surface, backend, plan; host...) -> Surface

Pack the first frame and open the native target, forwarding an optional
host-window binding. Publish the frame and resident asset slots only
after startup finishes. Planning and native errors propagate.
"""
function initialize!(surface::NativeSurface,backend::NativeBackend,plan::Vellum.PreparedFrame;host...)
    surface.preparing = true
    try
        if backend.source_pool !== :standard
            return initialize_stream!(surface,backend,plan;host...)
        end
        packet = stage_frame(plan,surface.size,RasterPages.EMPTY,backend.raster_registry;
                             blur_radius=box_blur_radius(backend),workspace=surface.workspace)
        surface.session = open_session(backend,packet.words,packet.uploads;host...)
        surface.committed = plan.frame
        surface.shapes = packet.shapes
        capacity = RasterPages.page_capacity(surface.size)
        surface.assets = RasterPages.with_cache(packet.assets,retains_inactive_pages(surface.session,backend,capacity))
        surface.valid = true
        return surface
    finally
        surface.preparing = false
    end
end

"""
    retains_inactive_pages(session, backend, capacity) -> Bool

Check the installed bridge's page-cache ABI. Libraries that predate this
entry continue to use their active-frame page residency.
"""
function retains_inactive_pages(session::Session,::NativeBackend{Transport},capacity) where Transport
    name = Transport === :vulkan ? :vetra_vulkan_page_cache_slots : :vetra_vector_page_cache_slots
    entry = Libdl.dlsym_e(session.library,name)
    return entry != C_NULL && ccall(entry,Cuint,()) >= capacity
end

"""
    page_cache_statistics(surface) -> NamedTuple

Count completed-frame active, cached and inactive pages and report the
fixed capacity of the device cache. The streamed profile reports its
physical slot count, including slots reserved for replacement pages.
`retains_inactive` identifies the
installed bridge's behavior. No GPU work or provider access occurs.
Throws for closed, uninitialized or wrong-thread use.
"""
function page_cache_statistics(surface::NativeSurface)
    require_session(surface)
    resident = surface.assets
    active,cached = length(resident.pages),length(resident.cached)
    capacity = surface.backend.source_pool === :standard ? RasterPages.page_capacity(surface.size) : RasterPages.STREAM_SLOTS
    return (;active,cached,inactive=cached-active,capacity,
             retains_inactive=resident.retain_inactive)
end

"""Maximum host drawable dimensions for one OpenGL back-buffer draw, in pixels."""
const MAX_WINDOW_EXTENT = (4096, 2160)

"""Ordered fields in the bridge's back-buffer draw diagnostics record."""
const WINDOW_STATS_KEYS = (:draws, :revision, :width, :height, :transfer_bytes, :enqueue_ns, :fence_tracked)

"""
    window_surface(frame, backend::Backend; size=frame.size) -> Surface

Render the first frame into a texture in the host's current EGL window context.
Requires OpenGL 4.4 core and a double-buffered drawable on the backend's PCI
device. `size` is the fixed render image extent, bounded by [`target_extent`](@ref). Keep
the same context and its original draw and read surfaces current during GPU
calls and close the result before destroying them. Enter with valid GL state
and without active transform feedback. The application owns the event loop.
Invalid frames, wrong-thread use and unsupported contexts throw.
"""
function window_surface(frame::Vellum.Frame, backend::Backend; size=frame.size)
    surface = Vellum.make_surface(backend,size)
    plan = Vellum.prepare(backend,frame)
    try
        require_plan(backend,surface,plan)
        return initialize!(surface,backend,plan;current_context=true)
    finally
        close(plan)
    end
end

"""
    draw_window!(surface, extent; refresh=false) -> Symbol

Draw the latest completed image into the host's current OpenGL back buffer.
Pass the physical framebuffer size as `extent`. The default draw buffer must
select a single-sample back buffer. The blit preserves aspect ratio and stage
orientation. Swap the window buffers after `:drawn`. After `:transition`,
swap and retry at the host framebuffer extent. EGL still reported the old
drawable size for that draw. A pending render or blit returns `:busy`.
The same revision and size return `:unchanged`.
Supply `refresh=true` when the host explicitly needs the image redrawn, such
as after writing into the back buffer. An empty extent returns `:suspended`.
Invalid or temporarily noncurrent surfaces throw `ArgumentError`. Driver
failure quarantines the surface and throws. No CPU pixel readback occurs.
"""
function draw_window!(surface::Surface, extent::Tuple{Integer,Integer}; refresh::Bool=false)
    all(0 .<= extent .<= MAX_WINDOW_EXTENT) || throw(ArgumentError("OpenGL window extent outside profile"))
    session = require_session(surface)
    call = Libdl.dlsym(session.library,:vetra_vector_draw_window)
    status = ccall(call,Cint,(Ptr{Cvoid},Cint,Cint,Cuchar),session.handle,extent[1],extent[2],refresh)
    require_context_status(status)
    status == 0 && return :drawn
    status == 1 && return :busy
    status == 2 && throw(ArgumentError("an OpenGL window with a single-sample back buffer is required"))
    status == 6 && return :unchanged
    status == 7 && return :suspended
    status == 8 && return :transition
    if status == 3
        surface.valid = false
        invalidate_sources!(surface.sources)
    end
    error("native OpenGL window draw failed with status $status")
end

"""
    window_statistics(surface) -> NamedTuple

Return completed render revision written to the back buffer, staged draw
count, dimensions, cumulative destination bytes and the latest enqueue time.
`fence_tracked` records an owned blit fence. A draw is separate from the host's
swap and its compositor delivery. This call performs no GPU work. Throws for
offscreen, closed, uninitialized or wrong-thread use.
"""
function window_statistics(surface::Surface)
    session = require_session(surface)
    call = Libdl.dlsym(session.library,:vetra_vector_window_stats)
    output = Vector{UInt64}(undef,length(WINDOW_STATS_KEYS))
    status = ccall(call,Cint,(Ptr{Cvoid},Ptr{UInt64},Csize_t),session.handle,output,length(output))
    status == 0 || throw(ArgumentError("surface does not borrow an OpenGL window context"))
    return NamedTuple{WINDOW_STATS_KEYS}(Tuple(output))
end

"""
    Vellum.execute!(backend::NativeBackend, surface::NativeSurface, plan) -> Surface

Render the initial Frame or block for a subsequent accepted revision.
Reuses the initialized target and never captures pixels. Errors from
admission, ownership, or device work propagate. A timed-out edit remains
owned by the target until it is drained.
"""
function Vellum.execute!(backend::NativeBackend, surface::NativeSurface, plan::Vellum.PreparedFrame)
    require_plan(backend,surface,plan)
    if surface.session === nothing
        initialize!(surface,backend,plan)
    else
        wait(Vellum.submit!(backend,surface,plan))
    end
    return surface
end

"""
    Vellum.submit!(backend::NativeBackend, surface::NativeSurface, plan) -> Token

Queue one new Frame on an initialized target. The frame must be the exact
next revision of the same logical Canvas. Throws for busy, quarantined,
foreign or out-of-profile work. The prior frame remains committed while
the token owns the staged frame and fence.
"""
function Vellum.submit!(backend::NativeBackend,surface::NativeSurface,plan::Vellum.PreparedFrame)
    require_plan(backend,surface,plan)
    require_session(surface)
    surface.valid && surface.item === nothing || throw(ArgumentError("target is busy or quarantined"))
    before = surface.committed::Vellum.Frame
    after = plan.frame
    after.canvas === before.canvas && after.revision == before.revision+1 ||
        throw(ArgumentError("expected a consecutive revision of the same Canvas"))
    surface.preparing = true
    try
        if backend.source_pool !== :standard
            return submit_stream!(surface,backend,plan,before.revision)
        end
        packet = stage_frame(plan,surface.size,surface.assets,backend.raster_registry;
                             shapes=surface.shapes,blur_radius=box_blur_radius(backend),workspace=surface.workspace)
        item = enqueue_staged!(backend,surface,after,before.revision,packet)
        invalidate_sources!(surface.sources)
        return item
    finally
        surface.preparing = false
    end
end

"""
    enqueue_staged!(backend, surface, frame, base, packet; latest=false) -> Token

Upload owned staging bytes and enqueue one GPU fence on the native owner.
The default entry requires consecutive revisions. The latest entry may
skip revisions against the same exact base. Native errors propagate.
"""
function enqueue_staged!(backend::NativeBackend{Transport},surface,frame,base,packet;latest=false) where Transport
    session = require_session(surface)
    words = packet.words
    staged = packet.uploads
    item = Token(surface,frame,packet.assets,UInt64(0),:pending)
    token = Ref{UInt64}(0)
    status = GC.@preserve staged begin
        if !latest && isempty(staged)
            ccall(session.entry.submit,Cint,(Ptr{Cvoid},Ptr{Cdouble},Csize_t,UInt64,Ref{UInt64}),
                session.handle,words,length(words),base,token)
        else
            call = raster_entry(session.library,Transport,latest ? :submit_latest : :submit_raster)
            uploads = RasterAssets.describe(staged)
            ccall(call,Cint,(Ptr{Cvoid},Ptr{Cdouble},Csize_t,UInt64,Ref{UInt64},Ptr{RasterAssets.Upload},Csize_t),
                session.handle,words,length(words),base,token,uploads,length(uploads))
        end
    end
    require_context_status(status)
    if status == 3
        surface.valid = false
        invalidate_sources!(surface.sources)
    end
    status == 2 && throw(ArgumentError("native vector work is outside the profile"))
    status == 0 || error("native vector submission failed with status $status")
    item.value = token[]
    surface.item = item
    surface.shapes = packet.shapes
    return item
end

"""
    request_frame!(surface, frame::Frame) -> Preparation

Queue the newest snapshot for background packing and source reads. The
surface must be initialized on this thread. Start Julia with both thread
pools, for example `--threads=2,1`. Keep the source publication or Frame
lease available until the worker can take its own pins. There is one running
job and one replaceable queued snapshot. A later request supersedes any
unsubmitted preparation. A foreign or outdated frame, a closed surface, or
an unavailable worker pool raises `ArgumentError`. The streamed 8K profile
uses synchronous bounded submission and rejects background requests.
"""
function request_frame!(surface::NativeSurface,frame::Vellum.Frame)
    require_session(surface)
    surface.backend.source_pool === :standard || throw(ArgumentError("use synchronous submit! for the streamed source pool"))
    surface.valid && !surface.preparing || throw(ArgumentError("surface cannot accept source work"))
    item = surface.item
    base = item === nothing ? surface.committed::Vellum.Frame : item.frame
    frame.canvas === base.canvas && frame.revision > base.revision ||
        throw(ArgumentError("expected a newer revision of this Canvas"))
    if surface.sources === nothing
        surface.sources = start_sources(surface.backend,surface.size)
    end
    resident = item === nothing ? surface.assets : item.assets
    return request_source!(surface.sources::SourceQueue,base.revision,frame,resident,surface.shapes)
end

"""
    Vellum.submit!(backend, surface, ticket::Preparation) -> Union{Nothing,Token}

Offer a prepared snapshot on the GPU owner thread. Return `nothing` while
its worker or the previous native fence is pending. A ready snapshot uses
the exact completed base and yields a normal GPU token. Superseded, failed,
foreign or consumed work raises. A temporarily noncurrent OpenGL context
leaves a ready ticket available for retry after restoring its context.
"""
function Vellum.submit!(backend::NativeBackend,surface::NativeSurface,ticket::Preparation)
    require_session(surface)
    surface.backend === backend && surface.sources === ticket.queue && surface.valid && !surface.preparing ||
        throw(ArgumentError("foreign preparation or unavailable surface"))
    surface.item === nothing || return nothing
    base = (surface.committed::Vellum.Frame).revision
    result = claim_source!(ticket,base)
    result === nothing && return nothing
    try
        item = enqueue_staged!(backend,surface,result.work.frame,base,result.staged;latest=true)
        finish_source!(ticket,true)
        return item
    catch
        surface.valid && finish_source!(ticket,false)
        rethrow()
    end
end

"""
    preparation_statistics(surface) -> NamedTuple

Inspect the latest source revision, stage and bounded work slots without
polling the GPU. `staged_bytes` counts CPU-owned source bytes ready for
upload. Throws for a closed, uninitialized or foreign-thread surface.
"""
function preparation_statistics(surface::NativeSurface)
    require_session(surface)
    queue = surface.sources
    queue === nothing && return (;revision=UInt64(0),state=:idle,running=false,queued=false,staged_bytes=0)
    lock(queue.changed) do
        result = queue.result
        bytes = result === nothing ? 0 : sum(item -> sizeof(item.bytes),result.staged.uploads;init=0)
        return (;revision=queue.revision,state=queue.state,running=queue.active,
                 queued=queue.pending !== nothing,staged_bytes=bytes)
    end
end

"""
    advance!(item, timeout_ns) -> Bool

Verify the outstanding token and advance its native fence. A timeout
returns false. Success publishes the pending Frame. Invalid ownership or
terminal driver errors throw, and driver failure quarantines the surface.
"""
function advance!(item::Token, timeout_ns::UInt64)
    surface = item.surface
    session = require_session(surface)
    surface.item === item || throw(ArgumentError("foreign or stale token"))
    status = ccall(session.entry.wait,Cint,(Ptr{Cvoid},UInt64,UInt64),
        session.handle,item.value,timeout_ns)
    require_context_status(status)
    status == 1 && return false
    if status == 3
        surface.valid = false
        item.state = :failed
        surface.item = nothing
        invalidate_sources!(surface.sources)
    end
    status == 0 || error("native vector fence failed with status $status")
    surface.committed = item.frame
    surface.assets = item.assets
    item.state = :complete
    surface.item = nothing
    return true
end

"""
    Vellum.completed(item::Token) -> Bool

Poll a pending fence with no wait and publish only on success. Return
false for pending, failed or cancelled tokens. Throws on wrong-thread
access or driver errors during the poll.
"""
function Vellum.completed(item::Token)
    require_owner(item.surface.backend)
    item.state === :pending && return advance!(item,UInt64(0))
    return item.state === :complete
end

"""
    wait(item::Token) -> Token

Wait up to one second for the exact fence and return the completed token.
Throws if cancelled, failed, or still pending at the deadline. A timeout
retains the pending work so the caller can retry.
"""
function Base.wait(item::Token)
    require_owner(item.surface.backend)
    item.state === :complete && return item
    item.state === :pending || throw(ArgumentError("token ended with status $(item.state)"))
    advance!(item,WAIT_NS) || error("native vector fence timed out")
    return item
end

"""
    Vellum.cancel!(item::Token) -> nothing

Quarantine a pending frame and retain its native fence for teardown. A
second cancellation is harmless. Throws for foreign and completed tokens,
wrong-thread operations, and native errors.
"""
function Vellum.cancel!(item::Token)
    surface = item.surface
    require_owner(surface.backend)
    item.state === :cancelled && return nothing
    session = require_session(surface)
    surface.item === item || throw(ArgumentError("foreign or stale token"))
    status = ccall(session.entry.abandon,Cint,(Ptr{Cvoid},UInt64),session.handle,item.value)
    status == 0 || error("native vector cancellation failed with status $status")
    surface.valid = false
    item.state = :cancelled
    surface.item = nothing
    invalidate_sources!(surface.sources)
    return nothing
end

"""
    readback_native(surface::NativeSurface) -> Vellum.Image

Explicitly copy completed premultiplied RGBA8 pixels in top-left row
order. Throws for pending, closed, or quarantined targets or driver
readback faults.
"""
function readback_native(surface::NativeSurface)
    session = require_session(surface)
    surface.valid && surface.item === nothing || throw(ArgumentError("surface output is unavailable"))
    output = Vector{UInt8}(undef,4*prod(surface.size))
    status = ccall(session.entry.pixels,Cint,(Ptr{Cvoid},Ptr{UInt8},Csize_t),
        session.handle,output,length(output))
    require_context_status(status)
    status == 0 || error("native vector capture failed with status $status")
    return Vellum.Image(surface.size...,output)
end

"""Copy the completed OpenGL image through the shared tutorial capture interface."""
Vellum.CPUBackend.pixels(surface::NativeSurface) = readback_native(surface)

"""Read a completed desktop OpenGL or Vulkan surface into independently owned host memory."""
Vellum.readback(surface::NativeSurface) = readback_native(surface)

"""Copy a completed OpenGL surface into a detached premultiplied `Image`."""
readback(surface::Surface) = readback_native(surface)

"""
    statistics_native(surface) -> NamedTuple

Inspect exact revision, cumulative upload/readback and dispatch counts,
object names, physical damage, and most recent enqueue/wait durations. Throws for closed,
uninitialized, or wrong-thread access. No fence polling or GPU readback.
"""
function statistics_native(surface::NativeSurface)
    session = require_session(surface)
    output = Vector{UInt64}(undef,length(STATS_KEYS))
    status = ccall(session.entry.stats,Cint,(Ptr{Cvoid},Ptr{UInt64},Csize_t),
        session.handle,output,length(output))
    status == 0 || error("native vector diagnostics failed with status $status")
    return NamedTuple{STATS_KEYS}(Tuple(output))
end

"""Return completed OpenGL revision and transfer counters without a framebuffer read."""
statistics(surface::Surface) = statistics_native(surface)

"""
    release_native!(surface) -> nothing

Drain and close the native handle on its owning thread. Clear the session
only after teardown succeeds. Native failure leaves the session for retry.
"""
function release_native!(surface::NativeSurface)
    session = surface.session
    session === nothing && return nothing
    status = ccall(session.entry.close,Cint,(Ptr{Cvoid},),session.handle)
    require_context_status(status)
    status == 0 || error("native vector close failed with status $status")
    surface.session = nothing
    surface.item !== nothing && (surface.item.state = :cancelled)
    surface.item = nothing
    Libdl.dlclose(session.library)
    return nothing
end

"""
    close(surface::NativeSurface) -> nothing

Drain any owned fence without publishing it, release the hardware, and
invalidate the target. Idempotent on the owner thread. If native drain
times out, ownership stays intact and close can be retried. A background
worker is cancelled and joined. An active provider read is allowed to
finish before close returns. Closing from a synchronous source callback
during preparation raises `ArgumentError`.
"""
function Base.close(surface::NativeSurface)
    require_owner(surface.backend)
    surface.closed && return nothing
    surface.preparing && throw(ArgumentError("cannot close a GPU surface during source preparation"))
    release_native!(surface)
    surface.committed = nothing
    surface.assets = RasterPages.EMPTY
    surface.shapes = FrameCurves.EMPTY_SHAPES
    surface.workspace = nothing
    surface.closed = true
    surface.valid = false
    stop_sources!(surface.sources)
    surface.sources = nothing
    return nothing
end

include("vulkan_source_stream.jl")
include("desktop.jl")

end
