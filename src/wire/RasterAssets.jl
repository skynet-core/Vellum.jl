# Included inside Wire after ImageTiles; no provider, path or callback enters portable data.
export RasterAssetStore, AssetLimits, AssetBinding, RasterManifest, asset_usage,
       canonical_manifest, parse_manifest, tile_digest, asset_binding, import_asset!,
       export_asset!, export_staging_bytes

const ASSET_TILE = 256
const ASSET_FORMATS = (:gray8,:rgb8,:bgr8,:rgba8,:bgra8)
const ASSET_ALPHAS = (:none,:straight,:premultiplied)
const ASSET_COLORS = (:srgb,:linear_srgb)
const MANIFEST_PREFIX = codeunits("VTRA-raster-v1\0")
const TILE_PREFIX = codeunits("VTRA-tile-v1\0")
const AssetKey = Tuple{UInt128,UInt64,UInt64}

struct AssetLimits
    tiles::Int
    asset_bytes::Int
    revisions::Int
    index_bytes::Int
    disk_bytes::Int
    chunks::Int
    history::Int
    sessions::Int
    transfers::Int
    reads::Int
    leases::Int
    cache_bytes::Int
    region_bytes::Int
    region_source_bytes::Int
    region_tiles::Int
    export_workspace::Int
    import_workspace::Int
end
function AssetLimits(;tiles=65536,asset_bytes=1024^3,revisions=32,index_bytes=8*1024^2,
                     disk_bytes=2*1024^3,chunks=65536,history=4096,sessions=8,
                     transfers=64,reads=4,leases=256,cache_bytes=16*1024^2,
                     region_bytes=1024^2,region_source_bytes=4*1024^2,region_tiles=64,
                     export_workspace=8*1024^2,import_workspace=4*1024^2)
    values=(tiles,asset_bytes,revisions,index_bytes,disk_bytes,chunks,history,sessions,
            transfers,reads,leases,cache_bytes,region_bytes,region_source_bytes,
            region_tiles,export_workspace,import_workspace)
    ceilings=(65536,1024^3,32,8*1024^2,2*1024^3,65536,4096,8,64,4,256,
              16*1024^2,1024^2,4*1024^2,64,8*1024^2,4*1024^2)
    check(all(v isa Integer && 0<v<=c for (v,c) in zip(values,ceilings)),
          "asset limits must be positive tightenings")
    AssetLimits(Int.(values)...)
end

asset_key(d::V.RasterReference) = (d.namespace,d.asset,d.revision)
asset_channels(m) = m.format === :gray8 ? 1 : m.format in (:rgb8,:bgr8) ? 3 : 4
function asset_shape(m,limits=AssetLimits())
    check(0<m.width<=typemax(Int64) && 0<m.height<=typemax(Int64) &&
          m.format in ASSET_FORMATS && m.color_space in ASSET_COLORS &&
          m.orientation === :top_left && m.storage === :tiled, "invalid asset metadata")
    check(asset_channels(m)==4 ? m.alpha in (:straight,:premultiplied) : m.alpha === :none,
          "invalid asset alpha")
    nx,ny=cld(UInt128(m.width),256),cld(UInt128(m.height),256)
    n=nx*ny
    bytes=UInt128(m.width)*UInt128(m.height)*asset_channels(m)
    check(n<=limits.tiles && bytes<=limits.asset_bytes, "asset dimensions exceed profile")
    (Int(nx),Int(ny),Int(n),Int(bytes))
end
function asset_tile_shape(m,index)
    nx,_,count,_=asset_shape(m)
    check(index isa Integer && 0<=index<count,"invalid asset tile index")
    x,y=Int(index)%nx*256,Int(index)÷nx*256
    (x,y,min(256,Int(m.width)-x),min(256,Int(m.height)-y))
end
asset_put(io,x::Unsigned)=write(io,htol(x))
function asset_get(io,::Type{T}) where T<:Unsigned
    ltoh(read(io,T))
end
function asset_bytes(io,n,cap)
    check(0<=n<=cap,"asset length exceeds limit")
    b=read(io,Int(n))
    check(length(b)==n,"truncated asset bytes")
    b
end
asset_digest(io)=Tuple(asset_bytes(io,32,32))::Digest
function asset_meta_write(io,m)
    asset_shape(m)
    asset_put(io,UInt64(m.width));asset_put(io,UInt64(m.height))
    for (v,table) in ((m.format,ASSET_FORMATS),(m.alpha,ASSET_ALPHAS),(m.color_space,ASSET_COLORS))
        asset_put(io,UInt8(findfirst(==(v),table)))
    end
    write(io,UInt8[1,1])
end
function asset_enum(io,table)
    n=asset_get(io,UInt8)
    check(1<=n<=length(table),"unknown asset metadata tag")
    table[n]
end
function asset_meta_read(io)
    w,h=asset_get(io,UInt64),asset_get(io,UInt64)
    check(0<w<=typemax(Int64) && 0<h<=typemax(Int64),"invalid asset dimensions")
    f=asset_enum(io,ASSET_FORMATS);a=asset_enum(io,ASSET_ALPHAS);c=asset_enum(io,ASSET_COLORS)
    check(asset_get(io,UInt8)==1 && asset_get(io,UInt8)==1,"unsupported asset layout")
    m=V.ImageMetadata(w,h;format=f,alpha=a,color_space=c,storage=:tiled)
    asset_shape(m)
    m
end
asset_key(b::AssetBinding)=asset_key(b.descriptor)
function binding_write(io,b::AssetBinding)
    d=b.descriptor
    asset_put(io,d.namespace);asset_put(io,d.asset);asset_put(io,d.revision)
    asset_meta_write(io,d.metadata);write(io,collect(b.root))
end
function binding_read(io)
    ns,id,rev=asset_get(io,UInt128),asset_get(io,UInt64),asset_get(io,UInt64)
    m=asset_meta_read(io)
    AssetBinding(V.RasterReference(ns,id,rev,m),asset_digest(io))
end
struct TileDigests <: AbstractVector{Digest}
    bytes::String
end
Base.size(d::TileDigests)=(ncodeunits(d.bytes)÷32,)
Base.IndexStyle(::Type{TileDigests})=IndexLinear()
function Base.getindex(d::TileDigests,i::Int)
    checkbounds(d,i)
    ntuple(j->codeunit(d.bytes,32(i-1)+j),32)
end
struct RasterManifest
    metadata::V.ImageMetadata
    digests::TileDigests
    root::Digest
end
function canonical_manifest(m,digests)
    _,_,count,_=asset_shape(m)
    check(length(digests)==count,"manifest tile count mismatch")
    io=IOBuffer()
    write(io,MANIFEST_PREFIX);asset_meta_write(io,m)
    asset_put(io,UInt16(256));asset_put(io,UInt32(count))
    for digest in digests
        check(digest isa Digest,"invalid manifest digest")
        write(io,collect(digest))
    end
    take!(io)
end
function parse_manifest(bytes;limits=AssetLimits(),expected=nothing)
    check(length(bytes)<=2*1024^2+64,"manifest byte limit")
    io=IOBuffer(bytes)
    check(asset_bytes(io,length(MANIFEST_PREFIX),32)==MANIFEST_PREFIX,"manifest magic")
    m=asset_meta_read(io)
    _,_,count,_=asset_shape(m,limits)
    check(asset_get(io,UInt16)==256 && asset_get(io,UInt32)==count,"manifest geometry/count")
    check(bytesavailable(io)==32count,"manifest exact boundary")
    digests=TileDigests(String(asset_bytes(io,32count,2*1024^2)))
    root=Tuple(sha256(bytes))::Digest
    expected===nothing || check(expected.root==root && expected.descriptor.metadata==m,
                                "manifest binding mismatch")
    RasterManifest(m,digests,root)
