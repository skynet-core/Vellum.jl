export pyramid, view_request, prepare_region, pyramid_stats

mutable struct Pyramid{P<:S.AbstractImageProvider}
    source::Union{Nothing,P}
    metadata::S.ImageMetadata
    tile_size::Int
    chunk_size::Int
    cache_bytes::Int
    workspace_bytes::Int
    output_bytes::Int
    max_source_pixels::Int
    levels::Dict{Tuple{Int,UInt64},Tuple{CachedProvider,UInt64}}
    clock::UInt64
    source_requests::Int
    source_pixels::Int
    workspace_peak::Int
    cache_peak::Int
    closed::Bool
    guard::ReentrantLock
end

"""Two lazy resident levels sharing a fixed cache budget; tiny PixelBuffers retain identity."""
function pyramid(source::S.AbstractImageProvider; tile_size::Integer=32,
                 chunk_size::Integer=64,cache_bytes::Integer=1024*1024,
                 workspace_bytes::Integer=1024*1024,output_bytes::Integer=256*1024,
                 max_source_pixels::Integer=64*1024*1024)
    all(v -> v isa Integer && 0<v<=typemax(Int),
        (tile_size,chunk_size,cache_bytes,workspace_bytes,output_bytes,max_source_pixels)) ||
        throw(ArgumentError("pyramid budgets and sizes must be positive addressable integers"))
    metadata=S.image_metadata(source)
    source isa S.PixelBuffer && metadata.width<=tile_size && metadata.height<=tile_size &&
        return source
    metadata.alpha in (:none,:premultiplied) ||
        throw(S.UnsupportedStorageError("pyramid filtering requires premultiplied alpha; convert explicitly"))
    n=Base.checked_mul(Base.checked_mul(Int(tile_size),Int(tile_size)),S.channels(metadata.format))
    chunk=Base.checked_mul(Base.checked_mul(Int(chunk_size),Int(chunk_size)),S.channels(metadata.format))
    Base.checked_mul(2,n)<=cache_bytes ||
        throw(ArgumentError("cache budget must reserve one tile in each of two levels"))
    Base.checked_add(Base.checked_mul(9,n),chunk)<=workspace_bytes ||
        throw(ArgumentError("workspace must reserve tile sums, tile output and one source chunk"))
    max_source_pixels<=typemax(Int)÷255 || throw(ArgumentError("source work limit exceeds exact accumulator range"))
    p=Pyramid{typeof(source)}(source,metadata,Int(tile_size),Int(chunk_size),Int(cache_bytes),Int(workspace_bytes),
        Int(output_bytes),Int(max_source_pixels),Dict{Tuple{Int,UInt64},Tuple{CachedProvider,UInt64}}(),
        UInt64(0),0,0,0,0,false,ReentrantLock())
    finalizer(close,p)
    p
end

S.image_metadata(p::Pyramid)=p.metadata
function S.storage_revision(p::Pyramid)
    p.closed && throw(ArgumentError("pyramid is closed"))
    source_revision(p.source)
end
function Base.close(p::Pyramid)
    lock(p.guard) do
        foreach(pair -> close(pair[1]),values(p.levels))
        empty!(p.levels)
        p.source=nothing
        p.closed=true
    end
    nothing
end
function max_level(p)
    size=max(p.metadata.width,p.metadata.height)
    level=0
    while size>1
        size=cld(size,2)
        level+=1
    end
    level
end
level_scale(level)=Int128(1)<<level
function level_metadata(p,level)
    factor=level_scale(level)
    m=p.metadata
    S.ImageMetadata(Int(cld(Int128(m.width),factor)),Int(cld(Int128(m.height),factor));
                    format=m.format,alpha=m.alpha,color_space=m.color_space)
end

struct ViewRequest
    owner::Pyramid
    revision::UInt64
    level::Int
    region::NTuple{4,Int}
    scale::Int128
end

function positive_pair(value,name)
    pair=value isa Real ? (value,value) : value
    pair isa Tuple && length(pair)==2 &&
        all(v -> v isa Real && isfinite(v) && v>0,pair) ||
        throw(ArgumentError("$name must be a finite positive scalar or pair"))
    pair
end

