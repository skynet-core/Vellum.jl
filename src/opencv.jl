import .NativeInterop: opencv_gray, opencv_version

"""Verified OpenCV provider retained with the native outputs it can create."""
struct _OpenCVBridge
    """Vetra ABI handle kept alive through allocated outputs."""
    library::NativeInterop.NativeLibrary
    """Provider version returned during successful validation."""
    version::String
end

"""Resident providers indexed by canonical path and resolved request aliases."""
const _opencv_bridges = Dict{String,_OpenCVBridge}()
"""Verified handles supplied directly by advanced callers."""
const _opencv_handles = Dict{Ptr{Cvoid},_OpenCVBridge}()
"""Protect loading and publication of verified native providers."""
const _opencv_lock = ReentrantLock()
"""Default bridge location relative to this source installation."""
const _opencv_default_path = joinpath(dirname(@__DIR__), "build", "interop",
    (Sys.iswindows() ? "vetra_interop." : "libvetra_interop.") * Libdl.dlext)

"""
    _verify_opencv(library) -> _OpenCVBridge

Read the version and check the facade's required entry points. A missing
OpenCV provider or null version raises `ArgumentError`. Loader errors propagate.
"""
function _verify_opencv(library::NativeInterop.NativeLibrary)
    version_ptr = ccall(NativeInterop.symbol(library, :vtr_opencv_version), Cstring, ())
    version_ptr == C_NULL && throw(ArgumentError("native bridge returned a null OpenCV version"))
    version = unsafe_string(version_ptr)
    isempty(strip(version)) && throw(ArgumentError("native bridge has no OpenCV provider"))
    for name in (:vtr_borrow, :vtr_release, :vtr_invert, :vtr_rgb_to_bgr, :vtr_opencv_gray, :vtr_describe)
        NativeInterop.symbol(library, name)
    end
    return _OpenCVBridge(library, version)
end

"""Verify a caller-owned library once per resident handle."""
function _opencv_bridge(library::NativeInterop.NativeLibrary)
    return lock(_opencv_lock) do
        get!(_opencv_handles, library.handle) do
            _verify_opencv(library)
        end
    end
end

"""
    _opencv_bridge(library) -> _OpenCVBridge

Resolve an explicit path or the configured default and open it lazily.
Cache only compatible OpenCV providers. Close a newly opened handle if
validation fails. Missing and malformed paths raise `ArgumentError`.
"""
function _opencv_bridge(library)
    path = library === nothing ? get(ENV, "VETRA_INTEROP_LIBRARY", _opencv_default_path) : library
    path isa AbstractString || throw(ArgumentError("library must be a path or NativeLibrary"))
    request = isabspath(path) ? String(path) : abspath(path)
    return lock(_opencv_lock) do
        cached = get(_opencv_bridges, request, nothing)
        cached === nothing || return cached
        canonical = try
            realpath(request)
        catch error
            error isa Union{Base.IOError,SystemError} || rethrow()
            throw(ArgumentError("OpenCV bridge not found at $(repr(path)). Build it in build/interop or set VETRA_INTEROP_LIBRARY."))
        end
        bridge = get!(_opencv_bridges, canonical) do
            handle = NativeInterop.NativeLibrary(canonical)
            try
                _verify_opencv(handle)
            catch
                Libdl.dlclose(handle.handle)
                rethrow()
            end
        end
        _opencv_bridges[request] = bridge
        return bridge
    end
end

"""
    opencv_version(; library=nothing) -> String

Return the real provider's version. Set `library` to a bridge path or a
loaded native library. The default uses `VETRA_INTEROP_LIBRARY` or a local
`build/interop` build. Loading is lazy. Missing, incompatible and
provider-free bridges raise an error.
"""
opencv_version(; library=nothing) = _opencv_bridge(library).version

"""A task-bound, callback-scoped native view; its fields are implementation details."""
mutable struct _OpenCVView
    """Native borrowed handle, valid only while the callback runs."""
    handle::NativeInterop.NativeHandle
    """Lease task allowed to use this view."""
    task::Task
    """Whether the lease permits mutation."""
    writable::Bool
    """Whether the callback scope remains open."""
    active::Bool
