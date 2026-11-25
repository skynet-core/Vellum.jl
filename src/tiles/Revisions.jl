export AbstractRasterRevision, AbstractRasterResolver, AbstractRevisionLease, revision_resolver,
       OwnedTileRevision, retained_bytes, revision_usage, RasterRegistry,
       publish_revision!, acquire_revision, retain_frame, registry_usage, retain_revision

const V = parentmodule(@__MODULE__)
abstract type AbstractRasterRevision <: S.AbstractImageProvider end
abstract type AbstractRasterResolver end
abstract type AbstractRevisionLease <: S.AbstractImageProvider end
function revision_resolver end
retained_bytes(::AbstractRasterRevision) = V.model_error(:invalid_input,"authority must declare retained source/index bytes")

"""Process-local counter assigning one identity to each validated immutable tile."""
const tile_identity = Threads.Atomic{UInt64}(0)

"""Return a unique nonzero tile identity or report counter exhaustion."""
function next_tile_identity()
    previous = tile_identity[]
    while true
        previous < typemax(UInt64) || V.model_error(:resource_limit,"tile identity counter exhausted")
        id = previous + UInt64(1)
        observed = Threads.atomic_cas!(tile_identity,previous,id)
        observed == previous && return id
        previous = observed
    end
end

"""
    RgbaTile(width, height, bytes)

Own one packed premultiplied sRGB RGBA8 tile. Validate its shape and color
channels once, sharing `FrozenBytes` or copying a byte vector. Subsequent
revisions can share the same tile and its process-local identity. Invalid
dimensions or premultiplication raise a Vellum model error.
"""
struct RgbaTile
    pixels::V.FrozenBytes
    extent::Tuple{Int,Int}
    id::UInt64

    function RgbaTile(width::Int,height::Int,bytes::Union{V.FrozenBytes,AbstractVector{UInt8}})
        width > 0 && height > 0 && UInt128(width)*UInt128(height)*4 == length(bytes) ||
            V.model_error(:invalid_input,"invalid packed tile extent")
        frozen = bytes isa V.FrozenBytes ? bytes : V.FrozenBytes(bytes)
        for i in 1:4:length(frozen)
            max(frozen[i],frozen[i+1],frozen[i+2]) <= frozen[i+3] ||
                V.model_error(:invalid_input,"invalid premultiplied chunk")
        end
        return new(frozen,(width,height),next_tile_identity())
    end
end

"""Return the number of packed payload bytes in the tile."""
Base.length(tile::RgbaTile) = length(tile.pixels)

"""Read the packed channel byte at a one-based offset."""
Base.getindex(tile::RgbaTile,index::Int) = tile.pixels[index]

"""
    index_within_logical_charge(index, payload, charge)

Prove that the installed `summarysize(index)+256` cannot exceed `charge`.
Return false for unaudited layouts or when the bound does not fit; callers
must then calculate the original exact charge.
"""
function index_within_logical_charge(index::Dict{Tuple{Int,Int},RgbaTile},payload::Int,charge::Int)
    @static if VERSION == v"1.13.4" && Sys.MACHINE == "x86_64-linux-gnu"
        D = typeof(index)
        # shortcut: only the audited stock build/layout is specialized, re-audit before extending.
        Base.GIT_VERSION_INFO.commit == "c1ac32ab73354bbe9bb767f91e0a2b857141fe70" &&
        fieldnames(D) == (:slots,:keys,:vals,:ndel,:count,:age,:idxfloor,:maxprobe) &&
        fieldtypes(D) == (Memory{UInt8},Memory{Tuple{Int,Int}},Memory{RgbaTile},Int,Int,UInt,Int,Int) &&
        sizeof(D) == 64 && fieldnames(RgbaTile) == (:pixels,:extent,:id) &&
        fieldtypes(RgbaTile) == (V.FrozenBytes,Tuple{Int,Int},UInt64) &&
        sizeof(RgbaTile) == 32 && Base.allocatedinline(RgbaTile) &&
        Base.datatype_npointers(RgbaTile) == 1 &&
        fieldnames(V.FrozenBytes) == (:bytes,) && fieldtypes(V.FrozenBytes) == (String,) || return false
        getfield(index,:ndel) == 0 || return false
        slots,keys,vals = getfield(index,:slots),getfield(index,:keys),getfield(index,:vals)
        length(slots) == length(keys) == length(vals) || return false
        # Widen before arithmetic: all lengths and payload are addressable Ints.
        bound = UInt128(sizeof(D)) + 3*UInt128(2*sizeof(Int)) +
                UInt128(length(slots))*(sizeof(UInt8)+sizeof(Tuple{Int,Int})+sizeof(RgbaTile)) +
                UInt128(payload) + UInt128(length(index))*sizeof(Int) + 256
        return bound <= UInt128(charge)
    else
        return false
    end
