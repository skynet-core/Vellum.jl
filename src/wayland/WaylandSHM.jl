"""Present completed CPU surfaces through borrowed Wayland shared-memory windows."""
module WaylandSHM

import Libdl
import ..Vetra
import ..Vetra.CPUBackend: CPUSurface
import ..Vetra: present!

"""Maximum mapped physical extent per shared-memory slot, in pixels."""
const MAX_EXTENT = (4096, 2160)

"""Entry points in the checked-in shared-memory bridge."""
const ENTRY_POINTS = (:open, :present, :detach, :stats, :capture, :close)

"""Ordered names of the native counters and current buffer state."""
const STATS = (:revision, :commits, :staged_bytes, :releases, :in_flight, :mapped_bytes,
    :buffer_objects, :width, :height, :detached, :damage_x, :damage_y, :damage_width,
    :damage_height, :copied_pixels, :slot, :connection_failed, :protocol_buffer_damage)

"""
    Presenter(library, display, shm, surface; max_size) <: Vetra.Presenter

Bind a Linux `wl_surface*` to a two-slot Wayland shared-memory pool. Pass
an absolute bridge path and live `wl_display*`, `wl_shm*`, and `wl_surface*`
handles as `Ptr{Cvoid}`. All handles must belong to the same host connection.
`max_size=(width,height)` reserves two packed four-byte buffers of that
physical size. The surface must be configured by the host and exclusive
to this graphics adapter. The toolkit owns surface scaling, display I/O
and the event queue. Dispatch this presenter's Wayland events on the same
thread that created it. Keep the host handles alive through `close`.

Invalid arguments throw `ArgumentError`. Missing bridge symbols, file or
Wayland allocation failures, exhausted budgets, or duplicate bindings
throw before returning a usable presenter.
"""
mutable struct Presenter <: Vetra.Presenter
    library::Ptr{Cvoid}
    handle::Ptr{Cvoid}
    entry::NamedTuple{ENTRY_POINTS,NTuple{6,Ptr{Cvoid}}}
    owner::Int
    limit::NTuple{2,Int}

    function Presenter(library::AbstractString, display::Ptr{Cvoid}, shm::Ptr{Cvoid}, surface::Ptr{Cvoid};
                       max_size::Tuple{Integer,Integer})
        Sys.islinux() || throw(ArgumentError("the Wayland SHM bridge requires Linux"))
        isabspath(library) && isfile(library) || throw(ArgumentError("provide an absolute Wayland SHM bridge path"))
        all(!=(C_NULL), (display, shm, surface)) || throw(ArgumentError("Wayland handles must be non-null"))
        all(1 .<= max_size .<= MAX_EXTENT) || throw(ArgumentError("Wayland SHM extent outside profile"))
        lib = Libdl.dlopen(library)
        try
            entry = NamedTuple{ENTRY_POINTS}(map(name -> Libdl.dlsym(lib, Symbol("vetra_wl_", name)), ENTRY_POINTS))
            handle = ccall(entry.open, Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}, Cint, Cint),
                display, shm, surface, max_size[1], max_size[2])
            handle != C_NULL || error("Wayland SHM rejected the surface, owner, or mapping budget")
            return new(lib, handle, entry, Threads.threadid(), Int.(max_size))
        catch
            Libdl.dlclose(lib)
            rethrow()
        end
    end
end

"""
    handle(presenter) -> Ptr{Cvoid}

Return the live bridge context on its owner thread. Closed or cross-thread
access raises `ArgumentError` before calling Wayland.
"""
function handle(presenter::Presenter)
    Threads.threadid() == presenter.owner || throw(ArgumentError("wrong Wayland SHM owner thread"))
    presenter.handle != C_NULL || throw(ArgumentError("Wayland SHM presenter is closed"))
    return presenter.handle
end

