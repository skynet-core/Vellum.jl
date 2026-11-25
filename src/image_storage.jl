module ImageStorage

export AbstractImageProvider, ImageMetadata, PixelDescriptor, PixelBuffer, PixelLease,
       CopyReport, UnsupportedStorageError, allocate_buffer, wrap_buffer, wrap_pointer,
       buffer_view, image_metadata, storage_revision, borrow_pixels, with_pixels,
       read_channel, write_channel!, lease_pointer, convert_buffer, mark_modified!,
       damage_since, descriptor_extent

struct UnsupportedStorageError <: Exception
    message::String
end
Base.showerror(io::IO, e::UnsupportedStorageError) = print(io, e.message)

abstract type AbstractImageProvider end
function image_metadata end
function storage_revision end

channels(format::Symbol) = format == :gray8 ? 1 :
    format in (:rgb8, :bgr8) ? 3 :
    format in (:rgba8, :bgra8) ? 4 :
    throw(UnsupportedStorageError("unsupported pixel format: $format"))

struct ImageMetadata
    width::Int
    height::Int
    format::Symbol
    alpha::Symbol
    color_space::Symbol
    orientation::Symbol
    function ImageMetadata(width::Integer, height::Integer; format=:rgba8,
                           alpha=channels(format) == 4 ? :premultiplied : :none,
                           color_space=:srgb, orientation=:top_left)
        width > 0 && height > 0 || throw(ArgumentError("dimensions must be positive"))
        width, height = Int(width), Int(height)
        n = channels(format)
        (n == 4 ? alpha in (:straight, :premultiplied) : alpha == :none) ||
            throw(ArgumentError("alpha mode does not match pixel format"))
        color_space in (:srgb, :linear_srgb) ||
            throw(UnsupportedStorageError("unsupported color space: $color_space"))
        orientation == :top_left ||
            throw(UnsupportedStorageError("normalize orientation before wrapping pixels"))
        new(width, height, format, alpha, color_space, orientation)
    end
end

struct PixelDescriptor
    metadata::ImageMetadata
    row_stride::Int
    pixel_stride::Int
    offset::Int
    function PixelDescriptor(m::ImageMetadata; pixel_stride=channels(m.format),
                             row_stride=Base.checked_mul(m.width, Int(pixel_stride)),
                             offset=0, planes=1, address_space=:cpu)
        planes == 1 && address_space == :cpu ||
            throw(UnsupportedStorageError("only single-plane CPU buffers are supported"))
        ps, rs, off = Int(pixel_stride), Int(row_stride), Int(offset)
        n = channels(m.format)
        ps >= n && rs >= n && off >= 0 ||
            throw(ArgumentError("strides must be positive, offset nonnegative"))
        row_span = Base.checked_add(Base.checked_mul(m.width-1, ps), n)
        column_span = Base.checked_add(Base.checked_mul(m.height-1, rs), n)
        rs >= row_span || ps >= column_span ||
            throw(UnsupportedStorageError("overlapping pixel/row strides"))
        d = new(m, rs, ps, off)
        descriptor_extent(d)
        d
    end
end

PixelDescriptor(width::Integer, height::Integer; format=:rgba8,
                alpha=channels(format) == 4 ? :premultiplied : :none,
                color_space=:srgb, orientation=:top_left, kwargs...) =
    PixelDescriptor(ImageMetadata(width,height; format,alpha,color_space,orientation); kwargs...)

"""Exclusive root-byte end; includes offset and row/pixel padding."""
function descriptor_extent(d::PixelDescriptor)
    m = d.metadata
    rows = Base.checked_mul(m.height-1, d.row_stride)
    columns = Base.checked_mul(m.width-1, d.pixel_stride)
    Base.checked_add(Base.checked_add(Base.checked_add(d.offset, rows), columns),
                     channels(m.format))
end

mutable struct LeaseRecord
    first::Int
    last::Int
    write::Bool
end

mutable struct BufferOwner{B,O,F}
    bytes::Union{Nothing,B}
    retained::Union{Nothing,O}
    release::F
    address::UInt
    byte_length::Int
    readonly::Bool
    ownership::Symbol
    guard::ReentrantLock
    leases::Vector{LeaseRecord}
    revision::UInt64
    closing::Bool
    releasing::Bool
    released::Base.Threads.Atomic{Bool}
    damage::Tuple{Int,Int}
end