end

"""
    OwnedTileRevision(width, height, chunks; tile_size=256, revision=1,
                      source_bytes=64*1024^2, max_tiles=4096,
                      max_region_bytes=1024^2, share_pages=false)

Own a sparse index of zero-based tile coordinates. Values are `RgbaTile`,
`FrozenBytes`, or packed premultiplied RGBA8 vectors. Missing tiles are
transparent. `share_pages` permits native adapters with the same tile grid
to omit absent tiles and reuse the identities of shared tiles across exact
revisions. Invalid input, duplicate tiles, and exceeded budgets raise Vellum
model errors. Borrowing pixels still requires an explicit read lease.
"""
mutable struct OwnedTileRevision <: AbstractRasterRevision
    metadata::S.ImageMetadata
    tile_size::Int
    tag::UInt64
    index::Dict{Tuple{Int,Int},RgbaTile}
    charge::Int
    payload_bytes::Int
    chunk_count::Int
    max_tiles::Int
    max_region_bytes::Int
    share_pages::Bool
    closed::Bool
    guard::ReentrantLock
    function OwnedTileRevision(width::Integer,height::Integer,chunks;
                               tile_size::Integer=256,revision::Integer=1,
                               source_bytes::Integer=64*1024*1024,max_tiles::Integer=4096,
                               max_region_bytes::Integer=1024*1024,share_pages::Bool=false)
        all(x->x isa Integer && 0<x<=typemax(Int),(tile_size,source_bytes,max_tiles,max_region_bytes)) ||
            V.model_error(:invalid_input,"authority limits must be positive and addressable")
        0 <= revision <= typemax(UInt64) || V.model_error(:invalid_input,"invalid provider tag")
        metadata=S.ImageMetadata(width,height)
        index=Dict{Tuple{Int,Int},RgbaTile}()
        # A typed paint checkpoint map has already been bounded and contains
        # validated tiles. Raw chunk iterators still grow only after admission.
        if chunks isa Dict{Tuple{Int,Int},RgbaTile}
            sizehint!(index,min(length(chunks),max_tiles,(source_bytes-256)÷256))
        end
        charge=256
        payload=0
        charge<=source_bytes || V.model_error(:resource_limit,"authority header exceeds source budget")
        for (key,bytes) in chunks
            key isa Tuple && length(key)==2 && all(x->x isa Integer,key) ||
                V.model_error(:invalid_input,"tile key must be an integer pair")
            tx,ty=key
            0<=tx<=div(metadata.width-1,tile_size) && 0<=ty<=div(metadata.height-1,tile_size) ||
                V.model_error(:invalid_input,"tile outside logical source")
            k=(Int(tx),Int(ty))
            haskey(index,k) && V.model_error(:invalid_input,"duplicate tile")
            length(index)<max_tiles || V.model_error(:resource_limit,"authority tile count exceeded")
            w=min(tile_size,metadata.width-tx*tile_size)
            h=min(tile_size,metadata.height-ty*tile_size)
            bytes isa Union{RgbaTile,V.FrozenBytes,AbstractVector{UInt8}} ||
                V.model_error(:invalid_input,"chunks must contain RGBA tiles or packed bytes")
            n=UInt128(w)*UInt128(h)*4
            n<=typemax(Int) && length(bytes)==n || V.model_error(:invalid_input,"invalid edge chunk extent")
            next=Int128(charge)+256+Int(n)
            next<=source_bytes || V.model_error(:resource_limit,"authority source/index budget exceeded")
            tile = bytes isa RgbaTile ? bytes : RgbaTile(Int(w),Int(h),bytes)
            tile.extent == (w,h) || V.model_error(:invalid_input,"tile extent does not match placement")
            index[k]=tile
            charge=Int(next)
            payload+=Int(n)
        end
        # Charge actual index overhead if this Julia runtime exceeds the conservative per-entry allowance.
        if !index_within_logical_charge(index,payload,charge)
            charge=max(charge,Base.summarysize(index)+256)
        end
        charge<=source_bytes || V.model_error(:resource_limit,"authority index exceeds source budget")
        result=new(metadata,Int(tile_size),UInt64(revision),index,charge,payload,length(index),Int(max_tiles),
                   Int(max_region_bytes),share_pages,false,ReentrantLock())
        finalizer(close,result)
        result
    end