end
function tile_digest(m,index,pixels)
    _,_,w,h=asset_tile_shape(m,index)
    n=w*h*asset_channels(m)
    check(length(pixels)==n,"tile pixel length mismatch")
    if m.alpha===:premultiplied
        for i in 1:4:n
            check(max(pixels[i],pixels[i+1],pixels[i+2])<=pixels[i+3],"invalid premultiplied asset")
        end
    end
    io=IOBuffer()
    write(io,TILE_PREFIX);asset_put(io,UInt16(w));asset_put(io,UInt16(h))
    write(io,UInt8[findfirst(==(m.format),ASSET_FORMATS),findfirst(==(m.alpha),ASSET_ALPHAS),
                   findfirst(==(m.color_space),ASSET_COLORS),1])
    asset_put(io,UInt32(n))
    ctx=SHA.SHA2_256_CTX()
    SHA.update!(ctx,take!(io));SHA.update!(ctx,pixels)
    Tuple(SHA.digest!(ctx))::Digest
end
manifest_charge(m::RasterManifest)=length(MANIFEST_PREFIX)+27+32length(m.digests)

"""
Keep the first binding and zero-based tile index for one canonical digest.
Track its decoded shape and the number of distinct catalog references.
"""
mutable struct AssetLayoutTile
    first_record::Int
    index::Int
    length::Int
    shape::Tuple{Int,Int,Symbol,Symbol,Symbol}
    last_record::Int
    references::Int
end

"""
    asset_layout(manifests, limits; cancelled)

Index distinct digests in binding and tile order. Check compatible tile shapes,
archive index, chunk and disk limits without reading any chunks. Return the
index and its exact disk, manifest and largest-chunk byte counts. An invalid
layout raises ArgumentError. A cancelled build raises InterruptException.
"""
function asset_layout(manifests, limits; cancelled=()->false)
    tiles=Dict{Digest,AssetLayoutTile}()
    disk_bytes=0
    index_bytes=0
    largest=0
    for (record,manifest) in enumerate(manifests)
        cancelled() && throw(InterruptException())
        index_bytes+=manifest_charge(manifest)
        check(index_bytes<=limits.index_bytes,"archive index limit")
        metadata=manifest.metadata
        asset_shape(metadata,limits)
        for (j,digest) in enumerate(manifest.digests)
            _,_,w,h=asset_tile_shape(metadata,j-1)
            shape=(w,h,metadata.format,metadata.alpha,metadata.color_space)
            existing=get(tiles,digest,nothing)
            if existing===nothing
                n=w*h*asset_channels(metadata)
                check(length(tiles)<limits.chunks && n<=limits.disk_bytes-disk_bytes,
                      "archive disk/chunk limit")
                tiles[digest]=AssetLayoutTile(record,j-1,n,shape,record,1)
                disk_bytes+=n
                largest=max(largest,n)
            else
                check(existing.shape==shape,"archive digest reused with different tile shape")
                if existing.last_record!=record
                    existing.last_record=record
                    existing.references+=1
                end
            end
        end
    end
    (;tiles,disk_bytes,index_bytes,largest)
end

mutable struct AssetRecord
    binding::AssetBinding
    manifest::RasterManifest
    pins::Int
end
mutable struct RasterAssetStore
    directory::String
    limits::AssetLimits
    records::Dict{AssetKey,AssetRecord}
    history::Dict{AssetKey,AssetBinding}
    chunks::Dict{Digest,Tuple{Int,Int}}
    disk_bytes::Int
    index_bytes::Int
    builder::Bool
    sessions::Int
    transfers::Int
    reads::Int
    leases::Int
    closing::Bool
    terminal::Bool
    released::Bool
    guard::ReentrantLock
end
chunk_path(s,d)=joinpath(s.directory,bytes2hex(collect(d))*".tile")
function asset_usage(s::RasterAssetStore)
    lock(s.guard) do
        (;disk_bytes=s.disk_bytes,index_bytes=s.index_bytes,chunks=length(s.chunks),
          revisions=length(s.records),history=length(s.history),builder=s.builder,
          sessions=s.sessions,transfers=s.transfers,reads=s.reads,leases=s.leases,
          closing=s.closing,terminal=s.terminal)
    end
end
function store_open(s)
    check(!s.closing && !s.terminal,"asset store closed or terminal")
end
function asset_binding(s::RasterAssetStore,d::V.RasterReference)
    lock(s.guard) do
        store_open(s)
        rec=get(s.records,asset_key(d),nothing)
        check(rec!==nothing && rec.binding.descriptor==d,"complete exact asset unavailable")
        rec.binding
    end
end
function check_binding(s,b)
    asset_shape(b.descriptor.metadata,s.limits)
    known=get(s.history,asset_key(b),nothing)
    check(known===nothing || known==b,"immutable foreign asset binding conflict")
    check(known!==nothing || length(s.history)<s.limits.history,"asset history limit")
end

# One builder owns object/catalog installation. Store locks cover admission only, never file IO.
mutable struct AssetBuilder
    store::RasterAssetStore
    created::Set{Digest}
    created_bytes::Int
    reserved_bytes::Int
    reserved_chunks::Int
    lease_reserved::Bool
    closed::Bool
end
function begin_asset(s;reserve_bytes=0,reserve_chunks=0)
    lock(s.guard) do
        store_open(s)
        check(!s.builder,"asset builder busy")
        check(0<=reserve_bytes<=s.limits.disk_bytes-s.disk_bytes &&
              0<=reserve_chunks<=s.limits.chunks-length(s.chunks),"asset disk/chunk reservation limit")
        check(s.leases<s.limits.leases,"asset builder publication lease limit")
        s.builder=true
        s.leases+=1
        AssetBuilder(s,Set{Digest}(),0,Int(reserve_bytes),Int(reserve_chunks),true,false)
    end
end
function atomic_asset_file(callback,s,destination;replace=false)
    temp,io=mktemp(s.directory;cleanup=false)
    try
        callback(io)
        flush(io);close(io)
        check(replace || !ispath(destination),"asset destination already exists")
        Base.Filesystem.rename(temp,destination)
        temp=nothing
    finally
        isopen(io) && close(io)
        temp===nothing || rm(temp;force=true)
    end
    nothing
end
function read_asset_tile(s,m,index;cancelled=()->false)
    cancelled() && throw(InterruptException())
    d=m.digests[index+1];_,_,w,h=asset_tile_shape(m.metadata,index)
    n=w*h*asset_channels(m.metadata)
    path=chunk_path(s,d)
    check(isfile(path),"asset tile unavailable")
    check(filesize(path)==n,"asset tile length integrity")
    pixels=open(path,"r") do io
        asset_bytes(io,n,262144)
    end
    check(tile_digest(m.metadata,index,pixels)==d,"asset tile digest integrity")
    cancelled() && throw(InterruptException())
    pixels
end
function stage_asset_tile!(b,m,index,pixels;cancelled=()->false)
    s=b.store
    check(!b.closed,"asset builder closed")
    cancelled() && throw(InterruptException())
    d=tile_digest(m.metadata,index,pixels)
    check(d==m.digests[index+1],"asset tile expected digest mismatch")
    if haskey(s.chunks,d)
        read_asset_tile(s,m,index;cancelled)
        return false
    end
    stage_asset_chunk!(b,d,pixels;cancelled)