"""Source-pixel viewport, physical pixels/source pixel = zoom*dpi; halo is in source pixels."""
function view_request(p::Pyramid,region;zoom=1,dpi=1,halo=0,level=nothing,
                      revision=S.storage_revision(p))
    x,y,w,h=checked_region(p.metadata,region)
    z,d=positive_pair(zoom,"zoom"),positive_pair(dpi,"dpi")
    # BigFloat avoids overflow/underflow in an otherwise valid physical-scale product.
    scale=max(BigFloat(z[1])*BigFloat(d[1]),BigFloat(z[2])*BigFloat(d[2]))
    limit=max_level(p)
    selected=0
    while selected<limit && scale*level_scale(selected+1)<=1
        selected+=1
    end
    if level!==nothing
        level isa Integer && 0<=level<=limit || throw(ArgumentError("invalid pyramid level"))
        selected=Int(level)
    end
    revision isa Integer && 0<=revision<=typemax(UInt64) ||
        throw(ArgumentError("invalid snapshot revision"))
    support=halo isa Integer ? (halo,halo) : halo
    support isa Tuple && length(support)==2 &&
        all(v -> v isa Integer && 0<=v<=typemax(Int),support) ||
        throw(ArgumentError("halo must be a nonnegative source-pixel integer or pair"))
    factor=level_scale(selected)
    left=max(Int128(0),Int128(x)-support[1])
    top=max(Int128(0),Int128(y)-support[2])
    right=min(Int128(p.metadata.width),Int128(x)+w+support[1])
    bottom=min(Int128(p.metadata.height),Int128(y)+h+support[2])
    lx,ly=Int(div(left,factor)),Int(div(top,factor))
    ViewRequest(p,UInt64(revision),selected,(lx,ly,Int(cld(right,factor))-lx,Int(cld(bottom,factor))-ly),factor)
end

mutable struct LevelProvider{P} <: S.AbstractImageProvider
    pyramid::P
    metadata::S.ImageMetadata
    level::Int
    revision::UInt64
    cancelled::Function
end
S.image_metadata(level::LevelProvider)=level.metadata
function S.storage_revision(level::LevelProvider)
    p=level.pyramid
    p.closed && throw(ArgumentError("pyramid is closed"))
    source_revision(p.source)==level.revision ||
        throw(ArgumentError("snapshot revision no longer available"))
    level.revision
end
function check_level(level)
    level.cancelled() && throw(InterruptException())
    S.storage_revision(level)
    S.image_metadata(level.pyramid.source)==level.pyramid.metadata ||
        throw(ArgumentError("source metadata changed; create a new pyramid"))
    nothing
end
function average_byte(sum::UInt64,count)
    q,r=divrem(sum,UInt64(count))
    UInt8(q+(2r>count || (2r==count && isodd(q))))
end

# Only the source chunk is borrowed; never request a full source footprint as staging.
function accumulate_chunk!(sums,level,region,origin,factor,remaining)
    p=level.pyramid
    x,y,w,h=region
    n=S.channels(level.metadata.format)
    budget=min(Base.checked_mul(Base.checked_mul(w,h),n),remaining)
    check_level(level)
    S.with_pixels(p.source,region;copy_policy=:allow,budget_bytes=budget) do lease
        meta=S.image_metadata(lease.buffer)
        (meta.width,meta.height,meta.format,meta.alpha,meta.color_space)==
            (w,h,level.metadata.format,level.metadata.alpha,level.metadata.color_space) ||
            throw(ArgumentError("source lease does not match pyramid request"))
        lease.report.copied_bytes<=budget ||
            throw(ArgumentError("source staging exceeds pyramid workspace/copy budget"))
        p.source_requests+=1
        p.source_pixels+=w*h
        d=lease.buffer.descriptor
        GC.@preserve lease begin
            ptr=S.lease_pointer(lease)
            for row in 0:h-1
                check_level(level)
                oy=Int(div(Int128(y)+row,factor))-origin[2]+1
                for column in 0:w-1
                    ox=Int(div(Int128(x)+column,factor))-origin[1]+1
                    for channel in 1:n
                        sums[channel,ox,oy]+=unsafe_load(ptr+row*d.row_stride+column*d.pixel_stride,channel)
                    end
                end
            end
        end
        check_level(level)
        lease.report.copied_bytes
    end
end