end
function Base.getproperty(source::OwnedTileRevision,name::Symbol)
    name===:index && throw(ArgumentError("owned tile index is private"))
    getfield(source,name)
end
Base.setproperty!(::OwnedTileRevision,::Symbol,value)=throw(ArgumentError("owned revision fields are immutable"))
S.image_metadata(source::OwnedTileRevision)=source.metadata
function S.storage_revision(source::OwnedTileRevision)
    lock(source.guard) do
        source.closed && V.model_error(:resource_unavailable,"owned revision is closed")
        source.tag
    end
end
retained_bytes(source::OwnedTileRevision)=source.charge
function revision_usage(source::OwnedTileRevision)
    lock(source.guard) do
        (;source_bytes=source.closed ? 0 : source.charge,
          chunk_bytes=source.closed ? 0 : source.payload_bytes,
          index_bytes=source.closed ? 0 : source.charge-source.payload_bytes,
          index_entries=source.closed ? 0 : source.chunk_count,
          declared_bytes=source.charge,max_tiles=source.max_tiles,
          max_region_bytes=source.max_region_bytes,closed=source.closed)
    end
end
function Base.close(source::OwnedTileRevision)
    lock(source.guard) do
        source.closed && return nothing
        setfield!(source,:closed,true)
        empty!(getfield(source,:index))
    end
    nothing
end
function S.borrow_pixels(source::OwnedTileRevision,region=(0,0,source.metadata.width,source.metadata.height);
                         access=:read,copy_policy=:forbid,budget_bytes=typemax(Int),
                         format=:rgba8,alpha=:premultiplied,color_space=:srgb,layout=:native,
                         revision=nothing,cancelled=()->false)
    access===:read && copy_policy===:allow ||
        throw(S.UnsupportedStorageError("owned sparse regions require explicit read staging"))
    (format,alpha,color_space)==(:rgba8,:premultiplied,:srgb) && layout in (:native,:packed) ||
        throw(S.UnsupportedStorageError("use explicit storage conversion"))
    x,y,w,h=checked_region(source.metadata,region)
    n=UInt128(w)*UInt128(h)*4
    0<=budget_bytes && n<=min(source.max_region_bytes,budget_bytes) ||
        V.model_error(:resource_limit,"owned revision region exceeds staging budget")
    lock(source.guard) do
        source.closed && V.model_error(:resource_unavailable,"owned revision is closed")
        revision===nothing || revision==source.tag || V.model_error(:invalid_input,"wrong provider revision tag")
        cancelled() && throw(InterruptException())
        output=S.allocate_buffer(w,h;budget_bytes)
        try
            bytes=output.owner.bytes
            t=source.tile_size
            for row in 0:h-1
                cancelled() && throw(InterruptException())
                for column in 0:w-1
                    px,py=x+column,y+row
                    chunk=get(getfield(source,:index),(div(px,t),div(py,t)),nothing)
                    chunk===nothing && continue
                    cw=min(t,source.metadata.width-div(px,t)*t)
                    offset=4*(mod(py,t)*cw+mod(px,t))
                    destination=4*(row*w+column)
                    for c in 1:4
                        bytes[destination+c]=chunk[offset+c]
                    end
                end
            end
            S.new_lease(output,:read;close_buffer=true,report=S.CopyReport(Int(n),(:owned_tiles,)))
        catch
            close(output)
            rethrow()
        end
    end