end
function stage_asset_chunk!(b,d,pixels;cancelled=()->false)
    s=b.store
    d in b.created && return false
    check(length(pixels)<=b.reserved_bytes && b.reserved_chunks>0,"asset reservation exhausted")
    push!(b.created,d)
    atomic_asset_file(s,chunk_path(s,d)) do io
        cancelled() && throw(InterruptException())
        write(io,pixels)
        cancelled() && throw(InterruptException())
    end
    b.created_bytes+=length(pixels)
    b.reserved_bytes-=length(pixels);b.reserved_chunks-=1
    true
end

"""Maximum adapter staging for one canonical tile; adapters must explicitly declare bounded reads."""
export_staging_bytes(source)=throw(ArgumentError("wire: export adapter has no bounded staging declaration"))
export_staging_bytes(source::V.ImageTiles.OwnedTileRevision)=min(source.max_region_bytes,262144)
function export_asset!(s::RasterAssetStore,registry,d::V.RasterReference;cancelled=()->false)
    m=d.metadata
    _,_,count,total=asset_shape(m,s.limits)
    builder=begin_asset(s)
    pin=nothing
    try
        pin=V.ImageTiles.acquire_revision(registry,d)
        entry=V.ImageTiles.single_entry(pin)
        staging=export_staging_bytes(entry.source)
        check(staging isa Integer && 0<=staging<=s.limits.export_workspace,
              "invalid declared export staging")
        largest=min(256,Int(m.width))*min(256,Int(m.height))*asset_channels(m)
        # Adapter input + registry output + canonical packed bytes/hash staging.
        workspace=staging+2largest+256
        check(workspace<=s.limits.export_workspace,"asset export workspace limit")
        digestio=IOBuffer()
        remaining_tiles=count;remaining_bytes=total
        for i in 0:count-1
            cancelled() && throw(InterruptException())
            x,y,w,h=asset_tile_shape(m,i);n=w*h*asset_channels(m)
            check(remaining_tiles>0 && n<=remaining_bytes,"asset export work exhausted")
            input=V.ImageStorage.borrow_pixels(pin,(x,y,w,h);access=:read,copy_policy=:allow,
                                               budget_bytes=staging+n,cancelled)
            pixels=try
                V.ImageStorage.active(input)
                check(input.report.copied_bytes<=staging+n,"export staging report exceeded declaration")
                packed=Vector{UInt8}(undef,n)
                desc=input.buffer.descriptor
                check(desc.pixel_stride==asset_channels(m),"export revision staging must be packed pixels")
                # The independent read lease remains open throughout the explicit row copy.
                for row in 0:h-1
                    copyto!(packed,row*w*asset_channels(m)+1,input.buffer.owner.bytes,
                            desc.offset+row*desc.row_stride+1,w*asset_channels(m))
                end
                packed
            finally
                close(input)
            end
            digest=tile_digest(m,i,pixels)
            if haskey(s.chunks,digest)
                path=chunk_path(s,digest)
                check(isfile(path) && filesize(path)==n,"export retained chunk unavailable")
                stored=open(io->asset_bytes(io,n,262144),path,"r")
                check(tile_digest(m,i,stored)==digest,"export retained chunk integrity")
            elseif !(digest in builder.created)
                check(n<=s.limits.disk_bytes-s.disk_bytes-builder.created_bytes &&
                      length(builder.created)<s.limits.chunks-length(s.chunks),"export disk/chunk limit")
                builder.reserved_bytes=n;builder.reserved_chunks=1
                stage_asset_chunk!(builder,digest,pixels;cancelled)
            end
            write(digestio,collect(digest))
            remaining_tiles-=1;remaining_bytes-=n
        end
        check(remaining_tiles==0 && remaining_bytes==0,"incomplete asset export")
        bytes=canonical_manifest(m,TileDigests(String(take!(digestio))))
        manifest=parse_manifest(bytes;limits=s.limits)
        binding=AssetBinding(d,manifest.root)
        check_binding(s,binding)
        rec=commit_asset!(builder,binding,manifest;cancelled)
        publication=pin_asset(s,rec;admitted=true,reservation=builder)
        try
            close(pin)
        catch
            close(publication)
            rethrow()
        end
        pin=nothing
        (publication,binding)
    finally
        try
            pin===nothing || close(pin)
        finally
            close(builder)
        end
    end
end
function write_catalog(s,records,history;cancelled=()->false)
    atomic_asset_file(s,joinpath(s.directory,"catalog");replace=true) do io
        write(io,codeunits("VTRS"));asset_put(io,UInt16(1));asset_put(io,UInt16(0))
        asset_put(io,UInt32(length(history)));asset_put(io,UInt32(length(records)))
        for key in sort!(collect(keys(history)))
            cancelled() && throw(InterruptException())
            binding_write(io,history[key])
        end
        for key in sort!(collect(keys(records)))
            rec=records[key];binding_write(io,rec.binding)
            bytes=canonical_manifest(rec.manifest.metadata,rec.manifest.digests)
            asset_put(io,UInt32(length(bytes)));write(io,bytes)
        end
        cancelled() && throw(InterruptException())
    end
end
function commit_asset!(builder,binding,manifest;cancelled=()->false)
    s=builder.store
    check(!builder.closed && binding.root==manifest.root &&
          binding.descriptor.metadata==manifest.metadata,"asset commit binding")
    check_binding(s,binding)
    existing=get(s.records,asset_key(binding),nothing)
    if existing!==nothing
        check(existing.binding==binding,"asset complete binding conflict")
        lock(s.guard) do
            s.builder=false;builder.closed=true
        end
        return existing
    end
    check(length(s.records)<s.limits.revisions,"asset revision limit")
    charge=manifest_charge(manifest)
    check(charge<=s.limits.index_bytes-s.index_bytes,"asset index limit")
    records=copy(s.records);history=copy(s.history);chunks=copy(s.chunks)
    rec=AssetRecord(binding,manifest,0)
    records[asset_key(binding)]=rec;history[asset_key(binding)]=binding
    disk=s.disk_bytes
    seen=Set{Digest}()
    for (j,d) in enumerate(manifest.digests)
        d in seen && continue
        push!(seen,d)
        i=j-1
        _,_,w,h=asset_tile_shape(manifest.metadata,i);n=w*h*asset_channels(manifest.metadata)
        check(haskey(chunks,d) || d in builder.created,"incomplete asset commit")
        if haskey(chunks,d)
            bytes,refs=chunks[d];check(bytes==n,"asset chunk shape conflict")
            chunks[d]=(bytes,refs+1)
        else
            chunks[d]=(n,1);disk+=n
        end
    end
    cancelled() && throw(InterruptException())
    # Catalog replacement is the only publication point; no cancellation after it.
    write_catalog(s,records,history;cancelled)
    lock(s.guard) do
        s.records=records;s.history=history;s.chunks=chunks
        s.disk_bytes=disk;s.index_bytes+=charge;s.builder=false
        builder.closed=true
    end
    rec
end
function Base.close(b::AssetBuilder)
    s=b.store
    if b.lease_reserved
        lock(s.guard) do
            b.lease_reserved=false;s.leases-=1
        end
    end
    b.closed && (drain_asset_store(s);return nothing)
    b.closed=true
    failure=nothing
    try
        for d in b.created
            rm(chunk_path(s,d);force=true)
        end
    catch e
        failure=e
    finally
        lock(s.guard) do
            s.builder=false
            failure===nothing || (s.terminal=true)
        end
    end
    failure===nothing || throw(failure)
    drain_asset_store(s)
    nothing
