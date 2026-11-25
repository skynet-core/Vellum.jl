"""
    drawing(callback; size)::Frame

Build a semantic drawing and return its immutable frame.

Use a do block to receive an active edit with the requested logical size.
Callback and validation errors propagate before publication. External raster
references retain their existing provider lifetime.

# Examples

    frame = drawing(size=(32, 24)) do edit
        rectangle!(edit, 2, 3, 10, 8; fill=Solid(1, 0, 0))
    end
"""
function drawing(callback; size)
    canvas = Canvas(; size)
    transaction!(callback, canvas)
    return snapshot(canvas)
end

"""
    rectangle!(edit, x, y, width, height; fill)::UInt64

Draw a filled rectangle and return its retained node ID.

Use finite logical coordinates, nonnegative dimensions, and a paint such
as `Solid` or `LinearGradient`. The fill is scoped to this rectangle.
The current transform, clip, opacity, and blend apply. Invalid geometry,
closed edits, and edits owned by another Julia task raise `ModelError`.

    rectangle!(edit, 1, 2, 5, 4; fill=Solid(0, 0, 1))
"""
function rectangle!(edit::CanvasEdit, x::Real, y::Real, width::Real, height::Real; fill)
    return with_state(edit; fill) do scoped
        lower!(scoped, rectangle_path(x, y, width, height); mode=:fill)
    end
end

"""Marker for an option that the caller omitted."""
struct _DrawingOmitted end

"""Shared marker that distinguishes omitted keywords from explicit values."""
const _DRAWING_OMITTED = _DrawingOmitted()

"""
    _drawing_pci_id(path) -> Union{UInt16,Nothing}

Read one Linux sysfs PCI attribute. A malformed hexadecimal value returns
`nothing`. File errors propagate to the node discovery loop.
"""
function _drawing_pci_id(path)
    value = strip(read(path, String))
    isascii(value) && occursin(r"\A0x[0-9a-fA-F]{1,4}\z", value) || return nothing
    return tryparse(UInt16, value[3:end]; base=16)
end

"""
    _drawing_device(device; sysfs="/sys/class/drm", devdir="/dev/dri")

Return the PCI vendor and product as a pair of `UInt16` values. Exact
ID pairs go directly to the driver. Symbolic selectors require a unique
visible DRM node. Vanished nodes and malformed attributes are skipped.
An invalid selector, missing match, or ambiguous match raises `ArgumentError`.
"""
function _drawing_device(device; sysfs="/sys/class/drm", devdir="/dev/dri")
    if device isa Tuple && length(device) == 2 &&
       all(x -> x isa Integer && !(x isa Bool) && 0 < x <= typemax(UInt16), device)
        return (UInt16(device[1]), UInt16(device[2]))
    end
    vendors = (amd=0x1002, intel=0x8086, nvidia=0x10de)
    device isa Symbol && device in (:auto, :amd, :intel, :nvidia) ||
        throw(ArgumentError("device must be :auto, :amd, :intel, :nvidia, or a nonzero 16-bit (vendor, product) tuple"))
    wanted = device === :auto ? nothing : getproperty(vendors, device)
    nodes = try
        readdir(sysfs)
    catch err
        err isa Union{SystemError,Base.IOError} || rethrow()
        String[]
    end
    matches = Tuple{UInt16,UInt16}[]
    for node in nodes
        occursin(r"\ArenderD[0-9]+\z", node) || continue
        ispath(joinpath(devdir, node)) || continue
        ids = try
            map(name -> _drawing_pci_id(joinpath(sysfs, node, "device", name)), ("vendor", "device"))
        catch err
            err isa Union{SystemError,Base.IOError} || rethrow()
            continue
        end
        all(id -> id !== nothing && !iszero(id), ids) || continue
        (wanted === nothing || ids[1] == wanted) && push!(matches, ids)
    end
    length(matches) == 1 ||
        throw(ArgumentError("device=$device matched $(length(matches)) visible PCI DRM render nodes. Choose a unique vendor or an exact (vendor, product) pair."))
    return only(matches)
end

"""
    _drawing_native_backend(target, device)

Create the existing Linux OpenGL or Vulkan backend on the caller's thread.
Read the configured bridge path and resolve the device. Unsupported
platforms, missing bridges, and invalid devices raise `ArgumentError`.
The backend opens the device at render time.
"""
function _drawing_native_backend(target, device; linux=Sys.islinux())
    linux || throw(ArgumentError("$target one-shot rendering requires Linux; use savehtml for browser output"))
    vendor, product = _drawing_device(device)
    name = target === :opengl ? "OPENGL" : "VULKAN"
    filename = target === :opengl ? "libvetra_opengl.so" : "libvetra_vulkan.so"
    variable = "VETRA_$(name)_LIBRARY"
    path = get(ENV, variable, joinpath(@__DIR__, "..", "build", String(target), filename))
    isfile(path) || throw(ArgumentError("native bridge not found at $(repr(path)); build the $target bridge or set $variable to its library path"))
    return OpenGLBackend.NativeBackend{target}(abspath(path), vendor, product)