end

mutable struct RevisionEntry
    descriptor::V.RasterReference
    source::AbstractRasterRevision
    tag::UInt64
    bytes::Int
    pins::Int
    guard::ReentrantLock
end
mutable struct RasterRegistry <: AbstractRasterResolver
    namespace::UInt128
    source_bytes::Int
    max_assets::Int
    max_revisions::Int
    max_leases::Int
    entries::Dict{Tuple{UInt64,UInt64},RevisionEntry}
    assets::Dict{UInt64,UInt64}
    next_asset::UInt64
    bytes::Int
    leases::Int
    peak_bytes::Int
    peak_assets::Int
    peak_revisions::Int
    peak_leases::Int
    source_reads::UInt64
    source_pixels::UInt128
    peak_region_bytes::Int
    closing::Bool
    guard::ReentrantLock
    function RasterRegistry(;namespace::Integer,source_bytes::Integer,max_assets::Integer,
                            max_revisions::Integer,max_leases::Integer)
        0<namespace<=typemax(UInt128) || V.model_error(:invalid_input,"invalid registry namespace")
        all(x->0<x<=typemax(Int),(source_bytes,max_assets,max_revisions,max_leases)) ||
            V.model_error(:invalid_input,"registry requires finite positive limits")
        new(UInt128(namespace),Int(source_bytes),Int(max_assets),Int(max_revisions),Int(max_leases),
            Dict{Tuple{UInt64,UInt64},RevisionEntry}(),Dict{UInt64,UInt64}(),0,0,0,0,0,0,0,0,0,0,false,ReentrantLock())
    end
end

# Live transfer markers prevent cross-registry double ownership, not a retired-handle history.
const authority_ownership=WeakRef[]
const authority_ownership_guard=ReentrantLock()
mutable struct RevisionLease <: AbstractRevisionLease
    registry::RasterRegistry
    entries::Vector{RevisionEntry}
    closed::Bool
end
revision_resolver(lease::RevisionLease)=lease.registry

"""
    shared_tile_sources(lease::RevisionLease, side)

Find the opted-in owned authorities with the requested native tile side.
The caller keeps the execution lease open while inspecting the returned
authorities. Other provider types use their ordinary exact revision keys.
A closed lease raises a resource-unavailable error.
"""
function shared_tile_sources(lease::RevisionLease,side::Int)
    return lock(lease.registry.guard) do
        lease.closed && V.model_error(:resource_unavailable,"raster lease is closed")
        sources = nothing
        for entry in lease.entries
            authority = entry.source
            authority isa OwnedTileRevision && authority.share_pages && authority.tile_size == side || continue
            sources === nothing && (sources = Dict{V.RasterReference,OwnedTileRevision}())
            sources[entry.descriptor] = authority
        end
        return sources
    end
end

"""Inspect the validated sparse tile index under its lock, rejecting closed sources."""
function with_shared_tiles(callback,source::OwnedTileRevision)
    return lock(source.guard) do
        source.closed && V.model_error(:resource_unavailable,"owned revision is closed")
        callback(getfield(source,:index))
    end
end

key(d::V.RasterReference)=(d.asset,d.revision)
raster_identity(d::V.RasterReference)=(d.namespace,d.asset,d.revision)
function revision_error(category,d,message)
    V.model_error(category,"raster $(raster_identity(d)): $message")
end
function update_peaks!(r)
    r.peak_bytes=max(r.peak_bytes,r.bytes)
    r.peak_assets=max(r.peak_assets,length(r.assets))
    r.peak_revisions=max(r.peak_revisions,length(r.entries))
    r.peak_leases=max(r.peak_leases,r.leases)
