"""
    VulkanBackend.QueueBackend(; device=:auto, raster_registry=nothing)

Draw portable frames offscreen on an owned Vulkan compute queue without a display.
Install VulkanCore and Shaderc_jll in the application project. Select a Float64-capable
device automatically, by vendor (:amd, :intel, :nvidia), or by (vendor ID, product ID).
The compact vector profile supports 32 commands, two group levels and a 1920 × 1080 target.
Supply a raster registry for immutable tiled sources.
"""
struct QueueBackend <: Vellum.Backend
    device::Union{Symbol,Tuple{UInt32,UInt32}}
    raster_registry::Union{Nothing,Vellum.ImageTiles.AbstractRasterResolver}
    function QueueBackend(;device=:auto,raster_registry=nothing)
        device isa Symbol && device in (:auto,:amd,:intel,:nvidia) && return new(device,raster_registry)
        if device isa Tuple && length(device)==2 && all(x -> x isa Integer && !(x isa Bool) && 0 <= x <= typemax(UInt32),device)
            return new(UInt32.(device),raster_registry)
        end
        throw(ArgumentError("invalid Vulkan device selector $device"))
    end
end

"""An owned Vulkan device, its submission resources and two independently publishable output buffers."""
struct QueueSurface{T} <: Vellum.Surface
    backend::QueueBackend
    native::T
end

"""A queue fence and the unpublished frame and page mapping that it protects."""
mutable struct QueueSubmission{T,C} <: Vellum.Submission
    native::T
    candidate::Union{Nothing,C}
    state::Symbol
end

"""
    queue_extension()

Load the optional raw Vulkan bindings and in-process shader compiler.
"""
function queue_extension()
    Vellum._require_provider(Base.PkgId(Base.UUID("16167f82-ea26-5cba-b1de-ed6fd5e30a11"),"VulkanCore"))
    Vellum._require_provider(Base.PkgId(Base.UUID("6bef4a77-805f-5404-b838-981e48d6e429"),"Shaderc_jll"))
    ext = Base.get_extension(Vellum,:VellumVulkanExt)
    isnothing(ext) && error("Vellum's Vulkan queue extension failed to load")
    return ext
end

"""
    Vellum.capabilities(b::QueueBackend)

Report vector, captured-text and sampling support for the compact Vulkan compute pipeline.
"""
function Vellum.capabilities(b::QueueBackend)
    features = (:fill_path,:stroke_path,:curve_paths,:clear,:clip,:group,:multiply,:float64,:gradient,
                :text,:text_captured_glyphs_v1,:image,:linear_sampling)
    isnothing(b.raster_registry) && return Vellum.Capabilities(;features,max_image_size=(256,256))
    pages = OpenGLBackend.RasterPages
    return Vellum.Capabilities(features=(features...,:image_provider_revision_v1,Symbol("image_storage.tiled"),:linear_srgb_image),
        formats=pages.PAGE_FORMATS,max_image_size=(pages.SOURCE_SIDE,pages.SOURCE_SIDE))
end

"""Pin the source revisions referenced by a queue drawing plan."""
Vellum.prepare_retention(b::QueueBackend,frame::Vellum.Frame) =
    Vellum.prepare_retention(OpenGLBackend.DesktopBackend(raster_registry=b.raster_registry),frame)

"""
    Vellum.make_surface(b::QueueBackend,size)

Open an offscreen queue target on the current thread.
"""
function Vellum.make_surface(b::QueueBackend,size)
    dims = Vellum.checked_dimensions(size...)
    all(dims .<= OpenGLBackend.MAX_EXTENT) || throw(ArgumentError("extent exceeds the Vulkan vector profile"))
    return QueueSurface(b,Base.invokelatest(queue_extension().open_target,b.device,dims))
end

"""
    Vellum.submit!(b::QueueBackend,s::QueueSurface,plan::Vellum.PreparedFrame)

Queue one prepared draw. Its output becomes visible only when its fence is observed.
"""
function Vellum.submit!(b::QueueBackend,s::QueueSurface,plan::Vellum.PreparedFrame)
    b === s.backend && b === plan.backend || throw(ArgumentError("foreign Vulkan queue plan or surface"))
    return Base.invokelatest(queue_extension().submit_draw!,s.native,plan)
