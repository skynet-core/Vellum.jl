"""Explicitly owned GLFW window adapter; loading this module does not load GLFW."""
module GLHost

using Libdl
import ..Vellum

export Window, open_window, close!, with_window, proc_address, framebuffer_size,
       window_size, cursor_position, key_state, mouse_button_state, poll_events,
       swap_buffers, should_close, request_close!, backend, glfw_version

"""GLFW boolean true."""
const GLFW_TRUE = Cint(1)
"""GLFW window visibility hint."""
const GLFW_VISIBLE = Cint(0x00020004)
"""GLFW context major-version hint."""
const GLFW_CONTEXT_VERSION_MAJOR = Cint(0x00022002)
"""GLFW context minor-version hint."""
const GLFW_CONTEXT_VERSION_MINOR = Cint(0x00022003)
"""GLFW forward-compatible context hint."""
const GLFW_OPENGL_FORWARD_COMPAT = Cint(0x00022006)
"""GLFW context profile hint."""
const GLFW_OPENGL_PROFILE = Cint(0x00022008)
"""GLFW core profile value."""
const GLFW_OPENGL_CORE_PROFILE = Cint(0x00032001)
"""GLFW window hint selecting the client graphics API."""
const GLFW_CLIENT_API = Cint(0x00022001)
"""A window without an OpenGL or OpenGL ES context."""
const GLFW_NO_API = Cint(0)
"""GLFW platform initialization hint."""
const GLFW_PLATFORM = Cint(0x00050003)
"""GLFW Wayland platform value."""
const GLFW_PLATFORM_WAYLAND = Cint(0x00060003)
"""GLFW X11 platform value."""
const GLFW_PLATFORM_X11 = Cint(0x00060004)
"""GLFW initialization hint controlling Wayland's libdecor plugin."""
const GLFW_WAYLAND_LIBDECOR = Cint(0x00053001)
"""Ask the Wayland host to prefer the libdecor plugin."""
const GLFW_WAYLAND_PREFER_LIBDECOR = Cint(0x00038001)
"""Use GLFW's built-in Wayland decorations when the compositor needs them."""
const GLFW_WAYLAND_DISABLE_LIBDECOR = Cint(0x00038002)

"""An owned GLFW window and library handle; close on its creating thread."""
mutable struct Window
    library::Ptr{Cvoid}
    handle::Ptr{Cvoid}
    closed::Bool
end

"""Resolve a GLFW symbol from a borrowed library handle, or throw if absent."""
function symbol(library::Ptr{Cvoid}, name::Symbol)
    p = Libdl.dlsym_e(library, name)
    p == C_NULL && error("GLFW symbol not found: $name")
    p
end

"""Find GLFW lazily; throw if no override or library is available."""
function library_path()
    override = get(ENV, "VELLUM_GLFW_LIBRARY", "")
    isempty(override) || return override
    glfw = Vellum._require_provider(Base.PkgId(Base.UUID("0656b61e-2033-5cc2-a64a-77c0f6c09b89"), "GLFW_jll"))
    return Base.invokelatest(glfw.get_libglfw_path)
end

"""Return the version of an already loaded GLFW library."""
function glfw_version(library::Ptr{Cvoid})
    major, minor, patch = Ref{Cint}(), Ref{Cint}(), Ref{Cint}()
    ccall(symbol(library, :glfwGetVersion), Cvoid,
          (Ref{Cint}, Ref{Cint}, Ref{Cint}), major, minor, patch)
    (Int(major[]), Int(minor[]), Int(patch[]))
end

"""Return the GLFW version for the window's loaded library."""
glfw_version(w::Window) = glfw_version(w.library)

