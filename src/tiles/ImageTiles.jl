"""Blocking CPU region cache over the ImageStorage provider/lease contract."""
module ImageTiles

import ..ImageStorage
const S = ImageStorage

export cached, visible_tiles, cache_stats

struct TileRegions
    width::Int
    height::Int
    tile_size::Int
    first_x::Int
    last_x::Int
    first_y::Int
    last_y::Int
end
Base.IteratorSize(::Type{TileRegions}) = Base.SizeUnknown()
Base.eltype(::Type{TileRegions}) = NTuple{4,Int}
function Base.iterate(tiles::TileRegions, state=(tiles.first_x,tiles.first_y))
    state === nothing && return nothing
    tx,ty = state
    x,y = tx*tiles.tile_size,ty*tiles.tile_size
    region = (x,y,min(tiles.tile_size,tiles.width-x),min(tiles.tile_size,tiles.height-y))
    next = tx < tiles.last_x ? (tx+1,ty) :
           ty < tiles.last_y ? (tiles.first_x,ty+1) : nothing
    region,next
end

function checked_region(metadata, region)
    length(region) == 4 && all(v -> v isa Integer,region) ||
        throw(ArgumentError("region must contain four integer pixel coordinates"))
    x,y,w,h = region
    0 < w <= metadata.width && 0 < h <= metadata.height &&
        0 <= x <= metadata.width-w && 0 <= y <= metadata.height-h ||
        throw(ArgumentError("region outside image"))
    Tuple(Int.(region))
end

"""Lazy full-tile rectangles covering an integer source region and optional filter gutter."""
function visible_tiles(provider, region; tile_size::Integer=provider isa CachedProvider ? provider.tile_size : 256,
                       halo=0)
    0 < tile_size <= typemax(Int) || throw(ArgumentError("tile_size must be positive and addressable"))
    metadata = S.image_metadata(provider)
    x,y,w,h = checked_region(metadata,region)
    support = halo isa Integer ? (halo,halo) : halo
    support isa Tuple && length(support) == 2 && all(v -> v isa Integer && 0 <= v <= typemax(Int),support) ||
        throw(ArgumentError("halo must be a nonnegative integer or pair"))
    hx,hy = Int.(support)
    left,top = Int(max(0,Int128(x)-hx)),Int(max(0,Int128(y)-hy))
    right = Int(min(metadata.width,Int128(x)+w+hx))
    bottom = Int(min(metadata.height,Int128(y)+h+hy))
    t = Int(tile_size)
    TileRegions(metadata.width,metadata.height,t,div(left,t),div(right-1,t),div(top,t),div(bottom-1,t))
end

mutable struct Entry
    buffer::S.PixelBuffer
    used::UInt64
end

mutable struct CachedProvider{P<:S.AbstractImageProvider} <: S.AbstractImageProvider
    source::Union{Nothing,P}
    metadata::S.ImageMetadata
    tile_size::Int
    budget::Int
    tile_bytes::Int
    capacity::Int
    revision::UInt64
    entries::Dict{Tuple{Int,Int},Entry}
    clock::UInt64
    hits::Int
    misses::Int
    evictions::Int
    loads::Int
    peak_reserved::Int
    closed::Bool
    guard::ReentrantLock
end

function source_revision(source)
    revision = S.storage_revision(source)
    revision isa Integer && 0 <= revision <= typemax(UInt64) ||
        throw(ArgumentError("tile providers require a nonnegative UInt64-addressable revision"))
    UInt64(revision)
end

"""Preserve small PixelBuffers unchanged; otherwise retain a bounded read-only region cache."""
function cached(source::S.AbstractImageProvider; tile_size::Integer=256, cache_bytes::Integer=16*1024*1024)
    0 < tile_size <= typemax(Int) && 0 < cache_bytes <= typemax(Int) ||
        throw(ArgumentError("tile size and cache budget must be positive and addressable"))
    metadata = S.image_metadata(source)
    metadata isa S.ImageMetadata || throw(ArgumentError("provider must return ImageStorage.ImageMetadata"))
    if source isa S.PixelBuffer && metadata.width <= tile_size && metadata.height <= tile_size
        return source
    end
    size,budget = Int(tile_size),Int(cache_bytes)
    bytes = Base.checked_mul(Base.checked_mul(size,size),S.channels(metadata.format))
    bytes <= budget || throw(ArgumentError("cache_bytes must reserve at least one complete tile"))
    result = CachedProvider(source,metadata,size,budget,bytes,div(budget,bytes),source_revision(source),
        Dict{Tuple{Int,Int},Entry}(),UInt64(0),0,0,0,0,0,false,ReentrantLock())
    finalizer(close,result)
    result
end

S.image_metadata(provider::CachedProvider) = provider.metadata
function S.storage_revision(provider::CachedProvider)
    lock(provider.guard) do
        provider.closed && throw(ArgumentError("tile cache is closed"))
        source_revision(provider.source)
    end
end

function release_entries!(cache)
    foreach(entry -> close(entry.buffer),values(cache.entries))
    cache.entries = Dict{Tuple{Int,Int},Entry}()
    nothing
end
function Base.close(cache::CachedProvider)
    lock(cache.guard) do
        release_entries!(cache)
        cache.source = nothing  # The authoritative provider is caller-owned, never closed here.
        cache.closed = true
    end
    nothing
end