"""
    present!(presenter, source::CPUSurface, revision; damage=nothing) -> Symbol

Queue the completed CPU image under `revision` for this window. Use
monotonic revisions from one logical view. `damage` is a zero-based physical
pixel rectangle `(left, top, width, height)` relative to the last accepted
presentation. It must cover every changed pixel. Initial, resized and skipped
revisions always stage the full image. A reusable buffer may also need pixels
    from previous edits. The source lock protects the mutable image during staging.
    A Wayland surface older than version 4 receives a full-surface damage notice.

Return `:accepted` for a queued Wayland commit, `:busy` when both slots await
release, and `:unchanged` for the same revision and physical extent. The host
waits for and dispatches events before retrying. Invalid geometry, detached
or invalid sources, and stale revisions throw `ArgumentError`. Native errors
throw without a new accepted revision. Compositor delivery has separate feedback.
"""
function present!(presenter::Presenter, source::CPUSurface, revision::Integer;
                  damage::Union{Nothing,Tuple{Integer,Integer,Integer,Integer}}=nothing)
    handle(presenter)
    0 <= revision <= typemax(UInt64) || throw(ArgumentError("invalid Wayland revision"))
    status = lock(source.guard) do
        context = handle(presenter)
        source.valid[] || throw(ArgumentError("source surface is invalid"))
        image = source.image
        all((image.width, image.height) .<= presenter.limit) || throw(ArgumentError("image exceeds the mapped extent"))
        x, y, w, h = isnothing(damage) ? (0, 0, image.width, image.height) : damage
        0 <= x < image.width && 0 <= y < image.height && 0 < w <= image.width - x && 0 < h <= image.height - y ||
            throw(ArgumentError("invalid Wayland damage rectangle"))
        region = Ref{NTuple{4,Cint}}((x, y, x+w, y+h))
        ccall(presenter.entry.present, Cint,
            (Ptr{Cvoid}, Ptr{UInt8}, Csize_t, Cint, Cint, UInt64, Ref{NTuple{4,Cint}}),
            context, image.data, length(image.data), image.width, image.height, revision, region)
    end
    status == 0 && return :accepted
    status == 1 && return :busy
    status == 2 && return :unchanged
    status == 3 && throw(ArgumentError("presenter detached, source changed extent, or revision is stale"))
    error("Wayland SHM staging failed with status $status")
end

"""
    detach!(presenter) -> nothing

Queue a null attachment and reject any future buffer offers. Idempotent
while open. The app dispatches releases before closing the presenter and
then destroys the window. Closed or wrong-thread access raises `ArgumentError`.
"""
function detach!(presenter::Presenter)
    result = ccall(presenter.entry.detach, Cint, (Ptr{Cvoid},), handle(presenter))
    result == 0 || error("Wayland SHM detach failed with status $result")
    return nothing
end

"""
    statistics(presenter) -> NamedTuple

Return queued commits, observed releases, bytes written, mapped bytes,
live occupancy and the latest device-pixel damage rectangle. `copied_pixels` includes
the repair of old slot content. `buffer_objects` counts native buffer
creations including replacements. Performs no event dispatch or pixel copy.
Invalid presenter ownership and closed handles raise `ArgumentError`.
"""
function statistics(presenter::Presenter)
    context = handle(presenter)
    output = Vector{UInt64}(undef, length(STATS))
    result = ccall(presenter.entry.stats, Cint, (Ptr{Cvoid}, Ptr{UInt64}, Csize_t), context, output, length(output))
    result == 0 || error("Wayland SHM statistics failed with status $result")
    return NamedTuple{STATS}(Tuple(output))
end

"""
    capture(presenter) -> Vetra.Image

Explicitly copy the last committed client buffer to a detached premultiplied
RGBA image for diagnostics. Throws before the first commit or on invalid
presenter ownership. Captures the application's own staging memory.
"""
function capture(presenter::Presenter)
    state = statistics(presenter)
    state.commits > 0 || throw(ArgumentError("no Wayland SHM buffer has been offered"))
    image = Vetra.Image(Int(state.width), Int(state.height))
    result = ccall(presenter.entry.capture, Cint, (Ptr{Cvoid}, Ptr{UInt8}, Csize_t),
        handle(presenter), image.data, length(image.data))
    result == 0 || error("Wayland SHM capture failed with status $result")
    return image
end

"""
    close(presenter) -> nothing

Destroy adapter resources after `detach!` and compositor release. A live
connection with unreleased buffers raises `ArgumentError`, preserving
ownership for retry after event dispatch. A terminal display connection
error permits teardown. The host window and protocol handles remain owned
by the host. Repeated close on the creating thread is harmless.
"""
function Base.close(presenter::Presenter)
    Threads.threadid() == presenter.owner || throw(ArgumentError("wrong Wayland SHM owner thread"))
    presenter.handle == C_NULL && return nothing
    result = ccall(presenter.entry.close, Cint, (Ptr{Cvoid},), presenter.handle)
    result == 1 && throw(ArgumentError("detach and dispatch Wayland buffer releases before close"))
    result == 0 || error("Wayland SHM close failed with status $result")
    presenter.handle = C_NULL
    Libdl.dlclose(presenter.library)
    return nothing
end

end