end

"""
    Vellum.completed(t::QueueSubmission)

Poll the device fence and atomically publish the completed frame, sources and timestamps.
"""
Vellum.completed(t::QueueSubmission) = Base.invokelatest(queue_extension().advance!,t,UInt64(0))

"""
    Base.wait(t::QueueSubmission)

Wait up to one second for publication. A timeout leaves the submission pending.
"""
function Base.wait(t::QueueSubmission)
    t.state in (:pending,:complete) || throw(ArgumentError("Vulkan submission is $(t.state)"))
    Base.invokelatest(queue_extension().advance!,t,UInt64(10^9)) || error("Vulkan fence timed out")
    return t
end

"""
    Vellum.cancel!(t::QueueSubmission)

Discard a pending candidate. Its submitted GPU work retires before the next use of the queue resources.
"""
Vellum.cancel!(t::QueueSubmission) = Base.invokelatest(queue_extension().cancel_draw!,t)

"""
    Vellum.execute!(b::QueueBackend,s::QueueSurface,plan::Vellum.PreparedFrame)

Submit a draw, wait for the fence and return its surface.
"""
function Vellum.execute!(b::QueueBackend,s::QueueSurface,plan::Vellum.PreparedFrame)
    token = Vellum.submit!(b,s,plan)
    try
        Base.invokelatest(queue_extension().advance!,token,typemax(UInt64)) || error("Vulkan draw did not finish")
    finally
        token.state === :pending && Vellum.cancel!(token)
    end
    return s
end

"""
    Vellum.readback(s::QueueSurface)

Copy the last published device output to an owned top-left premultiplied RGBA8 image.
"""
Vellum.readback(s::QueueSurface) = Base.invokelatest(queue_extension().capture,s.native)

"""
    statistics(s::QueueSurface)

Report the physical device, completed frame and timing, and total and committed source transfers.
"""
statistics(s::QueueSurface) = Base.invokelatest(queue_extension().device_statistics,s.native)

"""
    Base.close(s::QueueSurface)

Drain pending commands and release this surface's buffers, device and instance.
"""
Base.close(s::QueueSurface) = Base.invokelatest(queue_extension().release!,s.native)

"""
    VulkanBackend.X11Window(display::Ptr{Cvoid}, xid::Integer)

Borrow a mapped Xlib window and its display connection. The host owns both handles,
dispatches events and keeps them alive until the Vellum surface closes.
"""
struct X11Window
    display::Ptr{Cvoid}
    xid::Culong
    function X11Window(display::Ptr{Cvoid},xid::Integer)
        display != C_NULL && !(xid isa Bool) && 0 < xid <= typemax(Culong) ||
            throw(ArgumentError("a live Xlib display and window ID are required"))
        return new(display,xid)
    end
end

"""
    VulkanBackend.window_surface(frame, backend::QueueBackend, window; size=frame.size)

Draw the initial frame on a graphics/compute queue that can present to the borrowed
Wayland or X11 window. The host supplies physical framebuffer dimensions to
`present!` and owns event dispatch. Close the result before destroying the window.
"""
function window_surface(frame::Vellum.Frame,b::QueueBackend,window::Union{WaylandWindow,X11Window};size=frame.size)
    (Sys.islinux() || Sys.isfreebsd()) || throw(ArgumentError("the raw Vulkan window provider requires Wayland or X11"))
    dims = Vellum.checked_dimensions(size...)
    all(dims .<= OpenGLBackend.MAX_EXTENT) || throw(ArgumentError("extent exceeds the Vulkan vector profile"))
    plan = Vellum.prepare(b,frame)
    try
        native = Base.invokelatest(queue_extension().open_target,b.device,dims;window)
        surface = QueueSurface(b,native)
        try
            return Vellum.execute!(b,surface,plan)
        catch
            close(surface)
            rethrow()
        end
    finally
        close(plan)
    end
end