# Independently wrapping overlapping memory would create two conflicting arbiters.
const OWNERS = WeakRef[]
const OWNERS_GUARD = ReentrantLock()

function register_owner!(o::BufferOwner)
    lock(OWNERS_GUARD) do
        filter!(OWNERS) do r
            owner = r.value
            owner !== nothing && !owner.released[]
        end
        for r in OWNERS
            other = r.value
            if other !== nothing && o.address < other.address+UInt(other.byte_length) &&
                    other.address < o.address+UInt(o.byte_length)
                throw(ArgumentError("memory already wrapped; use buffer_view for aliases"))
            end
        end
        push!(OWNERS, WeakRef(o))
    end
    finalizer(close, o)
    o
end

struct PixelBuffer{O<:BufferOwner} <: AbstractImageProvider
    owner::O
    descriptor::PixelDescriptor
    readonly::Bool
    function PixelBuffer(o::O, d::PixelDescriptor, readonly::Bool) where {O<:BufferOwner}
        descriptor_extent(d) <= o.byte_length ||
            throw(ArgumentError("descriptor exceeds accessible byte length"))
        new{O}(o, d, readonly || o.readonly)
    end
end

function make_buffer(bytes, d, retained, readonly, release, ownership)
    descriptor_extent(d) <= length(bytes) ||
        throw(ArgumentError("descriptor exceeds accessible byte length"))
    address = UInt(pointer(bytes))
    Base.checked_add(address, UInt(length(bytes)))
    o = BufferOwner(bytes, retained, release, address, length(bytes), readonly, ownership,
                    ReentrantLock(), LeaseRecord[], UInt64(0), false, false,
                    Base.Threads.Atomic{Bool}(false), (0,0))
    buffer = PixelBuffer(o, d, readonly)
    register_owner!(o)
    buffer
end

"""Borrow contiguous Julia bytes without copying; row/pixel layout is in d."""
function wrap_buffer(bytes::StridedVector{UInt8}, d::PixelDescriptor;
                     owner=bytes, readonly::Bool=false)
    stride(bytes,1) == 1 && firstindex(bytes) == 1 ||
        throw(UnsupportedStorageError("byte storage itself must be contiguous and one-based"))
    owner === nothing && throw(ArgumentError("a strong owner is required"))
    make_buffer(bytes, d, owner, readonly, nothing, :borrowed)
end

"""Wrap valid external CPU memory; release(owner) explicitly transfers ownership."""
function wrap_pointer(ptr::Ptr{UInt8}, byte_length::Integer, d::PixelDescriptor;
                      owner, readonly::Bool=false, release=nothing)
    ptr != C_NULL && byte_length > 0 || throw(ArgumentError("null/empty foreign buffer"))
    owner === nothing && throw(ArgumentError("a strong owner is required"))
    release === nothing && owner isa Ptr &&
        throw(ArgumentError("a pointer alone does not retain a borrowed owner"))
    release === nothing || applicable(release,owner) ||
        throw(ArgumentError("release callback must accept the retained owner"))
    n = Int(byte_length)
    descriptor_extent(d) <= n || throw(ArgumentError("foreign byte length too small"))
    Base.checked_add(UInt(ptr), UInt(n))
    GC.@preserve owner begin
        bytes = unsafe_wrap(Vector{UInt8}, ptr, n; own=false)
        make_buffer(bytes, d, owner, readonly, release,
                    release === nothing ? :borrowed : :transferred)
    end
end

function allocate_buffer(width::Integer, height::Integer; budget_bytes=typemax(Int), kwargs...)
    d = PixelDescriptor(width,height; kwargs...)
    n = descriptor_extent(d)
    n <= budget_bytes || throw(ArgumentError("pixel allocation exceeds byte budget"))
    bytes = zeros(UInt8,n)
    make_buffer(bytes,d,bytes,false,nothing,:owned)
end

image_metadata(b::PixelBuffer) = b.descriptor.metadata
storage_revision(b::PixelBuffer) = lock(() -> b.owner.revision, b.owner.guard)

function region_descriptor(b::PixelBuffer, region)
    length(region) == 4 || throw(ArgumentError("region is (x,y,width,height)"))
    x,y,w,h = Int.(region)
    m, d = image_metadata(b), b.descriptor
    x >= 0 && y >= 0 && w > 0 && h > 0 &&
        w <= m.width && h <= m.height && x <= m.width-w && y <= m.height-h ||
        throw(ArgumentError("region outside image"))
    offset = Base.checked_add(d.offset, Base.checked_add(
        Base.checked_mul(x,d.pixel_stride), Base.checked_mul(y,d.row_stride)))
    meta = ImageMetadata(w,h; format=m.format,alpha=m.alpha,color_space=m.color_space)
    PixelDescriptor(meta; row_stride=d.row_stride, pixel_stride=d.pixel_stride, offset)