end

function asset_unique_tiles(m)
    entries=Dict{Digest,Tuple{Int,Int,Int,Int}}()
    for (j,d) in enumerate(m.digests)
        _,_,w,h=asset_tile_shape(m.metadata,j-1)
        value=(j-1,w*h*asset_channels(m.metadata),w,h)
        if haskey(entries,d)
            check(entries[d][2:4]==value[2:4],"manifest digest reused with different shape")
        else
            entries[d]=value
        end
    end
    entries
end

mutable struct AssetPublication
    store::RasterAssetStore
    record::AssetRecord
    closed::Bool
end
function pin_asset(s,rec;admitted=false,reservation=nothing)
    lock(s.guard) do
        admitted || store_open(s)
        reserved=reservation!==nothing && reservation.lease_reserved
        check(!s.terminal && (reserved || s.leases<s.limits.leases),"asset publication lease limit")
        check(get(s.records,asset_key(rec.binding),nothing)===rec,"asset revision retired")
        p=AssetPublication(s,rec,false)
        if reserved
            reservation.lease_reserved=false
        else
            s.leases+=1
        end
        rec.pins+=1
        p
    end
end
function Base.close(p::AssetPublication)
    s=p.store
    lock(s.guard) do
        p.closed && return nothing
        p.closed=true
        p.record.pins-=1;s.leases-=1
    end
    drain_asset_store(s)
end
asset_binding(p::AssetPublication)=lock(p.store.guard) do
    check(!p.closed,"asset publication closed")
    p.record.binding
end

function import_asset_tiles!(s,binding,manifest_bytes,fetch_tile;cancelled=()->false)
    m=parse_manifest(manifest_bytes;limits=s.limits,expected=binding)
    unique_tiles=asset_unique_tiles(m)
    builder=begin_asset(s)
    try
        check_binding(s,binding)
        rec=get(s.records,asset_key(binding),nothing)
        if rec!==nothing
            for (_,value) in unique_tiles
                read_asset_tile(s,rec.manifest,value[1];cancelled)
            end
            return pin_asset(s,rec;admitted=true,reservation=builder)
        end
        check(length(s.records)<s.limits.revisions &&
              manifest_charge(m)<=s.limits.index_bytes-s.index_bytes,"asset revision/index limit")
        missing=Dict(d=>v for (d,v) in unique_tiles if !haskey(s.chunks,d))
        total=sum(v->v[2],values(missing);init=0)
        check(total<=s.limits.disk_bytes-s.disk_bytes &&
              length(missing)<=s.limits.chunks-length(s.chunks),"asset import disk/chunk limit")
        # Input, hash verification and one staging buffer are all charged before any fetch.
        largest=maximum(v->v[2],values(unique_tiles);init=0)
        check(3largest+256<=s.limits.import_workspace,"asset import workspace limit")
        builder.reserved_bytes=total;builder.reserved_chunks=length(missing)
        remaining_tiles=length(missing);remaining_bytes=total
        for (d,v) in unique_tiles
            cancelled() && throw(InterruptException())
            i,n,_,_=v
            if haskey(s.chunks,d)
                read_asset_tile(s,m,i;cancelled)
            else
                check(remaining_tiles>0 && n<=remaining_bytes,"asset import work exhausted")
                pixels=fetch_tile(i,d,n)
                check(length(pixels)==n,"asset response length")
                stage_asset_tile!(builder,m,i,pixels;cancelled)
                remaining_tiles-=1;remaining_bytes-=n
            end
        end
        check(remaining_tiles==0 && remaining_bytes==0,"incomplete asset import")
        # Reserve the returned ownership before the durable commit can become visible.
        rec=commit_asset!(builder,binding,m;cancelled)
        pin_asset(s,rec;admitted=true,reservation=builder)
    finally
        close(builder)
    end
end
"""
    load_asset_catalog!(store) -> nothing

Load the existing catalog into a newly reserved store. Validate every manifest
and its tile interpretations and quotas before opening any chunk files. Verify
each distinct chunk once and keep the count of distinct referencing records.
An invalid catalog or unreadable chunk raises an error before the store opens.
"""
function load_asset_catalog!(s)
    open(joinpath(s.directory,"catalog"),"r") do io
        check(filesize(io)<=s.limits.index_bytes+117s.limits.history+4096,"store catalog limit")
        check(asset_bytes(io,4,4)==codeunits("VTRS") && asset_get(io,UInt16)==1 &&
              asset_get(io,UInt16)==0,"store catalog header")
        nh,nr=asset_get(io,UInt32),asset_get(io,UInt32)
        check(nh<=s.limits.history && nr<=s.limits.revisions,"store catalog count")
        previous=nothing
        for _ in 1:nh
            b=binding_read(io);key=asset_key(b)
            check(previous===nothing || previous<key,"store history order")
            asset_shape(b.descriptor.metadata,s.limits)
            s.history[key]=b;previous=key
        end
        manifests=RasterManifest[]
        index_bytes=0
        previous=nothing
        for _ in 1:nr
            b=binding_read(io);key=asset_key(b)
            check(previous===nothing || previous<key,"store record order")
            check(get(s.history,key,nothing)==b,"store record history mismatch")
            n=asset_get(io,UInt32)
            m=parse_manifest(asset_bytes(io,n,min(s.limits.index_bytes-index_bytes,2*1024^2+64));
                             limits=s.limits,expected=b)
            index_bytes+=manifest_charge(m)
            s.records[key]=AssetRecord(b,m,0);previous=key
            push!(manifests,m)
        end
        check(eof(io),"trailing store catalog")
        layout=asset_layout(manifests,s.limits)
        for (digest,tile) in layout.tiles
            read_asset_tile(s,manifests[tile.first_record],tile.index)
            s.chunks[digest]=(tile.length,tile.references)
        end
        s.index_bytes,s.disk_bytes=layout.index_bytes,layout.disk_bytes
    end
    nothing
end
function RasterAssetStore(directory::AbstractString;limits=AssetLimits())
    directory=abspath(directory)
    fresh=!ispath(directory)
    fresh ? mkdir(directory;mode=0o700) : check(isdir(directory) && isfile(joinpath(directory,"catalog")),
                                               "store requires a new directory or committed catalog")
    lockpath=joinpath(directory,"writer")
    mkdir(lockpath;mode=0o700) # Exclusive host ownership; stale locks require explicit host recovery.
    s=RasterAssetStore(directory,limits,Dict{AssetKey,AssetRecord}(),Dict{AssetKey,AssetBinding}(),
                       Dict{Digest,Tuple{Int,Int}}(),0,0,false,0,0,0,0,false,false,false,ReentrantLock())
    try
        fresh ? write_catalog(s,s.records,s.history) : load_asset_catalog!(s)
    catch
        rm(lockpath)
        rethrow()
    end
    s
end
function drain_asset_store(s)
    release=lock(s.guard) do
        if s.closing && !s.released && !s.builder && s.sessions==0 && s.transfers==0 &&
           s.reads==0 && s.leases==0
            s.released=true
            true
        else
            false
        end
    end
    release && rm(joinpath(s.directory,"writer"))
    nothing
end
function Base.close(s::RasterAssetStore)
    lock(s.guard) do
        s.closing=true
    end
    drain_asset_store(s)
end