"""
    fitted_rect(source,extent)

Fit positive pixel dimensions to a framebuffer. Center letterbox bars and
retain at least one destination pixel for very thin sources.
"""
function fitted_rect(source,extent)
    sw,sh = source
    dw,dh = extent
    if dw*sh <= dh*sw
        w,h = dw,max(1,round(Int,dw*sh/sw))
    else
        w,h = max(1,round(Int,dh*sw/sh)),dh
    end
    return (x=(dw-w)÷2,y=(dh-h)÷2,width=w,height=h)
end

"""
    window_buffer_scale(scale,extent)

Validate an optional Wayland integer scale. Physical dimensions must divide
evenly into logical surface units before the host can commit this buffer.
"""
function window_buffer_scale(scale,extent)
    isnothing(scale) && return nothing
    scale isa Integer && !(scale isa Bool) && 1 <= scale <= typemax(Cint) &&
        all(d -> iszero(rem(d,scale)),extent) || throw(ArgumentError("expected a positive integral Wayland buffer scale dividing the physical extent"))
    return Int(scale)
end

"""
    present!(surface::QueueSurface, extent::Tuple{Integer,Integer}; buffer_scale=nothing)

Present the completed frame to its borrowed window in physical pixels. The device
fits the frame inside the window with black bars. On a borrowed Wayland surface, pass an integer
`buffer_scale` to set its logical-to-physical ratio at commit. Omit it when the host
manages its own scale or fractional viewport. An explicitly committed scale stays
on the borrowed surface until the host or a later presentation changes it. A zero extent returns `:suspended`;
pending draws and unavailable FIFO images return `:busy`. Retry `:resize` after
dispatching host events. A successful offer returns `:accepted` and repeats return
`:unchanged`. No pixel data crosses to Julia during presentation.
"""
function present!(s::QueueSurface,extent::Tuple{Integer,Integer};buffer_scale=nothing)
    all(0 .<= extent .<= MAX_WINDOW_EXTENT) || throw(ArgumentError("window framebuffer extent outside profile"))
    scale = window_buffer_scale(buffer_scale,extent)
    return Base.invokelatest(queue_extension().present_window!,s.native,Int.(extent),scale)
end

"""
    VulkanBackend.window_statistics(surface::QueueSurface)

Return accepted presentations, last offered frame revision, swapchain count and extent,
format, fitted transfer bytes and host time spent in the last queue-present call.
`gpu_ns` is the device timestamp duration of the last accepted image copy and blit
where queue timestamps are available.
"""
window_statistics(s::QueueSurface) = Base.invokelatest(queue_extension().window_stats,s.native)

"""
    VulkanBackend.window_surface(frame, backend::QueueBackend, window::GLHost.Window; size=frame.size)

Attach a Vulkan drawing to a Vellum GLFW window opened with `client_api=:none`.
Select Wayland or X11 at window creation. Vellum resolves the native handles for
the selected platform. Use `GLHost.framebuffer_size(window)` for presentation.
"""
function window_surface(frame::Vellum.Frame,b::QueueBackend,w::Vellum.GLHost.Window;size=frame.size)
    glfw = Vellum.GLHost
    handle = glfw.require_open(w)
    api = ccall(glfw.symbol(w.library,:glfwGetWindowAttrib),Cint,(Ptr{Cvoid},Cint),handle,glfw.GLFW_CLIENT_API)
    api == glfw.GLFW_NO_API || throw(ArgumentError("open the Vulkan window with client_api=:none"))
    platform = glfw.backend(w)
    native = if platform === :wayland
        WaylandWindow(ccall(glfw.symbol(w.library,:glfwGetWaylandDisplay),Ptr{Cvoid},()),
                      ccall(glfw.symbol(w.library,:glfwGetWaylandWindow),Ptr{Cvoid},(Ptr{Cvoid},),handle))
    elseif platform === :x11
        X11Window(ccall(glfw.symbol(w.library,:glfwGetX11Display),Ptr{Cvoid},()),
                  ccall(glfw.symbol(w.library,:glfwGetX11Window),Culong,(Ptr{Cvoid},),handle))
    else
        throw(ArgumentError("the Vulkan queue window provider requires GLFW 3.4 on X11 or Wayland"))
    end
    return window_surface(frame,b,native;size)
end