"""
    open_window(width, height, title; visible=true, platform=nothing, client_api=:opengl, libdecor=true, context_version=(3, 3))

Create a GLFW window. `client_api=:opengl` makes a core context of at least
`context_version` current on the calling thread. `:none` leaves it unattached.
`platform` may be `:wayland` or `:x11` on Linux with GLFW 3.4 or newer.
For an explicit Wayland platform, `libdecor=false` selects GLFW's built-in
decoration fallback instead of a libdecor plugin.
The caller owns the window and must call `close!` on the same thread. This
adapter owns GLFW initialization globally; do not use it concurrently
with another GLFW owner.
"""
function open_window(width::Integer, height::Integer, title::AbstractString;
                     visible::Bool=true, platform::Union{Nothing,Symbol}=nothing, client_api::Symbol=:opengl,
                     libdecor::Bool=true, context_version::Tuple{Integer,Integer}=(3, 3))
    0 < width <= typemax(Cint) && 0 < height <= typemax(Cint) ||
        throw(ArgumentError("window dimensions must be positive C integers"))
    occursin('\0', title) && throw(ArgumentError("title contains NUL"))
    platform in (nothing, :wayland, :x11) ||
        throw(ArgumentError("platform must be nothing, :wayland, or :x11"))
    platform !== nothing && !Sys.islinux() &&
        throw(ArgumentError("explicit platform selection is supported only on Linux"))
    client_api in (:opengl, :none) || throw(ArgumentError("client_api must be :opengl or :none"))
    libdecor || platform === :wayland || throw(ArgumentError("libdecor preference requires an explicit Wayland platform"))
    1 <= context_version[1] <= typemax(Cint) && 0 <= context_version[2] <= typemax(Cint) ||
        throw(ArgumentError("invalid OpenGL context version"))

    library = Libdl.dlopen(library_path())
    initialized = false
    handle = Ptr{Cvoid}(C_NULL)
    try
        if platform !== nothing
            glfw_version(library) >= (3, 4, 0) ||
                error("explicit platform selection requires GLFW 3.4 or newer")
            value = platform === :wayland ? GLFW_PLATFORM_WAYLAND : GLFW_PLATFORM_X11
            init_hint = symbol(library, :glfwInitHint)
            ccall(init_hint, Cvoid, (Cint, Cint), GLFW_PLATFORM, value)
            if platform === :wayland
                decor = libdecor ? GLFW_WAYLAND_PREFER_LIBDECOR : GLFW_WAYLAND_DISABLE_LIBDECOR
                ccall(init_hint, Cvoid, (Cint, Cint), GLFW_WAYLAND_LIBDECOR, decor)
            end
        end
        ccall(symbol(library, :glfwInit), Cint, ()) == GLFW_TRUE ||
            error("glfwInit failed")
        initialized = true
        hint = symbol(library, :glfwWindowHint)
        ccall(hint, Cvoid, (Cint, Cint), GLFW_VISIBLE, visible ? 1 : 0)
        if client_api === :opengl
            ccall(hint, Cvoid, (Cint, Cint), GLFW_CONTEXT_VERSION_MAJOR, context_version[1])
            ccall(hint, Cvoid, (Cint, Cint), GLFW_CONTEXT_VERSION_MINOR, context_version[2])
            ccall(hint, Cvoid, (Cint, Cint), GLFW_OPENGL_PROFILE, GLFW_OPENGL_CORE_PROFILE)
            if Sys.isapple()
                ccall(hint, Cvoid, (Cint, Cint), GLFW_OPENGL_FORWARD_COMPAT, 1)
            end
        else
            ccall(hint, Cvoid, (Cint, Cint), GLFW_CLIENT_API, GLFW_NO_API)
        end
        handle = ccall(symbol(library, :glfwCreateWindow), Ptr{Cvoid},
                       (Cint, Cint, Cstring, Ptr{Cvoid}, Ptr{Cvoid}),
                       width, height, title, C_NULL, C_NULL)
        handle == C_NULL && error("glfwCreateWindow failed")
        if client_api === :opengl
            ccall(symbol(library, :glfwMakeContextCurrent), Cvoid, (Ptr{Cvoid},), handle)
        end
        Window(library, handle, false)
    catch
        if handle != C_NULL
            ccall(symbol(library, :glfwDestroyWindow), Cvoid, (Ptr{Cvoid},), handle)
        end
        if initialized
            ccall(symbol(library, :glfwTerminate), Cvoid, ())
        end
        Libdl.dlclose(library)
        rethrow()
    end
end

"""Return the borrowed window handle, throwing if already closed."""
function require_open(w::Window)
    w.closed && throw(ArgumentError("window is closed"))
    w.handle
end

"""Run offscreen drawing with GLFW's context detached and restore the calling thread's binding on return."""
function without_context(f,w::Window)
    require_open(w)
    previous = ccall(symbol(w.library,:glfwGetCurrentContext),Ptr{Cvoid},())
    bind = symbol(w.library,:glfwMakeContextCurrent)
    ccall(bind,Cvoid,(Ptr{Cvoid},),C_NULL)
    try
        return f()
    finally
        ccall(bind,Cvoid,(Ptr{Cvoid},),previous)
    end
end

"""Close an owned window and terminate GLFW on its owning thread; idempotent."""
function close!(w::Window)
    w.closed && return nothing
    ccall(symbol(w.library, :glfwMakeContextCurrent), Cvoid, (Ptr{Cvoid},), C_NULL)
    ccall(symbol(w.library, :glfwDestroyWindow), Cvoid, (Ptr{Cvoid},), w.handle)
    ccall(symbol(w.library, :glfwTerminate), Cvoid, ())
    w.handle = C_NULL
    w.closed = true
    Libdl.dlclose(w.library)
    nothing
end

"""Call `f` with an owned window and close it even if `f` throws."""
function with_window(f::Function, args...; kwargs...)
    w = open_window(args...; kwargs...)
    try
        f(w)
    finally
        close!(w)
    end
end