end
function lease_locked(r,entries)
    max(1,length(entries))<=r.max_leases-r.leases || V.model_error(:resource_limit,"raster lease limit exceeded")
    lease=RevisionLease(r,entries,false)
    finalizer(close,lease)
    for entry in entries
        entry.pins+=1
    end
    r.leases+=max(1,length(entries))
    update_peaks!(r)
    lease
end
function publish_revision!(r::RasterRegistry,source::AbstractRasterRevision;asset=nothing)
    # All adapter callbacks occur before the ownership/registry critical sections.
    ismutabletype(typeof(source)) || V.model_error(:invalid_input,"authority requires an independent closeable handle")
    m=S.image_metadata(source)
    m isa S.ImageMetadata || V.model_error(:invalid_input,"invalid authority metadata")
    metadata=V.ImageMetadata(m.width,m.height;format=m.format,alpha=m.alpha,color_space=m.color_space,
                             orientation=m.orientation,storage=:tiled)
    tag=source_revision(source)
    charge=retained_bytes(source)
    charge isa Integer && 0<charge<=typemax(Int) ||
        V.model_error(:invalid_input,"authority retention charge must be known and positive")
    marker=WeakRef(source)
    lock(authority_ownership_guard) do
        filter!(w->w.value!==nothing,authority_ownership)
        any(w->w.value===source,authority_ownership) &&
            V.model_error(:invalid_input,"authority ownership already transferred")
        lock(r.guard) do
            r.closing && V.model_error(:resource_unavailable,"raster registry is closed")
            fresh=asset===nothing
            if fresh
                r.next_asset<typemax(UInt64) || V.model_error(:resource_limit,"raster asset counter exhausted")
                id=r.next_asset+UInt64(1)
                rev=UInt64(1)
                length(r.assets)<r.max_assets || V.model_error(:resource_limit,"raster asset limit exceeded")
            else
                asset isa Integer && 0<asset<=typemax(UInt64) ||
                    V.model_error(:invalid_input,"invalid raster asset")
                id=UInt64(asset)
                haskey(r.assets,id) && any(e->e.descriptor.asset==id && e.pins>0,values(r.entries)) ||
                    V.model_error(:resource_unavailable,"raster asset $id is retired or absent")
                r.assets[id]<typemax(UInt64) || V.model_error(:resource_limit,"raster revision counter exhausted")
                rev=r.assets[id]+UInt64(1)
            end
            d=V.RasterReference(r.namespace,id,rev,metadata)
            charge<=r.source_bytes-r.bytes && length(r.entries)<r.max_revisions &&
                r.leases<r.max_leases || revision_error(:resource_limit,d,"publication exceeds registry limits")
            entry=RevisionEntry(d,source,tag,Int(charge),0,ReentrantLock())
            # Allocate all fallible containers before committing accounting/ownership.
            lease=RevisionLease(r,RevisionEntry[entry],false)
            finalizer(close,lease)
            try
                push!(authority_ownership,marker)
                r.entries[key(d)]=entry
                r.assets[id]=rev
            catch
                filter!(w->w!==marker,authority_ownership)
                delete!(r.entries,key(d))
                fresh ? delete!(r.assets,id) : (r.assets[id]=rev-UInt64(1))
                lease.closed=true
                rethrow()
            end
            entry.pins=1
            r.bytes+=Int(charge)
            r.leases+=1
            fresh && (r.next_asset=id)
            update_peaks!(r)
            (d,lease)
        end
    end
end
function lookup_locked(r,d)
    d.namespace==r.namespace || revision_error(:invalid_input,d,"wrong registry namespace")
    r.closing && revision_error(:resource_unavailable,d,"registry is closed")
    entry=get(r.entries,key(d),nothing)
    entry===nothing && revision_error(:resource_unavailable,d,"exact revision is absent")
    d==entry.descriptor || revision_error(:invalid_input,d,"metadata does not match published revision")
    entry.pins>0 || revision_error(:resource_unavailable,d,"authority is draining")
    entry
end
function acquire_revision(r::RasterRegistry,d::V.RasterReference)
    lock(r.guard) do
        lease_locked(r,RevisionEntry[lookup_locked(r,d)])
    end