end

function buffer_view(b::PixelBuffer, region; readonly::Bool=false)
    lock(b.owner.guard) do
        b.owner.closing && throw(ArgumentError("buffer is closing"))
        PixelBuffer(b.owner, region_descriptor(b,region), b.readonly || readonly)
    end
end

function release_if_ready!(o::BufferOwner)
    if o.closing && !o.releasing && !o.released[] && isempty(o.leases)
        o.releasing = true
        retained = o.retained
        try
            o.release === nothing || o.release(retained)
        finally
            o.bytes = nothing
            o.retained = nothing
            o.released[] = true
        end
    end
    nothing
end

function Base.close(o::BufferOwner)
    lock(o.guard) do
        o.closing = true
        release_if_ready!(o)
    end
end
Base.close(b::PixelBuffer) = close(b.owner)

struct CopyReport
    copied_bytes::Int
    conversions::Tuple{Vararg{Symbol}}
    function CopyReport(copied_bytes::Integer, conversions::Tuple{Vararg{Symbol}})
        copied_bytes >= 0 || throw(ArgumentError("copied byte count must be nonnegative"))
        new(Int(copied_bytes),conversions)
    end
end

mutable struct PixelLease{B<:PixelBuffer}
    buffer::B
    record::LeaseRecord
    closed::Bool
    report::CopyReport
    close_buffer::Bool
end

overlaps(a::LeaseRecord, b::LeaseRecord) = a.first <= b.last && b.first <= a.last

function new_lease(b::PixelBuffer, access::Symbol; report=CopyReport(0,()), close_buffer=false)
    access in (:read,:write) || throw(ArgumentError("access must be :read or :write"))
    access == :write && b.readonly && throw(ArgumentError("buffer is read-only"))
    o, d = b.owner, b.descriptor
    record = LeaseRecord(d.offset+1,descriptor_extent(d),access == :write)
    lock(o.guard) do
        o.closing && throw(ArgumentError("buffer is closing"))
        any(r -> (r.write || record.write) && overlaps(r,record), o.leases) &&
            throw(ArgumentError("conflicting pixel lease"))
        if record.write
            reserved = count(r -> r.write, o.leases)+1
            Base.checked_add(o.revision, UInt64(reserved))
        end
        lease = PixelLease(b,record,false,report,close_buffer)
        finalizer(close,lease)
        push!(o.leases,record)
        lease
    end
end

function Base.close(lease::PixelLease)
    o = lease.buffer.owner
    lock(o.guard) do
        lease.closed && return nothing
        lease.closed = true
        deleteat!(o.leases, findfirst(r -> r === lease.record, o.leases))
        if lease.record.write
            o.revision = Base.checked_add(o.revision,UInt64(1))
            o.damage = (lease.record.first,lease.record.last)
        end
        lease.close_buffer && (o.closing = true)
        release_if_ready!(o)
    end
    nothing
end

function active(lease::PixelLease)
    lease.closed && throw(ArgumentError("pixel lease is closed"))
    nothing
end

function byte_index(d::PixelDescriptor, row::Integer, column::Integer, channel::Integer)
    m = d.metadata
    1 <= row <= m.height && 1 <= column <= m.width && 1 <= channel <= channels(m.format) ||
        throw(BoundsError(d,(row,column,channel)))
    d.offset+(Int(row)-1)*d.row_stride+(Int(column)-1)*d.pixel_stride+Int(channel)
end

function read_channel(lease::PixelLease, row::Integer, column::Integer, channel::Integer)
    lock(lease.buffer.owner.guard) do
        active(lease)
        lease.buffer.owner.bytes[byte_index(lease.buffer.descriptor,row,column,channel)]
    end
end

function write_channel!(lease::PixelLease, value::Integer,
                        row::Integer, column::Integer, channel::Integer)
    byte = UInt8(value)
    lock(lease.buffer.owner.guard) do
        active(lease)
        lease.record.write || throw(ArgumentError("lease is read-only"))
        lease.buffer.owner.bytes[byte_index(lease.buffer.descriptor,row,column,channel)] = byte
    end
    value
