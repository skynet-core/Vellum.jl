"""
Render bounded portable vector, dense image, captured-text and blur frames with Vulkan on Linux.
Completed images can also be presented to an application-owned Wayland window.
Importing this module loads no graphics driver. Pass the Vulkan bridge built
from `native/vulkan` and explicit PCI IDs when constructing a backend.
"""
module VulkanBackend

import Libdl
import ..OpenGLBackend
import ..OpenGLBackend: Preparation, request_frame!, preparation_status, preparation_statistics
import ..OpenGLBackend: page_cache_statistics, target_extent, box_blur_radius
import ..Vetra
import ..Vetra: present!

"""
    Backend(library, vendor, product; raster_registry=nothing, source_pool=:standard)

Select a Vulkan device by its nonzero 16-bit PCI IDs. `library` must be an
absolute path to the Vulkan bridge. Missing files or invalid IDs raise
`ArgumentError`. Hardware opens on the first render, on the creating thread.
Supply an `ImageTiles` revision resolver for immutable tiled sources.
Set `source_pool=:streamed_8k` with a compatible bridge for up to 8,160
active 64 × 64 pages. The Vulkan device reserves 256 MiB of source storage
so a failed source read can leave the previous drawing's pages intact.
Use `source_pool=:streamed_layers` for up to 10,240 active pages with the
same allocation. The union of completed and candidate pages must then fit
the 16,320 physical slots, or submission rejects before source reads.
With the rebuilt bridge, eligible unclipped sparse draws can skip empty
8 × 8 output blocks when the derived mask fits the plan buffer.
Both streamed pools prepare sources synchronously on the owner thread.
"""
const Backend = OpenGLBackend.NativeBackend{:vulkan}

"""A resident Vulkan target with a persistent image and one pending render fence."""
const Surface = OpenGLBackend.NativeSurface{Backend}

"""Largest physical Wayland framebuffer admitted, in pixels `(width, height)`."""
const MAX_WINDOW_EXTENT = (4096, 2160)

"""Ordered fields in the native Wayland presentation diagnostics record."""
const WINDOW_KEYS = (:accepted, :revision, :swapchains, :width, :height, :images, :format,
    :transfer_bytes, :queue_present_ns, :present_mode)

"""
    WaylandWindow(display::Ptr{Cvoid}, surface::Ptr{Cvoid})

Borrow live `wl_display*` and `wl_surface*` handles from the host toolkit.
Both handles must be non-null and belong to the same Wayland connection.
The native objects must remain valid until the Vulkan surface closes. The
constructor throws `ArgumentError` for null handles. The host owns event
dispatch and must avoid binding another graphics API to the same surface.
"""
struct WaylandWindow
    display::Ptr{Cvoid}
    surface::Ptr{Cvoid}

    function WaylandWindow(display::Ptr{Cvoid}, surface::Ptr{Cvoid})
        display != C_NULL && surface != C_NULL || throw(ArgumentError("Wayland handles must be non-null"))
        return new(display, surface)
    end
end

"""
    window_surface(frame, backend, window; size=frame.size) -> Surface

Render an initial `Frame` into a resident image bound to a borrowed
`WaylandWindow`. `size` is the Vetra raster extent, bounded by [`target_extent`](@ref).
Call [`present!`](@ref) separately with the host framebuffer extent.
Invalid plans or ownership throw, as do unsupported Wayland/Vulkan devices
or initial render failures. One target can borrow a given window at a time.
Close the result before destroying the window.
"""
function window_surface(frame::Vetra.Frame, backend::Backend, window::WaylandWindow; size=frame.size)
    surface = Vetra.make_surface(backend, size)
    plan = Vetra.prepare(backend, frame)
    try
        OpenGLBackend.require_plan(backend, surface, plan)
        return OpenGLBackend.initialize!(surface,backend,plan;window=(window.display,window.surface))
    finally
        close(plan)
    end
end

"""
    present!(surface::Surface, extent::Tuple{Integer,Integer}) -> Symbol

Offer the latest completed image to a borrowed Wayland window. `extent`
is the physical framebuffer size. The image keeps its aspect ratio, with
black bars where needed. Returns `:accepted` when the queue accepts the
request, `:busy` when rendering or acquisition is pending, `:unchanged`
for an already offered revision, `:resize` for an out-of-date swapchain,
or `:suspended` when either dimension is zero. Queue acceptance does not
measure scanout. Closed, offscreen, wrong-thread or oversized targets
raise `ArgumentError`. Driver failures quarantine the surface and throw.
The caller controls when to try again. No CPU pixel readback occurs.
"""
function present!(surface::Surface, extent::Tuple{Integer,Integer})
    all(0 .<= extent .<= MAX_WINDOW_EXTENT) || throw(ArgumentError("Wayland framebuffer extent outside profile"))
    session = OpenGLBackend.require_session(surface)
    call = Libdl.dlsym(session.library, :vetra_vulkan_present)
    status = ccall(call, Cint, (Ptr{Cvoid}, UInt32, UInt32), session.handle, extent[1], extent[2])
    status == 0 && return :accepted
    status == 1 && return :busy
    status == 5 && return :unchanged
    status == 6 && return :resize
    status == 7 && return :suspended
    status == 2 && throw(ArgumentError("surface is not bound to a Wayland window"))
    if status == 3
        surface.valid = false
        OpenGLBackend.invalidate_sources!(surface.sources)
    end
    error("native Vulkan presentation failed with status $status")