end
function retain_frame(r::RasterRegistry,frame::V.Frame)
    lock(r.guard) do
        r.closing && V.model_error(:resource_unavailable,"raster registry is closed")
        entries=RevisionEntry[]
        seen=Set{Tuple{UInt128,UInt64,UInt64}}()
        for record in frame.resources
            d=record.payload
            d isa V.RasterReference || continue
            entry=lookup_locked(r,d) # Validate even a duplicate with forged metadata.
            raster_identity(d) in seen && continue
            length(entries)<r.max_leases-r.leases || revision_error(:resource_limit,d,"Frame lease limit exceeded")
            push!(entries,entry)
            push!(seen,raster_identity(d))
        end
        lease_locked(r,entries)
    end
end
"""Independent pins from an open lease, including after registry close."""
function retain_revision(lease::RevisionLease)
    r=lease.registry
    lock(r.guard) do
        lease.closed && V.model_error(:resource_unavailable,"raster lease is closed")
        lease_locked(r,copy(lease.entries))
    end
end
V.retain_execution(lease::RevisionLease)=retain_revision(lease)
function Base.close(lease::RevisionLease)
    r=lease.registry
    retired=lock(r.guard) do
        lease.closed && return RevisionEntry[]
        dead=RevisionEntry[]
        sizehint!(dead,length(lease.entries))
        lease.closed=true
        r.leases-=max(1,length(lease.entries))
        for entry in lease.entries
            entry.pins-=1
            if entry.pins==0
                push!(dead,entry)
            end
        end
        empty!(lease.entries)
        dead
    end
    failures=Any[]
    for entry in retired
        try
            close(entry.source)
        catch error
            push!(failures,error)
        finally
            lock(r.guard) do
                delete!(r.entries,key(entry.descriptor))
                r.bytes-=entry.bytes
                if !any(k->k[1]==entry.descriptor.asset,keys(r.entries))
                    delete!(r.assets,entry.descriptor.asset)
                end
            end
            lock(authority_ownership_guard) do
                filter!(w->w.value!==nothing && w.value!==entry.source,authority_ownership)
            end
        end
    end
    isempty(failures) || throw(CompositeException(failures))
    nothing
end
function Base.close(r::RasterRegistry)
    lock(r.guard) do
        r.closing=true
    end
    nothing
end
function registry_usage(r::RasterRegistry)
    lock(r.guard) do
        (;source_bytes=r.bytes,assets=length(r.assets),revisions=length(r.entries),leases=r.leases,
          peak_source_bytes=r.peak_bytes,peak_assets=r.peak_assets,peak_revisions=r.peak_revisions,
          peak_leases=r.peak_leases,closing=r.closing,next_asset=r.next_asset,
          source_reads=r.source_reads,source_pixels=r.source_pixels,peak_region_bytes=r.peak_region_bytes,
          owned_index_entries=sum(e->e.source isa OwnedTileRevision ? e.source.chunk_count : 0,values(r.entries);init=0),
          owned_chunk_bytes=sum(e->e.source isa OwnedTileRevision ? e.source.payload_bytes : 0,values(r.entries);init=0),
          source_limit=r.source_bytes,asset_limit=r.max_assets,revision_limit=r.max_revisions,lease_limit=r.max_leases)
    end
end
function single_entry(lease)
    lock(lease.registry.guard) do
        lease.closed && V.model_error(:resource_unavailable,"raster lease is closed")
        length(lease.entries)==1 || V.model_error(:invalid_input,"region reads require one revision lease")
        only(lease.entries)
    end
end
function physical_metadata(d)
    m=d.metadata
    S.ImageMetadata(m.width,m.height;format=m.format,alpha=m.alpha,
                    color_space=m.color_space,orientation=m.orientation)