function S.borrow_pixels(level::LevelProvider,region;access=:read,copy_policy=:forbid,
                         budget_bytes=typemax(Int),kwargs...)
    access==:read && copy_policy==:allow ||
        throw(S.UnsupportedStorageError("pyramid level reads require explicit read-only staging"))
    x,y,w,h=checked_region(level.metadata,region)
    p=level.pyramid
    check_level(level)
    factor=level_scale(level.level)
    sx,sy=Int(Int128(x)*factor),Int(Int128(y)*factor)
    right=Int(min(Int128(p.metadata.width),(Int128(x)+w)*factor))
    bottom=Int(min(Int128(p.metadata.height),(Int128(y)+h)*factor))
    work=Int128(right-sx)*(bottom-sy)
    work<=p.max_source_pixels || throw(ArgumentError("level tile exceeds source work budget"))
    n=Base.checked_mul(Base.checked_mul(w,h),S.channels(level.metadata.format))
    n<=budget_bytes || throw(ArgumentError("level output exceeds copy budget"))
    workspace=Base.checked_add(Base.checked_mul(9,n),
        Base.checked_mul(Base.checked_mul(p.chunk_size,p.chunk_size),S.channels(level.metadata.format)))
    workspace<=p.workspace_bytes || throw(ArgumentError("level workspace budget exceeded"))
    p.workspace_peak=max(p.workspace_peak,workspace)
    sums=zeros(UInt64,S.channels(level.metadata.format),w,h)
    out=S.allocate_buffer(w,h;format=level.metadata.format,alpha=level.metadata.alpha,
                          color_space=level.metadata.color_space,budget_bytes)
    try
        copied=n
        for cy in sy:p.chunk_size:bottom-1,cx in sx:p.chunk_size:right-1
            chunk=(cx,cy,min(p.chunk_size,right-cx),min(p.chunk_size,bottom-cy))
            copied=Base.checked_add(copied,accumulate_chunk!(sums,level,chunk,(x,y),factor,budget_bytes-copied))
        end
        bytes=out.owner.bytes
        channels=size(sums,1)
        for row in 1:h,column in 1:w
            check_level(level)
            count=min(factor,p.metadata.width-(Int128(x)+column-1)*factor)*
                  min(factor,p.metadata.height-(Int128(y)+row-1)*factor)
            for channel in 1:channels
                bytes[((row-1)*w+column-1)*channels+channel]=average_byte(sums[channel,column,row],count)
            end
        end
        check_level(level)
        S.new_lease(out,:read;close_buffer=true,report=S.CopyReport(copied,(:pyramid_box,)))
    catch
        close(out)
        rethrow()
    end
end

function validate_view(p,view)
    p.closed && throw(ArgumentError("pyramid is closed"))
    view.owner===p || throw(ArgumentError("view belongs to another pyramid"))
    0<=view.level<=max_level(p) && view.scale==level_scale(view.level) ||
        throw(ArgumentError("invalid view level/scale"))
    m=level_metadata(p,view.level)
    x,y,w,h=checked_region(m,view.region)
    bytes=Base.checked_mul(Base.checked_mul(w,h),S.channels(m.format))
    bytes<=min(p.output_bytes,div(p.cache_bytes,2)) ||
        throw(ArgumentError("visible output exceeds budget; request a smaller viewport"))
    t=p.tile_size
    left,top=div(x,t)*t,div(y,t)*t
    right=min(Int128(m.width),cld(Int128(x)+w,t)*t)
    bottom=min(Int128(m.height),cld(Int128(y)+h,t)*t)
    source_width=min(Int128(p.metadata.width),right*view.scale)-Int128(left)*view.scale
    source_height=min(Int128(p.metadata.height),bottom*view.scale)-Int128(top)*view.scale
    source_width*source_height<=p.max_source_pixels ||
        throw(ArgumentError("visible source footprint exceeds work budget"))
    bytes
end

"""Blocking bounded region preparation; output lease owns its pixels and pins the requested revision."""
function prepare_region(p::Pyramid,view::ViewRequest;cancelled=()->false)
    lock(p.guard) do
        validate_view(p,view)
        source_revision(p.source)==view.revision ||
            throw(ArgumentError("snapshot revision no longer available"))
        cancelled() && throw(InterruptException())
        key=(view.level,view.revision)
        p.clock=Base.checked_add(p.clock,UInt64(1))
        if !haskey(p.levels,key)
            if length(p.levels)==2
                oldest=argmin(k -> p.levels[k][2],keys(p.levels))
                close(pop!(p.levels,oldest)[1])
            end
            provider=LevelProvider(p,level_metadata(p,view.level),view.level,view.revision,cancelled)
            cache=cached(provider;tile_size=p.tile_size,cache_bytes=div(p.cache_bytes,2))
        else
            cache=p.levels[key][1]
            cache.source.cancelled=cancelled
        end
        p.levels[key]=(cache,p.clock)
        try
            S.borrow_pixels(cache,view.region;copy_policy=:allow,revision=view.revision,cancelled)
        finally
            p.cache_peak=max(p.cache_peak,
                sum(pair->cache_stats(pair[1]).reserved_bytes,values(p.levels);init=0))
        end
    end
end

function pyramid_stats(p::Pyramid)
    lock(p.guard) do
        stats=[cache_stats(pair[1]) for pair in values(p.levels)]
        (;levels=length(stats),resident_bytes=sum(s->s.reserved_bytes,stats;init=0),
          cache_peak=p.cache_peak,cache_budget=p.cache_bytes,
          workspace_peak=p.workspace_peak,workspace_budget=p.workspace_bytes,
          output_limit=p.output_bytes,source_requests=p.source_requests,source_pixels=p.source_pixels,
          source_work_limit=p.max_source_pixels,closed=p.closed)
    end
end