export AssetService, AssetClient, serve_asset!, asset_request!, import_asset!
const VTRA_HEADER = 40
asset_message_cap(tag)=tag==2 ? 2*1024^2+256 : tag==4 ? 256*1024+256 : 256
"""
    write_asset_header(io, tag, session, request, body_length)

Write one fixed VTRA record header. Reject invalid type, identity or length
before writing. The caller writes exactly the declared body afterward.
"""
function write_asset_header(io,tag,session,request,body_length)
    check(tag in 1:8 && 0<=session<=typemax(UInt128) && 0<=request<=typemax(UInt64),
          "invalid VTRA identity/type")
    check(0<=body_length<=asset_message_cap(tag)-VTRA_HEADER,"VTRA body limit")
    write(io,codeunits("VTRA"))
    asset_put(io,UInt16(1))
    asset_put(io,UInt16(0))
    asset_put(io,UInt8(tag))
    asset_put(io,UInt8(0))
    asset_put(io,UInt16(0))
    asset_put(io,UInt128(session))
    asset_put(io,UInt64(request))
    asset_put(io,UInt32(body_length))
    nothing
end

"""Return a complete VTRA record with the supplied bounded body bytes."""
function asset_envelope(tag,session,request,body)
    io=IOBuffer()
    write_asset_header(io,tag,session,request,length(body))
    write(io,body)
    take!(io)
end

"""
    read_asset_header(io; offline=false)

Read the fixed VTRA header and return its type, session, request and bounded
body length. Reject a missing or malformed header before reading any body.
"""
function read_asset_header(io;offline=false)
    header=IOBuffer(asset_bytes(io,VTRA_HEADER,VTRA_HEADER))
    check(asset_bytes(header,4,4)==codeunits("VTRA") &&
          asset_get(header,UInt16)==1 && asset_get(header,UInt16)==0,"VTRA header")
    tag=asset_get(header,UInt8)
    check(tag in 1:8 && asset_get(header,UInt8)==0 && asset_get(header,UInt16)==0,"VTRA flags/type")
    session,request=asset_get(header,UInt128),asset_get(header,UInt64)
    check(offline ? session==0 && request==0 && tag in (2,4) : session>0 && request>0,
          "VTRA session/request")
    n=asset_get(header,UInt32)
    check(n<=asset_message_cap(tag)-VTRA_HEADER,"asset length exceeds limit")
    (Int(tag),session,request,n)
end
"""Read one bounded VTRA message, validating its envelope before the body."""
function read_asset_message(io;offline=false)
    tag,session,request,n=read_asset_header(io;offline)
    (tag,session,request,asset_bytes(io,n,asset_message_cap(tag)-VTRA_HEADER))
end
function asset_body(callback)
    io=IOBuffer();callback(io);take!(io)
end
asset_error(session,request,code)=asset_envelope(7,session,request,asset_body(io->asset_put(io,UInt16(code))))
mutable struct AssetService
    store::RasterAssetStore
    session::UInt128
    namespaces::Set{UInt128}
    last_request::UInt64
    next_lease::UInt64
    leases::Dict{UInt64,AssetPublication}
    data_request::UInt64
    cancellation::Union{Nothing,Threads.Atomic{Bool}}
    control::Bool
    closed::Bool
    guard::ReentrantLock
end
function AssetService(s::RasterAssetStore;session::Integer,namespaces)
    check(0<session<=typemax(UInt128),"invalid host asset session")
    check(0<length(namespaces)<=s.limits.revisions && all(n->0<n<=typemax(UInt128),namespaces),
          "invalid host namespace authority")
    allowed=Set(UInt128.(namespaces))
    lock(s.guard) do
        store_open(s)
        check(s.sessions<s.limits.sessions,"asset session limit")
        result=AssetService(s,UInt128(session),allowed,0,0,Dict{UInt64,AssetPublication}(),
                            0,nothing,false,false,ReentrantLock())
        s.sessions+=1
        result
    end
end
function Base.close(service::AssetService)
    pins=lock(service.guard) do
        service.closed && return AssetPublication[]
        service.closed=true
        service.cancellation===nothing || (service.cancellation[]=true)
        pins=collect(values(service.leases));empty!(service.leases)
        lock(service.store.guard) do
            service.store.sessions-=1
            service.store.transfers-=length(pins)
        end
        pins
    end
    foreach(close,pins)
    drain_asset_store(service.store)
end
function service_admit(service,tag,session,request)
    lock(service.guard) do
        check(!service.closed && session==service.session,"asset session closed/mismatch")
        check(request>service.last_request,"asset request replay/order")
        check(tag in (1,3,5,8),"unexpected asset service response")
        control=tag in (5,8)
        check(control ? !service.control : service.data_request==0,"asset request busy")
        token=Threads.Atomic{Bool}(false)
        service.last_request=request
        if control
            service.control=true
        else
            service.data_request=request;service.cancellation=token
        end
        token
    end
end
function service_finish(service,tag)
    lock(service.guard) do
        if tag in (5,8)
            service.control=false
        else
            service.data_request=0;service.cancellation=nothing
        end
    end
end
function service_response(service,tag,request,body,token;cancelled=()->false)
    s=service.store;io=IOBuffer(body)
    stop=()->token[] || cancelled()
    pin=nothing;read_admitted=false
    try
        if tag==1
            b=binding_read(io);check(eof(io),"OPEN exact boundary")
            check(b.descriptor.namespace in service.namespaces,"asset namespace outside host authority")
            stop() && return (asset_error(service.session,request,5),nothing,false)
            pin=lock(s.guard) do
                store_open(s)
                rec=get(s.records,asset_key(b),nothing)
                check(rec!==nothing && rec.binding==b,"OPEN exact complete binding unavailable")
                pin_asset(s,rec)
            end
            lease=lock(service.guard) do
                check(!service.closed && !stop(),"OPEN cancelled/closed")
                check(service.next_lease<typemax(UInt64),"asset transfer counter exhausted")
                lock(s.guard) do
                    check(s.transfers<s.limits.transfers,"asset transfer lease limit")
                    s.transfers+=1
                end
                id=service.next_lease+UInt64(1)
                try
                    service.leases[id]=pin
                catch
                    lock(s.guard) do
                        s.transfers-=1
                    end
                    rethrow()
                end
                service.next_lease=id;id
            end
            manifest=canonical_manifest(pin.record.manifest.metadata,pin.record.manifest.digests)
            response=asset_envelope(2,service.session,request,asset_body() do out
                asset_put(out,lease);asset_put(out,UInt32(length(manifest)));write(out,manifest)
            end)
            pin=nothing # Session transfer ownership now outlives the response.
            return (response,nothing,false)
        elseif tag==3
            lease,index=asset_get(io,UInt64),asset_get(io,UInt32)
            check(eof(io),"GET exact boundary")
            pin=lock(service.guard) do
                publication=get(service.leases,lease,nothing)
                check(publication!==nothing && !publication.closed,"GET unknown lease")
                pin_asset(s,publication.record;admitted=true)
            end
            lock(s.guard) do
                check(s.reads<s.limits.reads,"asset active read limit")
                s.reads+=1;read_admitted=true
            end
            m=pin.record.manifest
            check(index<length(m.digests),"GET invalid index")
            pixels=read_asset_tile(s,m,Int(index);cancelled=stop)
            response=asset_envelope(4,service.session,request,asset_body() do out
                asset_put(out,lease);asset_put(out,index);write(out,collect(m.digests[index+1]))
                asset_put(out,UInt32(length(pixels)));write(out,pixels)
            end)
            return (response,pin,read_admitted)
        elseif tag==5
            lease=asset_get(io,UInt64);check(eof(io),"RELEASE exact boundary")
            old=lock(service.guard) do
                check(haskey(service.leases,lease),"RELEASE unknown lease")
                pop!(service.leases,lease)
            end
            lock(s.guard) do
                s.transfers-=1
            end
            close(old)
            return (asset_envelope(6,service.session,request,asset_body(out->asset_put(out,lease))),nothing,false)
        else
            target=asset_get(io,UInt64);check(eof(io),"CANCEL exact boundary")
            cancelled_target=lock(service.guard) do
                if service.data_request==target && target!=0
                    service.cancellation[]=true;true
                else
                    false
                end
            end
            return (cancelled_target ?
                asset_envelope(6,service.session,request,asset_body(out->asset_put(out,UInt64(0)))) :
                asset_error(service.session,request,5),nothing,false)
        end
    catch
        pin===nothing || close(pin)
        if read_admitted
            lock(s.guard) do
                s.reads-=1
            end
        end
        rethrow()
    end