end
S.image_metadata(lease::RevisionLease)=physical_metadata(single_entry(lease).descriptor)
S.storage_revision(lease::RevisionLease)=single_entry(lease).tag
function acquire_revision(lease::RevisionLease,d::V.RasterReference)
    r=lease.registry
    lock(r.guard) do
        lease.closed && revision_error(:resource_unavailable,d,"lease is closed")
        d.namespace==r.namespace || revision_error(:invalid_input,d,"wrong registry namespace")
        found=findfirst(e->key(e.descriptor)==key(d),lease.entries)
        found===nothing && revision_error(:resource_unavailable,d,"revision not retained by lease")
        entry=lease.entries[found]
        d==entry.descriptor || revision_error(:invalid_input,d,"metadata mismatch")
        lease_locked(r,RevisionEntry[entry])
    end
end
function S.borrow_pixels(lease::RevisionLease,region;
                         access=:read,copy_policy=:forbid,budget_bytes=1024*1024,
                         revision=nothing,cancelled=()->false,kwargs...)
    access===:read && copy_policy===:allow ||
        throw(S.UnsupportedStorageError("revision lease regions require explicit independent staging"))
    isempty(kwargs) || throw(S.UnsupportedStorageError("use convert_buffer for revision conversion"))
    budget_bytes isa Integer && 0<=budget_bytes<=typemax(Int) ||
        V.model_error(:invalid_input,"region copy budget must be addressable")
    pin=retain_revision(lease)
    output=nothing
    try
        entry=single_entry(pin)
        metadata=physical_metadata(entry.descriptor)
        request=checked_region(metadata,region)
        revision===nothing || revision==entry.tag || revision_error(:invalid_input,entry.descriptor,"wrong provider tag")
        n=UInt128(request[3])*UInt128(request[4])*S.channels(metadata.format)
        n<=budget_bytes || revision_error(:resource_limit,entry.descriptor,"region staging exceeds budget")
        lock(pin.registry.guard) do
            r=pin.registry
            pixels=UInt128(request[3])*UInt128(request[4])
            r.source_reads<typemax(UInt64) && pixels<=typemax(UInt128)-r.source_pixels ||
                revision_error(:resource_limit,entry.descriptor,"source work counter exhausted")
            r.source_reads+=UInt64(1)
            r.source_pixels+=pixels
            r.peak_region_bytes=max(r.peak_region_bytes,Int(n))
        end
        report=lock(entry.guard) do
            cancelled() && throw(InterruptException())
            S.image_metadata(entry.source)==metadata && source_revision(entry.source)==entry.tag ||
                revision_error(:invalid_input,entry.descriptor,"authority metadata/tag changed")
            input=S.borrow_pixels(entry.source,request;access=:read,copy_policy=:allow,
                                  budget_bytes=budget_bytes-Int(n))
            try
                S.active(input)
                wanted=S.ImageMetadata(request[3],request[4];format=metadata.format,alpha=metadata.alpha,
                                       color_space=metadata.color_space,orientation=metadata.orientation)
                S.image_metadata(input.buffer)==wanted ||
                    revision_error(:invalid_input,entry.descriptor,"source lease metadata mismatch")
                input.report.copied_bytes<=budget_bytes-Int(n) ||
                    revision_error(:resource_limit,entry.descriptor,"source staging exceeds budget")
                output=S.allocate_buffer(request[3],request[4];format=metadata.format,alpha=metadata.alpha,
                                         color_space=metadata.color_space,budget_bytes)
                S.copy_pixels!(output,input)
                if metadata.alpha===:premultiplied
                    for i in 1:4:length(output.owner.bytes)
                        b=output.owner.bytes
                        max(b[i],b[i+1],b[i+2])<=b[i+3] ||
                            revision_error(:invalid_input,entry.descriptor,"invalid premultiplied source")
                    end
                end
                cancelled() && throw(InterruptException())
                S.image_metadata(entry.source)==metadata && source_revision(entry.source)==entry.tag ||
                    revision_error(:invalid_input,entry.descriptor,"authority changed during read")
                S.CopyReport(Int(n)+input.report.copied_bytes,(input.report.conversions...,:revision_region))
            finally
                close(input)
            end
        end
        # Source close/destruction is fallible; finish it before returning independent output.
        close(pin)
        result=S.new_lease(output,:read;close_buffer=true,report)
        output=nothing
        result
    finally
        try
            output===nothing || close(output)
        finally
            close(pin)
        end
    end
end