"""Reserved cache payload is bounded; caller output leases and provider workspace are separate."""
function cache_stats(cache::CachedProvider)
    lock(cache.guard) do
        (;entries=length(cache.entries),capacity=cache.capacity,
          resident_bytes=sum(e -> S.descriptor_extent(e.buffer.descriptor),values(cache.entries);init=0),
          reserved_bytes=length(cache.entries)*cache.tile_bytes,peak_reserved_bytes=cache.peak_reserved,
          budget_bytes=cache.budget,hits=cache.hits,misses=cache.misses,
          evictions=cache.evictions,loads=cache.loads,revision=cache.revision,closed=cache.closed)
    end
end

function check_current(cache,source,revision,cancelled)
    cache.closed && throw(ArgumentError("tile cache is closed"))
    cancelled() && throw(InterruptException())
    source_revision(source) == revision || throw(ArgumentError("source revision changed during region preparation"))
    S.image_metadata(source) == cache.metadata ||
        throw(ArgumentError("source metadata changed; create a new cache"))
    nothing
end

function tile!(cache,source,region,revision,cancelled,budget)
    check_current(cache,source,revision,cancelled)
    key = (region[1],region[2])
    cache.clock = Base.checked_add(cache.clock,UInt64(1))
    if haskey(cache.entries,key)
        cache.hits += 1
        entry = cache.entries[key]
        entry.used = cache.clock
        return entry.buffer,S.CopyReport(0,())
    end
    cache.misses += 1
    if length(cache.entries) == cache.capacity
        oldest = first(keys(cache.entries))
        for (candidate,entry) in cache.entries
            entry.used < cache.entries[oldest].used && (oldest = candidate)
        end
        close(pop!(cache.entries,oldest).buffer)
        cache.evictions += 1
    end
    result = S.convert_buffer(source;region,format=cache.metadata.format,
        alpha=cache.metadata.alpha,color_space=cache.metadata.color_space,budget_bytes=budget)
    try
        check_current(cache,source,revision,cancelled)
        cache.entries[key] = Entry(result.buffer,cache.clock)
        cache.loads += 1
        cache.peak_reserved = max(cache.peak_reserved,length(cache.entries)*cache.tile_bytes)
    catch
        close(result.buffer)
        rethrow()
    end
    result.buffer,result.report
end

function copy_intersection!(destination, tile, request, rectangle, cancelled)
    x,y,w,h = request
    tx,ty,tw,th = rectangle
    left,top = max(x,tx),max(y,ty)
    right,bottom = min(x+w,tx+tw),min(y+h,ty+th)
    channels = S.channels(S.image_metadata(tile).format)
    S.with_pixels(tile) do input
        S.with_pixels(destination;access=:write) do output
            GC.@preserve input output begin
                src,dst = S.lease_pointer(input),S.lease_pointer(output)
                for row in top:bottom-1
                    cancelled() && throw(InterruptException())
                    from = ((row-ty)*tw+left-tx)*channels
                    to = ((row-y)*w+left-x)*channels
                    unsafe_copyto!(dst+to,src+from,(right-left)*channels)
                end
            end
        end
    end
    nothing
end

function S.borrow_pixels(cache::CachedProvider,
                         region=(0,0,cache.metadata.width,cache.metadata.height);
                         access=:read,copy_policy=:forbid,budget_bytes=typemax(Int),
                         format=cache.metadata.format,alpha=cache.metadata.alpha,
                         color_space=cache.metadata.color_space,layout=:native,
                         revision=nothing,cancelled=()->false)
    access == :read || throw(S.UnsupportedStorageError("cached providers are read-only"))
    copy_policy in (:forbid,:allow) || throw(ArgumentError("invalid copy policy"))
    copy_policy == :allow || throw(S.UnsupportedStorageError("cached regions require explicit staging"))
    layout in (:native,:packed) || throw(S.UnsupportedStorageError("unsupported lease layout"))
    request = checked_region(cache.metadata,region)
    n = Base.checked_mul(Base.checked_mul(request[3],request[4]),S.channels(cache.metadata.format))
    0 <= budget_bytes && n <= min(cache.budget,budget_bytes) ||
        throw(ArgumentError("region staging exceeds cache/request budget; request a smaller region"))
    (format,alpha,color_space) == (cache.metadata.format,cache.metadata.alpha,cache.metadata.color_space) ||
        throw(S.UnsupportedStorageError("use convert_buffer for explicit format/alpha/color conversion"))
    lock(cache.guard) do
        cache.closed && throw(ArgumentError("tile cache is closed"))
        source = cache.source
        current = source_revision(source)
        revision === nothing || revision == current || throw(ArgumentError("requested source revision is stale"))
        check_current(cache,source,current,cancelled)
        if current != cache.revision
            release_entries!(cache)
            cache.revision = current
        end
        output = S.allocate_buffer(request[3],request[4];format,alpha,color_space,budget_bytes)
        try
            copied = n
            steps = Set{Symbol}((:tiled_region,))
            for rectangle in visible_tiles(cache,request)
                tile,report = tile!(cache,source,rectangle,current,cancelled,budget_bytes-copied)
                copied = Base.checked_add(copied,report.copied_bytes)
                union!(steps,report.conversions)
                copy_intersection!(output,tile,request,rectangle,cancelled)
            end
            check_current(cache,source,current,cancelled)
            return S.new_lease(output,:read;close_buffer=true,
                report=S.CopyReport(copied,Tuple(sort!(collect(steps);by=string))))
        catch
            close(output)
            rethrow()
        end
    end
end

include("Revisions.jl")
include("Pyramids.jl")
include("Previews.jl")
include("P6Stream.jl")
include("LegacyOps.jl")

end