end

"""Reject views used outside their callback or from another task."""
function _opencv_active(view::_OpenCVView)
    view.active && view.task === current_task() ||
        throw(ArgumentError("OpenCV view is outside its owning task or scope"))
    nothing
end

"""Validate a zero-based ROI and return a storage view without copying."""
function _opencv_region(source::ImageStorage.PixelBuffer, roi)
    m = ImageStorage.image_metadata(source)
    region = roi === nothing ? (0, 0, m.width, m.height) : roi
    region isa Tuple && length(region) == 4 &&
        all(n -> n isa Integer && !(n isa Bool) && 0 <= n <= typemax(Int), region) ||
        throw(ArgumentError("ROI must be a tuple of four nonnegative representable integers"))
    return ImageStorage.buffer_view(source, map(Int, region))
end

"""Check native OpenCV layout, dimensions, and final accessible row pitch."""
function _opencv_compatible(buffer::ImageStorage.PixelBuffer)
    d = buffer.descriptor
    m = d.metadata
    (m.format, m.alpha, m.color_space) == (:bgr8, :none, :srgb) &&
        m.width <= typemax(Cint) && m.height <= typemax(Cint) &&
        d.pixel_stride == 3 && d.row_stride ÷ 3 >= m.width &&
        d.row_stride <= (buffer.owner.byte_length - d.offset) ÷ m.height
end

"""
    with_opencv(f, buffer; roi=nothing, access=:read, library=nothing)

Borrow BGR8 sRGB pixels without copying and return the result of `f`.
The optional ROI is zero-based `(x, y, width, height)`.
Use the view in the owning task during the callback. Closing a write
lease invalidates the region once, including when `f` throws.
Invalid regions, unsupported layouts, conflicting leases and provider
errors propagate before a callback can use the view.
"""
function with_opencv(f::Function, buffer::ImageStorage.PixelBuffer;
                     roi=nothing, access=:read, library=nothing)
    access in (:read, :write) || throw(ArgumentError("access must be :read or :write"))
    region = _opencv_region(buffer, roi)
    _opencv_compatible(region) ||
        throw(ImageStorage.UnsupportedStorageError("OpenCV requires BGR8 sRGB, tight pixels and accessible full row pitches"))
    access == :write && region.readonly && throw(ArgumentError("buffer is read-only"))
    return _with_opencv(f, region, access, _opencv_bridge(library))
end

"""
    _with_opencv(f, region, access, bridge)

Run a callback under an independent storage lease on a validated BGR
region. The task-scoped view closes before releasing the native handle
and the storage lease. Callback and storage errors propagate.
"""
function _with_opencv(f, region, access, bridge::_OpenCVBridge)
    lease = ImageStorage.new_lease(region, access)
    try
        handle = NativeInterop.borrowed(bridge.library, lease)
        try
            view = _OpenCVView(handle, current_task(), access == :write, true)
            try
                f(view)
            finally
                view.active = false
            end
        finally
            close(handle)
        end
    finally
        close(lease)
    end
end

"""Invert an active writable BGR region in place and return `nothing`. Errors propagate from the lease and OpenCV."""
function opencv_invert!(view::_OpenCVView)
    _opencv_active(view)
    view.writable || throw(ArgumentError("OpenCV view is read-only"))
    NativeInterop.invert!(view.handle)
    nothing
end

"""
    opencv_invert!(source; roi=nothing, library=nothing) -> Nothing

Invert a BGR8 region under one scoped write lease. The ROI is zero-based.
Unsupported layouts, storage conflicts and provider errors propagate.
"""
function opencv_invert!(source::ImageStorage.PixelBuffer; roi=nothing, library=nothing)
    with_opencv(source; roi, access=:write, library) do view
        opencv_invert!(view)
    end
end

"""Allocate independent Gray8 output from an active OpenCV view. Returns a buffer and payload report. Close the buffer when finished."""
function opencv_gray(view::_OpenCVView)
    _opencv_active(view)
    NativeInterop.opencv_gray(view.handle)
end