end
function serve_asset!(service::AssetService,input::IO,output::IO;cancelled=()->false)
    tag,session,request,body=read_asset_message(input)
    token=service_admit(service,tag,session,request)
    pin=nothing;reading=false
    try
        response,pin,reading=try
            service_response(service,tag,request,body,token;cancelled)
        catch error
            error isa InterruptException || error isa ArgumentError || error isa EOFError || rethrow()
            (asset_error(session,request,error isa InterruptException ? 5 : 4),nothing,false)
        end
        write(output,response);flush(output)
    finally
        try
            pin===nothing || close(pin)
        finally
            if reading
                lock(service.store.guard) do
                    service.store.reads-=1
                end
                drain_asset_store(service.store)
            end
            service_finish(service,tag)
        end
    end
    nothing
end

mutable struct AssetClientRequest
    tag::Int
    response::Union{Nothing,Tuple{Int,Vector{UInt8}}}
end
mutable struct AssetClient
    session::UInt128
    input::IO
    output::IO
    next_request::UInt64
    pending::Dict{UInt64,AssetClientRequest}
    closed::Bool
    guard::ReentrantLock
    input_guard::ReentrantLock
end
function AssetClient(input::IO,output::IO;session::Integer)
    check(0<session<=typemax(UInt128),"invalid client session")
    AssetClient(UInt128(session),input,output,0,Dict{UInt64,AssetClientRequest}(),
                false,ReentrantLock(),ReentrantLock())
end
function start_asset_request!(client::AssetClient,tag,body)
    lock(client.guard) do
        check(!client.closed && client.next_request<typemax(UInt64),"asset client closed/exhausted")
        check(tag in (1,3,5,8),"asset client request type")
        control=tag in (5,8)
        check(!any(r->(r.tag in (5,8))==control,values(client.pending)),"asset client request busy")
        request=client.next_request+UInt64(1);client.next_request=request
        client.pending[request]=AssetClientRequest(tag,nothing)
        try
            write(client.output,asset_envelope(tag,client.session,request,body));flush(client.output)
        catch
            client.closed=true # No retry/replay after uncertain transport completion.
            rethrow()
        end
        request
    end
end
function complete_asset_request!(client::AssetClient,request)
    while true
        result=lock(client.guard) do
            check(!client.closed && haskey(client.pending,request),"asset client closed/unknown request")
            rec=client.pending[request]
            if rec.response!==nothing
                delete!(client.pending,request)
                rec.response
            else
                nothing
            end
        end
        if result!==nothing
            if result[1]==7
                io=IOBuffer(result[2]);code=asset_get(io,UInt16)
                check(eof(io) && code in 1:7,"asset ERROR malformed")
                throw(ArgumentError("wire: asset service error code $code"))
            end
            return result
        end
        lock(client.input_guard) do
            ready=lock(client.guard) do
                client.closed || !haskey(client.pending,request) || client.pending[request].response!==nothing
            end
            ready && return
            try
                tag,session,id,bytes=read_asset_message(client.input)
                lock(client.guard) do
                    check(!client.closed && session==client.session && haskey(client.pending,id),
                          "unsolicited asset response identity")
                    rec=client.pending[id]
                    check(rec.response===nothing,"duplicate asset response")
                    check(tag==7 || tag==(rec.tag==1 ? 2 : rec.tag==3 ? 4 : 6),"unexpected asset response type")
                    rec.response=(tag,bytes)
                end
            catch
                lock(client.guard) do
                    client.closed=true
                end
                rethrow()
            end
        end
    end
end
function asset_request!(client::AssetClient,tag,body)
    complete_asset_request!(client,start_asset_request!(client,tag,body))
end
function Base.close(client::AssetClient)
    lock(client.guard) do
        client.closed=true
    end
    nothing
end
function import_asset!(s::RasterAssetStore,client::AssetClient,b::AssetBinding;cancelled=()->false)
    lease=UInt64(0)
    try
        _,response=asset_request!(client,1,asset_body(io->binding_write(io,b)))
        io=IOBuffer(response);lease=asset_get(io,UInt64)
        check(lease>0,"invalid OPEN transfer lease")
        n=asset_get(io,UInt32);manifest=asset_bytes(io,n,2*1024^2+64)
        check(eof(io),"MANIFEST exact boundary")
        fetch=function(index,digest,length)
            cancelled() && throw(InterruptException())
            _,response=asset_request!(client,3,asset_body() do out
                asset_put(out,lease);asset_put(out,UInt32(index))
            end)
            io=IOBuffer(response)
            check(asset_get(io,UInt64)==lease && asset_get(io,UInt32)==index &&
                  asset_digest(io)==digest && asset_get(io,UInt32)==length,"TILE response binding")
            pixels=asset_bytes(io,length,262144);check(eof(io),"TILE exact boundary")
            pixels
        end
        import_asset_tiles!(s,b,manifest,fetch;cancelled)
    finally
        if lease>0 && !client.closed
            _,response=asset_request!(client,5,asset_body(io->asset_put(io,lease)))
            io=IOBuffer(response)
            check(asset_get(io,UInt64)==lease && eof(io),"RELEASED lease/boundary")
        end
    end
end

export RasterAssetResolver, AssetRevisionLease, resolver_usage

# Resolver state and publication pins use the store guard, in that order only.
"""
    RasterAssetResolver

Associate a host-owned `RasterAssetStore` with the raster resolution protocol.

New region reads are bounded by the store limits. Construct the resolver with
`RasterAssetResolver(store)`, acquire the revisions you need and release their
leases when finished.
"""
mutable struct RasterAssetResolver <: V.ImageTiles.AbstractRasterResolver
    store::RasterAssetStore
    leases::Int
    reads::UInt64
    io_bytes::UInt128
    io_reserved::UInt128
    closed::Bool
end
"""
    RasterAssetResolver(store::RasterAssetStore)

Create a resolver with independent zeroed counters for `store`. Construction
opens no additional files. The caller retains ownership of the store.
"""
RasterAssetResolver(s::RasterAssetStore) = RasterAssetResolver(s,0,0,0,0,false)

"""
    AssetRevisionLease

An independently closable lease over the exact admitted raster revisions.
Acquire or retain an instance through the `ImageTiles` protocol and close it
after use. Existing leases preserve admitted revisions through resolver and
store close. The store can release its writer reservation after the last
publication pin drains.
"""
mutable struct AssetRevisionLease <: V.ImageTiles.AbstractRevisionLease
    resolver::RasterAssetResolver
    pins::Vector{AssetPublication}
    closed::Bool