end

"""Pointer to this region's first byte; retain the lease through native completion."""
function lease_pointer(lease::PixelLease)
    lock(lease.buffer.owner.guard) do
        active(lease)
        pointer(lease.buffer.owner.bytes)+lease.buffer.descriptor.offset
    end
end

function borrow_pixels(b::PixelBuffer, region=(0,0,image_metadata(b).width,image_metadata(b).height);
                       access=:read, format=image_metadata(b).format,
                       alpha=image_metadata(b).alpha, color_space=image_metadata(b).color_space,
                       layout=:native, copy_policy=:forbid, budget_bytes=typemax(Int))
    copy_policy in (:forbid,:allow) || throw(ArgumentError("invalid copy policy"))
    layout in (:native,:packed) || throw(UnsupportedStorageError("unsupported lease layout"))
    access in (:read,:write) || throw(ArgumentError("invalid lease access"))
    view = buffer_view(b,region)
    m, d = image_metadata(view), view.descriptor
    compatible = (format,alpha,color_space) == (m.format,m.alpha,m.color_space) &&
        (layout == :native || (d.pixel_stride == channels(m.format) &&
                              d.row_stride == m.width*channels(m.format)))
    compatible && return new_lease(view,access)
    copy_policy == :forbid &&
        throw(UnsupportedStorageError("requested format/alpha/color/layout requires a copy"))
    access == :read ||
        throw(UnsupportedStorageError("converted write leases have no implicit copy-back"))
    result = convert_buffer(view; format,alpha,color_space,budget_bytes)
    new_lease(result.buffer,:read; report=result.report,close_buffer=true)
end

function with_pixels(f::Function, source::AbstractImageProvider, args...; kwargs...)
    lease = borrow_pixels(source,args...; kwargs...)
    try
        f(lease)
    finally
        close(lease)
    end
end

function mark_modified!(b::PixelBuffer, region=(0,0,image_metadata(b).width,image_metadata(b).height))
    b.readonly && throw(ArgumentError("buffer is read-only"))
    d, o = region_descriptor(b,region), b.owner
    span = LeaseRecord(d.offset+1,descriptor_extent(d),true)
    lock(o.guard) do
        o.closing && throw(ArgumentError("buffer is closing"))
        any(r -> overlaps(r,span), o.leases) && throw(ArgumentError("conflicting pixel lease"))
        reserved = count(r -> r.write,o.leases)+1
        Base.checked_add(o.revision,UInt64(reserved))
        o.revision += UInt64(1)
        o.damage = (span.first,span.last)
    end
    storage_revision(b)
end

"""Conservative root-byte damage; older-than-last revisions invalidate the allocation."""
function damage_since(b::PixelBuffer, revision::Integer)
    o = b.owner
    lock(o.guard) do
        0 <= revision <= o.revision || throw(ArgumentError("invalid resource revision"))
        revision == o.revision && return (0,0)
        revision == o.revision-1 ? o.damage : (1,o.byte_length)
    end
end

decode_srgb(x) = x <= 0.04045 ? x/12.92 : ((x+0.055)/1.055)^2.4
encode_srgb(x) = x <= 0.0031308 ? 12.92*x : 1.055*x^(1/2.4)-0.055
quantize(x) = round(UInt8,255*clamp(x,0,1),RoundNearest)

function straight_pixel(lease::PixelLease, row, column)
    d, bytes = lease.buffer.descriptor, lease.buffer.owner.bytes
    i, m = byte_index(d,row,column,1), d.metadata
    n = channels(m.format)
    if n == 1
        v = bytes[i]/255
        return (v,v,v,1.0)
    end
    c1,c2,c3 = bytes[i]/255,bytes[i+1]/255,bytes[i+2]/255
    r,g,b = m.format in (:bgr8,:bgra8) ? (c3,c2,c1) : (c1,c2,c3)
    a = n == 4 ? bytes[i+3]/255 : 1.0
    if m.alpha == :premultiplied
        r,g,b = a == 0 ? (0.0,0.0,0.0) : (min(r/a,1),min(g/a,1),min(b/a,1))
    end
    (r,g,b,a)
end