"""
    _opencv_bgr(region, bridge, matte, budget_bytes)

Convert the selected region to independently owned packed BGR8 and
return its payload report. Tight sRGB RGB8 uses the existing native
channel swap. Other layout, alpha and color conversions use ImageStorage.
The remaining output budget applies before either allocation.
"""
function _opencv_bgr(region, bridge::_OpenCVBridge, matte, budget_bytes)
    d = region.descriptor
    m = d.metadata
    tight_rgb = (m.format, m.alpha, m.color_space) == (:rgb8, :none, :srgb) &&
        d.pixel_stride == 3 && d.row_stride ÷ 3 >= m.width
    if tight_rgb && matte === nothing
        row_bytes = Base.checked_mul(3, m.width)
        Base.checked_mul(row_bytes, m.height) <= budget_bytes ||
            throw(ArgumentError("conversion exceeds byte budget"))
        result = NativeInterop.with_native(NativeInterop.rgb_to_bgr, bridge.library, region)
        d.row_stride == row_bytes && return result
        try
            report = ImageStorage.CopyReport(result.report.copied_bytes,
                (result.report.conversions..., :layout))
            return (buffer=result.buffer, report=report)
        catch
            close(result.buffer)
            rethrow()
        end
    end
    return ImageStorage.convert_buffer(region; format=:bgr8, alpha=:none,
        color_space=:srgb, matte, budget_bytes)
end

"""
    opencv_gray(source; roi=nothing, library=nothing, copy_policy=:forbid,
                matte=nothing, budget_bytes=typemax(Int))

Return `(buffer, report)` with an independently owned Gray8 buffer. Borrow
eligible BGR input, or use `:allow` for an explicit conversion of the ROI
to BGR8. Dropping alpha requires a matte in destination sRGB. The budget
covers conversion and result payload bytes. Close the returned buffer
when finished. Invalid arguments, storage and provider errors propagate.
"""
function opencv_gray(source::ImageStorage.PixelBuffer; roi=nothing, library=nothing,
                     copy_policy=:forbid, matte=nothing, budget_bytes=typemax(Int))
    copy_policy in (:forbid, :allow) || throw(ArgumentError("invalid copy policy"))
    budget_bytes isa Integer && budget_bytes >= 0 || throw(ArgumentError("invalid byte budget"))
    region = _opencv_region(source, roi)
    m = ImageStorage.image_metadata(region)
    m.width <= typemax(Cint) && m.height <= typemax(Cint) ||
        throw(ArgumentError("OpenCV dimensions exceed Cint"))
    graybytes = Base.checked_mul(m.width, m.height)
    graybytes <= budget_bytes || throw(ArgumentError("gray allocation exceeds byte budget"))
    if _opencv_compatible(region)
        return _with_opencv(opencv_gray, region, :read, _opencv_bridge(library))
    end
    copy_policy == :allow ||
        throw(ImageStorage.UnsupportedStorageError("OpenCV input requires explicit conversion"))
    lib = _opencv_bridge(library)
    converted = _opencv_bgr(region, lib, matte, budget_bytes-graybytes)
    try
        result = _with_opencv(opencv_gray, converted.buffer, :read, lib)
        try
            report = ImageStorage.CopyReport(Base.checked_add(converted.report.copied_bytes,
                result.report.copied_bytes), (converted.report.conversions..., result.report.conversions...))
            (buffer=result.buffer, report=report)
        catch
            close(result.buffer)
            rethrow()
        end
    finally
        close(converted.buffer)
    end
end

"""
    opencv_gray(source::Image; copy_policy, matte, roi, budget_bytes, library)

Read a premultiplied RGBA image and return independent Gray8 storage.
Choose `copy_policy=:allow` and an explicit sRGB matte. ROI and budget have
the same meanings as for a pixel buffer. Conversion and provider errors
propagate. Close the returned buffer when finished.
"""
function opencv_gray(source::Image; kwargs...)
    d = ImageStorage.PixelDescriptor(source.width, source.height;
        format=:rgba8, alpha=:premultiplied, color_space=:srgb)
    wrapper = ImageStorage.wrap_buffer(source.data, d; owner=source, readonly=true)
    try
        opencv_gray(wrapper; kwargs...)
    finally
        close(wrapper)
    end
end