end
"""
    revision_resolver(pin::AssetRevisionLease)

Return the associated resolver, including after `pin` closes. The returned
resolver is borrowed and this lookup performs no file I/O.
"""
V.ImageTiles.revision_resolver(p::AssetRevisionLease)=p.resolver
"""
    resolver_usage(resolver::RasterAssetResolver)

Return a consistent snapshot of resolver counters under the store guard.

`leases` counts one slot per pinned revision and one slot for an empty group.
`reads` counts admitted region reads, including requests later interrupted.
`io_bytes` counts verified tile bytes and `io_reserved` counts pending
reserved bytes. `closed` indicates whether new leases can be admitted.
"""
function resolver_usage(r::RasterAssetResolver)
    lock(r.store.guard) do
        (;leases=r.leases,reads=r.reads,io_bytes=r.io_bytes,io_reserved=r.io_reserved,closed=r.closed)
    end
end
"""
    close(reader::RasterAssetResolver)

Stop new admissions idempotently and return `nothing`. Leave archive ownership with the caller and preserve existing pins.
"""
function Base.close(r::RasterAssetResolver)
    lock(r.store.guard) do
        r.closed=true
    end
    nothing
end

"""
    asset_lease_locked(reader, records; admitted=false)

Reserve a lease group for already looked-up records while holding the store
guard. Use `admitted=true` to extend an existing authorized lease after close.
An exception rolls back pins already acquired. An inadmissible state or
exhausted lease budget raises `ArgumentError`.
"""
function asset_lease_locked(r, records; admitted=false)
    s=r.store
    admitted || (check(!r.closed,"asset resolver closed"); store_open(s))
    count=max(1,length(records))
    check(count<=s.limits.leases-r.leases,"asset resolver lease limit")
    check(length(records)<=s.limits.leases-s.leases,"asset store lease limit")
    pins=AssetPublication[]
    sizehint!(pins,length(records))
    try
        for rec in records
            push!(pins,pin_asset(s,rec;admitted))
        end
        lease=AssetRevisionLease(r,pins,false)
        finalizer(close,lease)
        r.leases+=count
        lease
    catch
        for pin in pins
            pin.closed=true
            pin.record.pins-=1
            s.leases-=1
        end
        rethrow()
    end
end
"""
    asset_lookup_locked(reader, descriptor)

Look up the exact stored descriptor while holding the store guard. Return its
record after checking the immutable binding, manifest root and metadata.
An absent or inconsistent record raises `ArgumentError`.
"""
function asset_lookup_locked(r,d)
    s=r.store
    rec=get(s.records,asset_key(d),nothing)
    check(rec!==nothing && rec.binding.descriptor==d,"exact raster revision or metadata unavailable")
    check(get(s.history,asset_key(d),nothing)==rec.binding &&
          rec.binding.root==rec.manifest.root && rec.manifest.metadata==d.metadata,
          "raster binding or manifest mismatch")
    rec
end
"""
    acquire_revision(reader::RasterAssetResolver, descriptor::RasterReference)

Return an independent pin for the exact stored revision. Raise `ArgumentError` if the reader or archive is closed, the record is absent, metadata mismatches, or the lease limit is reached.
"""
function V.ImageTiles.acquire_revision(r::RasterAssetResolver,d::V.RasterReference)
    lock(r.store.guard) do
        check(!r.closed,"asset resolver closed");store_open(r.store)
        asset_lease_locked(r,[asset_lookup_locked(r,d)])
    end
end
"""
    retain_frame(reader::RasterAssetResolver, frame::Frame)

Pin every distinct raster revision referenced by `frame`, including resources
that have no draw command. Return one independently closable lease group.

A closed resolver or store, unavailable revision, mismatched binding or
insufficient capacity raises `ArgumentError` before returning any lease.
"""
function V.ImageTiles.retain_frame(r::RasterAssetResolver,frame::V.Frame)
    lock(r.store.guard) do
        check(!r.closed,"asset resolver closed");store_open(r.store)
        records=AssetRecord[]
        seen=Set{AssetKey}()
        for resource in frame.resources
            d=resource.payload
            d isa V.RasterReference || continue
            rec=asset_lookup_locked(r,d)
            if !(asset_key(d) in seen)
                check(length(records)<r.store.limits.leases-r.leases &&
                      length(records)<r.store.limits.leases-r.store.leases,
                      "asset Frame lease limit")
                push!(records,rec);push!(seen,asset_key(d))
            end
        end
        asset_lease_locked(r,records)
    end
end
"""
    retain_revision(pin::AssetRevisionLease)

Return an independent pin over the same records, even if the reader or archive is closing. Raise `ArgumentError` if `pin` is closed or capacity is unavailable.
"""
function V.ImageTiles.retain_revision(p::AssetRevisionLease)
    r=p.resolver
    lock(r.store.guard) do
        check(!p.closed,"asset revision lease closed")
        asset_lease_locked(r,[pin.record for pin in p.pins];admitted=true)
    end
end
"""
    retain_execution(pin::AssetRevisionLease)

Return an independently closable lease over the revisions needed by an
execution. The execution owner releases the returned lease when finished.
A closed lease or exhausted capacity raises `ArgumentError`.
"""
V.retain_execution(p::AssetRevisionLease)=V.ImageTiles.retain_revision(p)
"""
    acquire_revision(pin::AssetRevisionLease, descriptor::RasterReference)

Return an independent pin over exactly one retained revision. Raise `ArgumentError` if `pin` is closed, the descriptor is unavailable, metadata mismatches, or a cap is reached.
"""
function V.ImageTiles.acquire_revision(p::AssetRevisionLease,d::V.RasterReference)
    r=p.resolver
    lock(r.store.guard) do
        check(!p.closed,"asset revision lease closed")
        i=findfirst(pin->asset_key(pin.record.binding)==asset_key(d),p.pins)
        check(i!==nothing && p.pins[i].record.binding.descriptor==d,
              "exact raster revision not retained by lease")
        asset_lease_locked(r,[p.pins[i].record];admitted=true)
    end
end
"""
    close(pin::AssetRevisionLease)

Release all records owned by `pin` once and return `nothing`. Attempt every release and report underlying drain failures together as a `CompositeException`.
"""
function Base.close(p::AssetRevisionLease)
    r=p.resolver
    pins=lock(r.store.guard) do
        p.closed && return AssetPublication[]
        p.closed=true
        r.leases-=max(1,length(p.pins))
        pins=p.pins
        p.pins=AssetPublication[]
        pins
    end
    failures=Any[]
    for pin in pins
        try
            close(pin)
        catch error
            push!(failures,error)
        end
    end
    isempty(failures) || throw(CompositeException(failures))
    nothing
end
"""
    asset_single(pin::AssetRevisionLease)

Return the backing record under the archive guard. Raise `ArgumentError` if `pin` is closed or has zero or multiple records.
"""
function asset_single(p::AssetRevisionLease)
    lock(p.resolver.store.guard) do
        check(!p.closed && length(p.pins)==1,"asset region requires one open revision")
        only(p.pins).record
    end
end
"""
    image_metadata(pin::AssetRevisionLease)

Return physical pixel metadata for the sole pinned raster. Raise `ArgumentError` if `pin` is closed or has zero or multiple records.
"""
V.ImageStorage.image_metadata(p::AssetRevisionLease)=
    V.ImageTiles.physical_metadata(asset_single(p).binding.descriptor)
"""
    storage_revision(pin::AssetRevisionLease)

Return the immutable revision tag for the sole pinned raster. Raise `ArgumentError` if `pin` is closed or has zero or multiple records.
"""
V.ImageStorage.storage_revision(p::AssetRevisionLease)=asset_single(p).binding.descriptor.revision