function converted_pixel(pixel, source_space, target::ImageMetadata, matte)
    r,g,b,a = pixel
    if source_space != target.color_space
        transfer = source_space == :srgb ? decode_srgb : encode_srgb
        r,g,b = transfer(r),transfer(g),transfer(b)
    end
    if target.alpha == :none
        r,g,b = r*a+matte[1]*(1-a),g*a+matte[2]*(1-a),b*a+matte[3]*(1-a)
        a = 1.0
    elseif target.alpha == :premultiplied
        r,g,b = r*a,g*a,b*a
    elseif a == 0
        r,g,b = 0.0,0.0,0.0
    end
    if target.format == :gray8
        return (quantize(0.2126*r+0.7152*g+0.0722*b),)
    end
    rgb = target.format in (:bgr8,:bgra8) ? (quantize(b),quantize(g),quantize(r)) :
        (quantize(r),quantize(g),quantize(b))
    channels(target.format) == 4 ? (rgb...,quantize(a)) : rgb
end

function copy_pixels!(out::PixelBuffer, lease::PixelLease)
    d, source, destination = lease.buffer.descriptor, lease.buffer.owner.bytes, out.owner.bytes
    m = d.metadata
    n = channels(m.format)
    row_bytes = m.width*n
    if d.pixel_stride == n
        if d.row_stride == row_bytes
            copyto!(destination,1,source,d.offset+1,row_bytes*m.height)
        else
            for row in 0:m.height-1
                copyto!(destination,row*row_bytes+1,source,d.offset+row*d.row_stride+1,row_bytes)
            end
        end
    else
        for row in 1:m.height, column in 1:m.width, k in 1:n
            destination[(row-1)*row_bytes+(column-1)*n+k] =
                source[byte_index(d,row,column,k)]
        end
    end
    out
end

"""Explicit dense copy/conversion; alpha removal requires matte in destination color space."""
function convert_buffer(source::AbstractImageProvider;
                        region=(0,0,image_metadata(source).width,image_metadata(source).height),
                        format=image_metadata(source).format,
                        alpha=channels(format) == 4 ?
                            (image_metadata(source).alpha == :none ? :straight :
                             image_metadata(source).alpha) : :none,
                        color_space=image_metadata(source).color_space,
                        matte=nothing, budget_bytes=typemax(Int))
    sm = image_metadata(source)
    target = ImageMetadata(region[3],region[4]; format,alpha,color_space)
    dropping_alpha = sm.alpha != :none && alpha == :none
    dropping_alpha && matte === nothing &&
        throw(ArgumentError("alpha removal requires an explicit matte"))
    if matte !== nothing
        length(matte) == 3 && all(v -> v isa Real && isfinite(v) && 0 <= v <= 1,matte) ||
            throw(ArgumentError("matte must have three finite unit channels"))
    end
    background = matte === nothing ? (0.0,0.0,0.0) : Tuple(Float64.(matte))
    d = PixelDescriptor(target)
    n = descriptor_extent(d)
    n <= budget_bytes || throw(ArgumentError("conversion exceeds byte budget"))
    conversions = Tuple(k for (k,changed) in
        ((:format,format != sm.format),(:alpha,alpha != sm.alpha),
         (:color_space,color_space != sm.color_space)) if changed)
    lease = borrow_pixels(source,region; access=:read,copy_policy=:allow,
                          budget_bytes=budget_bytes-n)
    try
        active(lease)
        lm = image_metadata(lease.buffer)
        (lm.width,lm.height,lm.format,lm.alpha,lm.color_space) ==
            (target.width,target.height,sm.format,sm.alpha,sm.color_space) ||
            throw(ArgumentError("provider lease does not match requested pixels"))
        lease.report.copied_bytes <= budget_bytes-n ||
            throw(ArgumentError("provider staging exceeds conversion budget"))
        ld = lease.buffer.descriptor
        layout_changes = ld.pixel_stride != channels(sm.format) ||
            ld.row_stride != target.width*channels(sm.format) ? (:layout,) : ()
        out = allocate_buffer(target.width,target.height;format,alpha,color_space,budget_bytes)
        try
            if isempty(conversions)
                copy_pixels!(out,lease)
            else
                bytes = out.owner.bytes
                index = 1
                for row in 1:target.height, column in 1:target.width
                    pixel = converted_pixel(straight_pixel(lease,row,column),sm.color_space,target,background)
                    for channel in pixel
                        bytes[index] = channel
                        index += 1
                    end
                end
            end
            (buffer=out,report=CopyReport(Base.checked_add(n,lease.report.copied_bytes),
                (lease.report.conversions...,conversions...,layout_changes...)))
        catch
            close(out)
            rethrow()
        end
    finally
        close(lease)
    end
end

end