end

"""
    rasterize(frame; target=:cpu, device, size=frame.size, hinting=nothing)::Image
    rasterize(frame; backend, size=frame.size, hinting=nothing)::Image

Render a frame and return its own premultiplied RGBA image.

Set `size` to physical `(width, height)` in integer pixels. The default
creates and closes a temporary CPU renderer. Supply a `device` only for
`target=:opengl` or `:vulkan`. Those targets wait for a Linux native render
and read back its completed image. `device=:auto`
requires exactly one visible PCI DRM render node. `:amd`, `:intel`, and
`:nvidia` require exactly one matching node; `(vendor, product)` selects
nonzero 16-bit PCI IDs directly, including devices without a public DRM node.
For several visible GPUs, choose a unique vendor or an exact PCI pair.
The installed driver determines reachability and capabilities.

Native bridges are found at `build/{opengl,vulkan}/libvetra_{opengl,vulkan}.so`
or via `VETRA_OPENGL_LIBRARY` / `VETRA_VULKAN_LIBRARY`. Build and configure
them separately. Native library loading starts with a native request.
For advanced configuration, pass an existing `backend` on its owning thread.
The caller owns that backend. Combining it with `target` or `device` raises
`ArgumentError`.
Browser output uses `savehtml`. Invalid choices and rendering errors propagate.

Pass a reusable [`TextHinting`](@ref) session to fit supported captured
outline text to the requested physical size on Linux x86-64. Fitting
errors propagate before opening a render surface.

    image = rasterize(frame; size=(640, 480))
"""
function rasterize(frame::Frame; backend=nothing, target=_DRAWING_OMITTED, device=_DRAWING_OMITTED,
                   size=frame.size, hinting::Union{Nothing,TextHinting}=nothing)
    backend !== nothing && (target !== _DRAWING_OMITTED || device !== _DRAWING_OMITTED) &&
        throw(ArgumentError("backend conflicts with target or device"))
    if backend === nothing
        choice = target === _DRAWING_OMITTED ? :cpu : target
        choice isa Symbol && choice in (:cpu, :opengl, :vulkan) ||
            throw(ArgumentError("target must be :cpu, :opengl, or :vulkan; use savehtml for browser output"))
        if choice === :cpu
            device === _DRAWING_OMITTED || throw(ArgumentError("CPU target does not accept device"))
            renderer = CPUBackend.Renderer()
            try
                return rasterize(frame; backend=renderer, size, hinting)
            finally
                close(renderer)
            end
        end
        native = _drawing_native_backend(choice, device === _DRAWING_OMITTED ? :auto : device)
        return rasterize(frame; backend=native, size, hinting)
    elseif backend isa CPUBackend.Renderer
        frame = hinting === nothing ? frame : hinted_frame(frame; size, hinting)
        # The fresh surface is private. Pass out its owned pixel buffer.
        return render(frame; backend, size).image
    elseif backend isa OpenGLBackend.NativeBackend
        frame = hinting === nothing ? frame : hinted_frame(frame; size, hinting)
        plan = prepare(backend, frame)
        try
            surface = make_surface(backend, checked_dimensions(size...))
            try
                execute!(backend, surface, plan)
                return OpenGLBackend.readback_native(surface)
            finally
                close(surface)
            end
        finally
            close(plan)
        end
    end
    throw(ArgumentError("rasterize supports CPU, OpenGL and Vulkan backends, got $(typeof(backend))"))
end

"""
    savepng(path, frame; target=:cpu, device, size=frame.size, hinting=nothing)::String
    savepng(path, frame; backend, size=frame.size, hinting=nothing)::String

Render a frame, write it as PNG, and return the output path.

Use the physical size and backend options of [`rasterize`](@ref).
Existing output is preserved when rendering or encoding fails.
Rendering, codec, and filesystem errors propagate.
"""
function savepng(path::AbstractString, frame::Frame; backend=nothing, target=_DRAWING_OMITTED,
                 device=_DRAWING_OMITTED, size=frame.size, hinting::Union{Nothing,TextHinting}=nothing)
    return savepng(path, rasterize(frame; backend, target, device, size, hinting))
end

"""
    savepng(path, image::Image)::String

Write a premultiplied RGBA image as PNG and return the output path.

The codec publishes the completed file by renaming a temporary file in
the destination directory. Codec and filesystem errors propagate.
"""
function savepng(path::AbstractString, image::Image)
    ImageCodecs.write_image(path, image; format=:png)
    return String(path)
end
