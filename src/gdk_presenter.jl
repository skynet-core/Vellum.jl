"""
    gdk_render_frame(window, region, user_data) -> Cint

Redraw the retained frame at the GDK window's logical size. The native signal receives
one if handled or zero if the window has no drawable frame. Capture deferred failures
for the Julia caller before returning across the C callback boundary.
"""
function gdk_render_frame(window::Ptr{Cvoid},::Ptr{Cvoid},::Ptr{Cvoid})::Cint
    p = get(gdk_windows,window,nothing)
    isnothing(p) && return 0
    try
        !isnothing(p.plan) && isnothing(p.failure) || return 0
        width = ccall((:gdk_surface_get_width,VulkanBackend.GTK),Cint,(Ptr{Cvoid},),window)
        height = ccall((:gdk_surface_get_height,VulkanBackend.GTK),Cint,(Ptr{Cvoid},),window)
        min(width,height) > 0 || return 0
        VulkanBackend.with_gdk_context() do
            VulkanBackend.draw_retained!(p.surface,p.plan,(Int(width),Int(height));to_window=true)
        end
    catch err
        p.failure = CapturedException(err,catch_backtrace())
    end
    return 1
end

"""
    GdkPresenter(window::Ptr{Cvoid}; target, raster_registry=nothing)

Draw retained frames directly into a caller-owned GTK 4.14+ `GdkSurface*` on Linux.
Choose `:opengl` or `:vulkan`. Reserve the live window for this renderer and call
`present!(presenter, frame)` when the drawing changes. The host dispatches its
usual GTK events. Supply a revision resolver for tiled image resources.
Use a pointer from the same GTK runtime as the presenter.
Vellum handles expose and resize using the latest frame.
Call `close(presenter)` on the GTK main thread before destroying the window.
"""
mutable struct GdkPresenter{B<:Backend} <: Presenter
    window::Ptr{Cvoid}
    backend::B
    surface::VulkanBackend.DesktopSurface
    plan::Union{PreparedFrame{B},Nothing}
    signal::Culong
    failure::Union{CapturedException,Nothing}
    function GdkPresenter(window::Ptr{Cvoid};target::Symbol,raster_registry=nothing)
        window != C_NULL || throw(ArgumentError("a live GdkSurface pointer is required"))
        target in (:opengl,:vulkan) || throw(ArgumentError("expected :opengl or :vulkan"))
        Sys.islinux() || throw(ArgumentError("this GDK window provider requires Linux"))
        VulkanBackend.main_thread()
        haskey(gdk_windows,window) && throw(ArgumentError("window already has a Vellum presenter"))
        ccall((:gdk_surface_is_destroyed,VulkanBackend.GTK),Cint,(Ptr{Cvoid},),window) == 0 ||
            throw(ArgumentError("GDK window is destroyed"))
        backend = target === :opengl ? OpenGLBackend.DesktopBackend(;raster_registry) : VulkanBackend.DesktopBackend(;raster_registry)
        surface = VulkanBackend.with_gdk_context(() -> VulkanBackend.open_desktop_surface((1,1),window,target;backend))
        p = new{typeof(backend)}(window,backend,surface,nothing,0,nothing)
        try
            gdk_windows[window] = p
            callback = @cfunction(gdk_render_frame,Cint,(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}))
            p.signal = ccall((:g_signal_connect_data,VulkanBackend.GTK),Culong,
                (Ptr{Cvoid},Cstring,Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid},Cint),window,"render",callback,C_NULL,C_NULL,0)
            iszero(p.signal) && error("could not install the GDK render handler")
            return p
        catch
            close(p)
            rethrow()
        end
    end
end

"""
    gdk_windows

Map live GDK surface pointers to their owning Vellum presenters. The GTK main thread
registers one callback per surface and holds its Julia state until explicit close.
"""
const gdk_windows = Dict{Ptr{Cvoid},GdkPresenter}()

"""
    present!(presenter::GdkPresenter, frame::Frame) -> Symbol

Validate and retain the latest frame for the next GDK redraw. Returns `:queued`
when mapped, `:suspended` while hidden, or `:unchanged` for the same frame.
Multiple updates within one display interval coalesce. Device submission runs on
the GTK main loop and performs no CPU pixel readback. Call `presentation_statistics`
to inspect submission or a deferred render error. A different frame can retry.
"""
function present!(p::GdkPresenter,frame::Frame)
    VulkanBackend.check_open(p.surface)
    p.surface.drawing && throw(ArgumentError("GDK draw is recording"))
    ccall((:gdk_surface_is_destroyed,VulkanBackend.GTK),Cint,(Ptr{Cvoid},),p.window) == 0 ||
        throw(ArgumentError("GDK window is destroyed"))
    if !isnothing(p.plan) && p.plan.frame === frame
        isnothing(p.failure) || throw(p.failure)
        return :unchanged
    end
    replacement = prepare(p.backend,frame)
    isnothing(p.plan) || close(p.plan)
    p.plan = replacement
    p.failure = nothing
    ccall((:gdk_surface_get_mapped,VulkanBackend.GTK),Cint,(Ptr{Cvoid},),p.window) != 0 || return :suspended
    ccall((:gdk_surface_queue_render,VulkanBackend.GTK),Cvoid,(Ptr{Cvoid},),p.window)
    return :queued
end

"""
    presentation_statistics(presenter::GdkPresenter)

Return the native renderer type, submitted frame count, reused node count,
last submitted frame revision and logical window extent. A render failure
on the GTK frame clock is rethrown here with its original backtrace.
"""
function presentation_statistics(p::GdkPresenter)
    result = VulkanBackend.statistics(p.surface)
    isnothing(p.failure) || throw(p.failure)
    frame = p.surface.frame
    return (;result..., revision=isnothing(frame) ? nothing : frame.revision,
            size=isnothing(frame) ? nothing : p.surface.size)
end

"""
    close(presenter::GdkPresenter)

Release the renderer, retained plan, event handler and node cache on the GTK main
thread. Repeated close is safe. The host keeps ownership of its window.
"""
function Base.close(p::GdkPresenter)
    VulkanBackend.main_thread()
    p.surface.renderer == C_NULL && return
    p.surface.drawing && throw(ArgumentError("GDK draw is recording"))
    if !iszero(p.signal)
        ccall((:g_signal_handler_disconnect,VulkanBackend.GTK),Cvoid,(Ptr{Cvoid},Culong),p.window,p.signal)
        p.signal = 0
    end
    VulkanBackend.with_gdk_context(() -> close(p.surface))
    delete!(gdk_windows,p.window)
    isnothing(p.plan) || close(p.plan)
    p.plan = p.failure = nothing
    return nothing
end