"""Resolve a GL entry point in the live context; throw if unavailable."""
function proc_address(w::Window, name::AbstractString)
    require_open(w)
    occursin('\0', name) && throw(ArgumentError("procedure name contains NUL"))
    p = ccall(symbol(w.library, :glfwGetProcAddress), Ptr{Cvoid}, (Cstring,), name)
    p == C_NULL && error("OpenGL procedure not available: $name")
    p
end

"""Query a pair of window dimensions from a live GLFW window."""
function dimensions(w::Window, name::Symbol)
    handle = require_open(w)
    x, y = Ref{Cint}(), Ref{Cint}()
    ccall(symbol(w.library, name), Cvoid,
          (Ptr{Cvoid}, Ref{Cint}, Ref{Cint}), handle, x, y)
    (Int(x[]), Int(y[]))
end

"""Return the physical drawable extent, which may be zero."""
framebuffer_size(w::Window) = dimensions(w, :glfwGetFramebufferSize)
"""Return the window extent in logical coordinates."""
window_size(w::Window) = dimensions(w, :glfwGetWindowSize)

"""Return the cursor position in logical window coordinates."""
function cursor_position(w::Window)
    handle = require_open(w)
    x, y = Ref{Cdouble}(), Ref{Cdouble}()
    ccall(symbol(w.library, :glfwGetCursorPos), Cvoid,
          (Ptr{Cvoid}, Ref{Cdouble}, Ref{Cdouble}), handle, x, y)
    (Float64(x[]), Float64(y[]))
end

"""Return the GLFW state of a key in this live window."""
function key_state(w::Window, key::Integer)
    handle = require_open(w)
    Int(ccall(symbol(w.library, :glfwGetKey), Cint, (Ptr{Cvoid}, Cint), handle, key))
end

"""Return the GLFW state of a mouse button in this live window."""
function mouse_button_state(w::Window, button::Integer)
    handle = require_open(w)
    Int(ccall(symbol(w.library, :glfwGetMouseButton), Cint,
              (Ptr{Cvoid}, Cint), handle, button))
end

"""Dispatch pending GLFW events on the window owner thread."""
function poll_events(w::Window)
    require_open(w)
    ccall(symbol(w.library, :glfwPollEvents), Cvoid, ())
    nothing
end

"""
    wait_events(w, timeout=nothing) -> nothing

Let GLFW dispatch host events on its owner thread. With a positive finite
timeout in seconds, wake even if no event arrived. Throws for a closed
window or an invalid timeout.
"""
function wait_events(w::Window, timeout::Union{Nothing,Real}=nothing)
    require_open(w)
    if isnothing(timeout)
        ccall(symbol(w.library, :glfwWaitEvents), Cvoid, ())
    else
        isfinite(timeout) && timeout > 0 || throw(ArgumentError("event wait needs a positive finite timeout"))
        ccall(symbol(w.library, :glfwWaitEventsTimeout), Cvoid, (Cdouble,), timeout)
    end
    return nothing
end

"""Swap the buffers of a live window on its context owner thread."""
function swap_buffers(w::Window)
    handle = require_open(w)
    ccall(symbol(w.library, :glfwSwapBuffers), Cvoid, (Ptr{Cvoid},), handle)
    nothing
end

"""
    swap_interval!(window, interval) -> nothing

Set GLFW's swap interval for the current context. The supplied window
must be live and current on this thread. Invalid values or state throw.
"""
function swap_interval!(w::Window, interval::Integer)
    handle = require_open(w)
    0 <= interval <= typemax(Cint) || throw(ArgumentError("invalid nonnegative swap interval"))
    current = ccall(symbol(w.library,:glfwGetCurrentContext),Ptr{Cvoid},())
    current == handle || throw(ArgumentError("the window context must be current"))
    ccall(symbol(w.library,:glfwSwapInterval),Cvoid,(Cint,),interval)
    return nothing
end

"""Return whether the live window has been asked to close."""
function should_close(w::Window)
    handle = require_open(w)
    ccall(symbol(w.library, :glfwWindowShouldClose), Cint, (Ptr{Cvoid},), handle) != 0
end

"""Mark the live window for closure without destroying it."""
function request_close!(w::Window)
    handle = require_open(w)
    ccall(symbol(w.library, :glfwSetWindowShouldClose), Cvoid,
          (Ptr{Cvoid}, Cint), handle, GLFW_TRUE)
    nothing
end

"""Return GLFW's selected platform, or `:unknown` on older GLFW."""
function backend(w::Window)
    require_open(w)
    glfw_version(w) >= (3, 4, 0) || return :unknown
    value = ccall(symbol(w.library, :glfwGetPlatform), Cint, ())
    value == GLFW_PLATFORM_WAYLAND && return :wayland
    value == GLFW_PLATFORM_X11 && return :x11
    :other
end

include("frame_window.jl")
include("interactive_window.jl")

end