end

"""
    window_statistics(surface) -> NamedTuple

Read cumulative accepted presentations, the most recently accepted
revision, swapchain count, physical extent, Vulkan format and FIFO mode.
`transfer_bytes` counts fitted destination pixels written by copies or blits at four
bytes per pixel, excluding clears and compositor transfers.
`queue_present_ns` measures the latest host call into the presentation
queue. Throws for offscreen, uninitialized, closed or wrong-thread targets.
This call performs no GPU work and does not wait.
"""
function window_statistics(surface::Surface)
    session = OpenGLBackend.require_session(surface)
    call = Libdl.dlsym(session.library, :vetra_vulkan_window_stats)
    values = Vector{UInt64}(undef, length(WINDOW_KEYS))
    status = ccall(call, Cint, (Ptr{Cvoid}, Ptr{UInt64}, Csize_t), session.handle, values, length(values))
    status == 0 || throw(ArgumentError("surface is not bound to a Wayland window"))
    return NamedTuple{WINDOW_KEYS}(Tuple(values))
end

"""
    readback(surface) -> Vetra.Image

Copy completed premultiplied RGBA8 pixels into a detached image. Pending,
closed or failed surfaces raise an error. This operation waits for its own
copy submission on the owning Julia thread.
"""
readback(surface::Surface) = OpenGLBackend.readback_native(surface)

"""
    raster_statistics(surface) -> NamedTuple

Return cumulative source image bytes copied into Vulkan's resident raster
slots and the number of resident source pages in the last completed frame.
The upload count excludes staging allocations and readback traffic.
Throws for uninitialized, closed, wrong-thread, or older bridge sessions.
"""
raster_statistics(surface::Surface) = OpenGLBackend.raster_statistics(surface)

"""
    upload_staging_record(surface, Val(words)) -> Tuple

Read the native upload-staging record as `UInt64` words. The original ABI
reports three words. The four-word form adds completed standalone transfer
waits on rebuilt bridges. An unsupported record size or invalid session raises.
"""
function upload_staging_record(surface::Surface,::Val{Words}) where Words
    session = OpenGLBackend.require_session(surface)
    call = OpenGLBackend.raster_entry(session.library,:vulkan,:upload_staging)
    values = Ref{NTuple{Words,UInt64}}()
    status = ccall(call,Cint,(Ptr{Cvoid},Ref{NTuple{Words,UInt64}},Csize_t),session.handle,values,Words)
    status == 0 || error("native Vulkan staging diagnostics failed with status $status")
    return values[]
end

"""
    upload_staging_statistics(surface) -> NamedTuple

Report `capacity_bytes`, the reserved size of the native mapped upload buffer,
`peak_bytes`, its largest occupied span since opening the surface, and
`source_batches`, the number of submitted batches that included source pixels.
Counts exclude Julia's provider conversion buffers and Vulkan's readback storage.
Performs no GPU work or synchronization. Closed, uninitialized, wrong-thread,
or older bridge sessions throw.
"""
function upload_staging_statistics(surface::Surface)
    capacity_bytes, peak_bytes, source_batches = upload_staging_record(surface,Val(3))
    return (; capacity_bytes, peak_bytes, source_batches)
end

"""
    statistics(surface) -> NamedTuple

Return the latest committed revision, completed GPU timing and allocation
and transfer counters. Requires an initialized surface on its owner thread.
This call performs no image readback and does not wait on a submission.
"""
function statistics(surface::Surface)
    stats = OpenGLBackend.statistics_native(surface)
    session = OpenGLBackend.require_session(surface)
    read = Libdl.dlsym(session.library, :vetra_vulkan_diagnostics)
    extra = Vector{UInt64}(undef, 4)
    status = ccall(read, Cint, (Ptr{Cvoid}, Ptr{UInt64}, Csize_t), session.handle, extra, length(extra))
    status == 0 || error("native Vulkan diagnostics failed with status $status")
    return (; stats..., allocated_bytes=extra[1], gpu_ns=extra[2], submit_ns=extra[3],
        copy_bytes=extra[4])
end

end