"""
    borrow_pixels(pin::AssetRevisionLease, region; <keyword arguments>)

Stage a read-only region from the single pinned raster into an owned
`ImageStorage.PixelLease`. Pass `region` as zero-based integer
`(x, y, width, height)`. The lease preserves the source pixel format, alpha
and color space and reports the copied region bytes. Close it after use.

# Arguments

- `access=:read` requests read access.
- `copy_policy=:forbid` requires the caller to opt in with `:allow`.
- `budget_bytes=1024*1024` limits the packed output size.
- `revision=nothing` optionally checks an exact source revision tag.
- `cancelled=()->false` cooperatively cancels work if it returns `true`.

The store also limits the intersected tile count, the full tile bytes read and
the number of concurrent reads. Invalid extents, mismatched revisions, corrupt
tiles and exceeded limits raise `ArgumentError`. Unsupported options raise
`ImageStorage.UnsupportedStorageError`. Cancellation raises
`InterruptException`. File I/O and final lease-drain errors may propagate.
"""
function V.ImageStorage.borrow_pixels(p::AssetRevisionLease,region;
        access=:read,copy_policy=:forbid,budget_bytes=1024*1024,
        revision=nothing,cancelled=()->false,kwargs...)
    S=V.ImageStorage
    access===:read && copy_policy===:allow ||
        throw(S.UnsupportedStorageError("asset regions require independent read staging"))
    isempty(kwargs) || throw(S.UnsupportedStorageError("use explicit asset pixel conversion"))
    check(budget_bytes isa Integer && 0<=budget_bytes<=typemax(Int),"invalid asset region budget")
    pin=V.ImageTiles.retain_revision(p)
    output=nothing
    reading=false
    remaining=UInt128(0)
    s=pin.resolver.store
    try
        report=try
            rec=asset_single(pin);m=rec.manifest.metadata
            x,y,w,h=V.ImageTiles.checked_region(V.ImageTiles.physical_metadata(rec.binding.descriptor),region)
            revision===nothing || check(revision==rec.binding.descriptor.revision,"asset revision tag mismatch")
            channels=asset_channels(m)
            n=UInt128(w)*UInt128(h)*channels
            tx0,tx1=x÷256,(x+w-1)÷256
            ty0,ty1=y÷256,(y+h-1)÷256
            count=UInt128(tx1-tx0+1)*UInt128(ty1-ty0+1)
            check(n<=min(s.limits.region_bytes,budget_bytes) && count<=s.limits.region_tiles,
                  "asset region output or tile count limit exceeded")
            source=UInt128(0)
            nx=cld(Int(m.width),256)
            for ty in ty0:ty1, tx in tx0:tx1
                _,_,tw,th=asset_tile_shape(m,ty*nx+tx)
                source+=UInt128(tw)*UInt128(th)*channels
            end
            check(source<=s.limits.region_source_bytes,"asset region source-byte limit exceeded")
            lock(s.guard) do
                check(s.reads<s.limits.reads,"asset active read limit")
                check(pin.resolver.reads<typemax(UInt64) &&
                      source<=typemax(UInt128)-pin.resolver.io_bytes-pin.resolver.io_reserved,
                      "asset IO counter exhausted")
                s.reads+=1;reading=true
                pin.resolver.reads+=1
                pin.resolver.io_reserved+=source
                remaining=source
            end
            cancelled() && throw(InterruptException())
            output=S.allocate_buffer(w,h;format=m.format,alpha=m.alpha,color_space=m.color_space,budget_bytes)
            for ty in ty0:ty1, tx in tx0:tx1
                i=ty*nx+tx
                ox,oy,tw,th=asset_tile_shape(m,i)
                pixels=read_asset_tile(s,rec.manifest,i;cancelled)
                lock(s.guard) do
                    pin.resolver.io_reserved-=length(pixels)
                    remaining-=length(pixels)
                    pin.resolver.io_bytes+=length(pixels)
                end
                left,right=max(x,ox),min(x+w,ox+tw)
                top,bottom=max(y,oy),min(y+h,oy+th)
                for row in top:bottom-1
                    copyto!(output.owner.bytes,((row-y)*w+left-x)*channels+1,
                            pixels,((row-oy)*tw+left-ox)*channels+1,(right-left)*channels)
                end
            end
            cancelled() && throw(InterruptException())
            S.CopyReport(Int(n),(:asset_region,))
        finally
            try
                if reading
                    lock(s.guard) do
                        s.reads-=1
                        pin.resolver.io_reserved-=remaining
                    end
                end
            finally
                close(pin)
            end
        end
        result=S.new_lease(output,:read;close_buffer=true,report)
        output=nothing
        result
    finally
        output===nothing || close(output)
    end
end

"""
    OwnedSnapshotAssets

Pair an immutable binding table with one independently closable resolver
lease group. The private table contains precisely the live external records.
"""
struct OwnedSnapshotAssets <: SnapshotAssetOwnership
    bindings::Dict{ResourceKey,AssetBinding}
    lease::AssetRevisionLease
end

"""Release a snapshot's private pin group, propagating archive cleanup failures."""
close_snapshot_assets(owner::OwnedSnapshotAssets) = close(owner.lease)

"""Read a private binding table only while its pin group is open."""
function owned_bindings(owner::OwnedSnapshotAssets)
    lock(owner.lease.resolver.store.guard) do
        check(!owner.lease.closed,"asset snapshot closed")
        owner.bindings
    end
end

"""
    open_snapshot_resolver(assets)

Require an explicit raster resolver. Callers check that it is open under
the store guard before reading bindings or admitting new leases.
"""
function open_snapshot_resolver(assets)
    check(assets isa RasterAssetResolver,"VTRW 1.6 requires a raster asset resolver")
    assets::RasterAssetResolver
end

"""
    admit_snapshot_assets(assets, resources, supplied)

Validate and pin every external resource under one guard, deduplicating
exact archival keys. When supplied is present, compare every binding to the
exact advertised root and metadata. A failed lookup reserves no pins.
"""
function admit_snapshot_assets(assets,resources,supplied)
    resolver = open_snapshot_resolver(assets)
    lock(resolver.store.guard) do
        check(!resolver.closed,"asset resolver closed")
        store_open(resolver.store)
        bindings = Dict{ResourceKey,AssetBinding}()
        records = Dict{AssetKey,AssetRecord}()
        for (key,payload) in resources
            payload isa V.RasterReference || continue
            check(key[4] == "image", "external raster requires image kind")
            record = asset_lookup_locked(resolver,payload)
            check(supplied === nothing || get(supplied,key,nothing)==record.binding,
                  "exact raster manifest root mismatch")
            records[asset_key(payload)] = record
            bindings[key] = record.binding
        end
        isempty(records) && return nothing
        OwnedSnapshotAssets(bindings,asset_lease_locked(resolver,collect(values(records))))
    end
end

"""
    verify_snapshot_assets(assets, bindings)

Require an open encoding resolver with the same exact binding table held
by the snapshot. Perform no reads or additional pin reservations.
"""
function verify_snapshot_assets(assets,bindings)
    resolver = open_snapshot_resolver(assets)
    lock(resolver.store.guard) do
        check(!resolver.closed,"asset resolver closed")
        store_open(resolver.store)
        for binding in values(bindings)
            record = asset_lookup_locked(resolver,binding.descriptor)
            check(record.binding == binding,"encoding raster binding mismatch")
        end
    end
    nothing
end

include("RasterBundles.jl")
