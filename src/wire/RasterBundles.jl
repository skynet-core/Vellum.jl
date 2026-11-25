export export_bundle, import_bundle, open_bundle_store

"""Byte count of the fixed VTRB 1.0 header."""
const BUNDLE_HEADER = 28
"""Maximum complete VTRB size, including metadata and the snapshot."""
const MAX_BUNDLE_BYTES = Int64(2)*1024^3 + 64*1024^2
"""Byte count of a fixed canonical asset binding."""
const BUNDLE_BINDING_BYTES = 85
"""Byte count of the VTRA MANIFEST body fields before manifest data."""
const BUNDLE_MANIFEST_PREFIX = 12
"""Byte count of the VTRA TILE body fields before packed pixels."""
const BUNDLE_TILE_PREFIX = 48
"""Filename of the committed VTRW snapshot beside a bundle store's catalog."""
const BUNDLE_SCENE = "scene.vtrw"

"""
    bundle_rename(source, destination)

Rename one closed file or private store directory on the same filesystem.
Propagate a filesystem error without falling back to copy and remove.
"""
function bundle_rename(source,destination)
    @static if VERSION >= v"1.12"
        Base.Filesystem.rename(source,destination)
    else
        # Before Julia 1.12, Base.Filesystem.rename falls back to copying.
        err=ccall(:jl_fs_rename,Int32,(Cstring,Cstring),source,destination)
        err<0 && Base.uv_error("rename($(repr(source)), $(repr(destination)))",err)
    end
    nothing
end

"""
    write_bundle_file(write_contents, destination; cancelled, flush_output, close_output, rename_output)

Write, flush and close a private temporary file before replacing destination.
Propagate any writing, close, cancellation or rename failure and clean up the
temporary file. Optional file operations support deterministic failure tests.
"""
function write_bundle_file(write_contents,destination;cancelled,flush_output=flush,
                           close_output=close,rename_output=bundle_rename)
    temporary,io=mktemp(dirname(destination);cleanup=false)
    published=false
    try
        write_contents(io)
        cancelled() && throw(InterruptException())
        flush_output(io)
        close_output(io)
        cancelled() && throw(InterruptException())
        rename_output(temporary,destination)
        published=true
    finally
        try
            isopen(io) && close(io)
        finally
            published || rm(temporary;force=true)
        end
    end
    nothing
end

"""
    bundle_size(record_count, layout, scene_length)

Return the exact VTRB byte count given a checked archive layout and root length.
"""
function bundle_size(record_count,layout,scene_length)
    Int64(BUNDLE_HEADER)+BUNDLE_BINDING_BYTES*record_count+
        (VTRA_HEADER+BUNDLE_MANIFEST_PREFIX)*record_count+layout.index_bytes+
        (VTRA_HEADER+BUNDLE_TILE_PREFIX)*length(layout.tiles)+layout.disk_bytes+scene_length
end

"""
    write_bundle_contents(io, scene, records, store; cancelled)

Stream canonical bindings, manifests, unique verified tiles and a VTRW
snapshot into an unpublished file. Records must be sorted and pinned.
Cancellation or an unreadable tile aborts the write.
"""
function write_bundle_contents(io,scene,records,store;cancelled)
    limits=store===nothing ? AssetLimits() : store.limits
    manifests=[record.manifest for record in records]
    layout=asset_layout(manifests,limits;cancelled)
    check(layout.largest+256<=limits.export_workspace,"bundle export workspace limit")
    total=bundle_size(length(records),layout,length(scene))
    check(total<=MAX_BUNDLE_BYTES,"bundle byte limit")
    write(io,codeunits("VTRB"))
    asset_put(io,UInt16(1))
    asset_put(io,UInt16(0))
    asset_put(io,UInt64(total))
    asset_put(io,UInt32(length(records)))
    asset_put(io,UInt32(length(layout.tiles)))
    asset_put(io,UInt32(length(scene)))
    for record in records
        binding_write(io,record.binding)
    end
    for (index,manifest) in enumerate(manifests)
        cancelled() && throw(InterruptException())
        bytes=canonical_manifest(manifest.metadata,manifest.digests)
        write_asset_header(io,2,0,0,BUNDLE_MANIFEST_PREFIX+length(bytes))
        asset_put(io,UInt64(index))
        asset_put(io,UInt32(length(bytes)))
        write(io,bytes)
    end
    for digest in sort!(collect(keys(layout.tiles)))
        tile=layout.tiles[digest]
        pixels=read_asset_tile(store,manifests[tile.first_record],tile.index;cancelled)
        write_asset_header(io,4,0,0,BUNDLE_TILE_PREFIX+tile.length)
        asset_put(io,UInt64(tile.first_record))
        asset_put(io,UInt32(tile.index))
        write(io,collect(digest))
        asset_put(io,UInt32(tile.length))
        write(io,pixels)
    end
    cancelled() && throw(InterruptException())
    write(io,scene)
    check(position(io)==total,"bundle write length")
    nothing
end

"""
    export_bundle(path, snapshot; assets=nothing, cancelled=()->false) -> nothing

Write a complete deterministic VTRB 1.0 bundle to a host-owned local path.
Pass an open RasterAssetResolver matching every external binding. Raster
reads use an independent pin group for the duration of the export. The
destination may be replaced after the temporary file closes successfully.
Malformed input, quota failures, cancellation or filesystem errors propagate.
A failure before the atomic rename leaves an existing destination intact.
"""
function export_bundle(path::AbstractString,state::Snapshot;assets=nothing,cancelled=()->false)
    cancelled() && throw(InterruptException())
    destination=abspath(path)
    scene=encode_snapshot(state;assets)
    bindings=snapshot_bindings(state)
    records=AssetRecord[]
    if bindings===nothing
        write_bundle_file(destination;cancelled) do io
            write_bundle_contents(io,scene,records,nothing;cancelled)
        end
        return nothing
    end
    resources=[(resourcekey(record.reference),record.payload) for record in state.frame.resources]
    ownership=admit_snapshot_assets(assets,resources,bindings)
    try
        store=ownership.lease.resolver.store
        check(realpath(dirname(destination))!=realpath(store.directory),
              "bundle destination must be outside the raster store")
        records=sort!([pin.record for pin in ownership.lease.pins];by=record->asset_key(record.binding))
        write_bundle_file(destination;cancelled) do io
            write_bundle_contents(io,scene,records,store;cancelled)
        end
    finally
        close_snapshot_assets(ownership)
    end
    nothing
end

"""
    read_bundle_header(io, limits)

Validate magic, version, total file size and bounded record counts before
reading any binding, manifest or snapshot. Return three validated counts.
"""
function read_bundle_header(io,limits)
    check(asset_bytes(io,4,4)==codeunits("VTRB") && asset_get(io,UInt16)==1 &&
          asset_get(io,UInt16)==0,"bundle header")
    total=asset_get(io,UInt64)
    nr,nc,ns=asset_get(io,UInt32),asset_get(io,UInt32),asset_get(io,UInt32)
    check(BUNDLE_HEADER<=total<=MAX_BUNDLE_BYTES && total==filesize(io),"bundle total length")
    check(nr<=min(limits.revisions,limits.history) && nc<=limits.chunks &&
          0<ns<=MAX_MESSAGE,"bundle count/length limit")
    minimum=BUNDLE_HEADER+UInt64(nr)*(BUNDLE_BINDING_BYTES+VTRA_HEADER+BUNDLE_MANIFEST_PREFIX)+
            UInt64(nc)*(VTRA_HEADER+BUNDLE_TILE_PREFIX)+ns
    check(minimum<=total,"bundle declared counts exceed file length")
    (Int(nr),Int(nc),Int(ns))
end

"""
    read_bundle_manifests(io, count, limits; cancelled)

Read sorted distinct bindings and one exact canonical manifest for each. Bound
aggregate manifest bytes before allocations and check record lengths and roots.
"""
function read_bundle_manifests(io,count,limits;cancelled)
    bindings=AssetBinding[]
    manifests=RasterManifest[]
    for _ in 1:count
        cancelled() && throw(InterruptException())
        binding=binding_read(io)
        check(isempty(bindings) || asset_key(bindings[end])<asset_key(binding),"bundle binding order")
        push!(bindings,binding)
    end
    index_bytes=0
    for (index,binding) in enumerate(bindings)
        cancelled() && throw(InterruptException())
        _,_,tiles,_=asset_shape(binding.descriptor.metadata,limits)
        length_expected=length(MANIFEST_PREFIX)+27+32tiles
        check(length_expected<=limits.index_bytes-index_bytes,"bundle index limit")
        tag,_,_,length_body=read_asset_header(io;offline=true)
        check(tag==2 && length_body==length_expected+BUNDLE_MANIFEST_PREFIX &&
              asset_get(io,UInt64)==index && asset_get(io,UInt32)==length_expected,
              "bundle manifest envelope")
        bytes=asset_bytes(io,length_expected,length_expected)
        push!(manifests,parse_manifest(bytes;limits,expected=binding))
        index_bytes+=length_expected
    end
    bindings,manifests
end

"""
    read_bundle_tile(io, digest, tile, manifests)

Read one bounded packed tile. Verify envelope, first canonical occurrence,
expected dimensions and content digest before returning its pixels.
"""
function read_bundle_tile(io,digest,tile,manifests)
    tag,_,_,length_body=read_asset_header(io;offline=true)
    check(tag==4 && length_body==tile.length+BUNDLE_TILE_PREFIX &&
          asset_get(io,UInt64)==tile.first_record && asset_get(io,UInt32)==tile.index &&
          asset_digest(io)==digest && asset_get(io,UInt32)==tile.length,"bundle tile envelope")
    pixels=asset_bytes(io,tile.length,262144)
    metadata=manifests[tile.first_record].metadata
    check(tile_digest(metadata,tile.index,pixels)==digest,"bundle tile digest mismatch")
    pixels
end

"""
    stage_bundle_archive(io, store, bindings, manifests, layout, scene_length; cancelled)

Verify and write each distinct tile inside the private store, then persist its
catalog and bounded VTRW bytes. No caller can open the destination before
successful scene admission. The caller removes the private directory on error.
"""
function stage_bundle_archive(io,store,bindings,manifests,layout,scene_length;cancelled)
    for digest in sort!(collect(keys(layout.tiles)))
        cancelled() && throw(InterruptException())
        pixels=read_bundle_tile(io,digest,layout.tiles[digest],manifests)
        open(chunk_path(store,digest),"w") do output
            check(write(output,pixels)==length(pixels),"short bundle tile write")
        end
    end
    scene=asset_bytes(io,scene_length,MAX_MESSAGE)
    check(eof(io),"trailing bundle bytes")
    records=Dict{AssetKey,AssetRecord}(asset_key(b)=>AssetRecord(b,m,0) for (b,m) in zip(bindings,manifests))
    history=Dict{AssetKey,AssetBinding}(asset_key(b)=>b for b in bindings)
    chunks=Dict{Digest,Tuple{Int,Int}}(d=>(t.length,t.references) for (d,t) in layout.tiles)
    write_catalog(store,records,history;cancelled)
    open(joinpath(store.directory,BUNDLE_SCENE),"w") do output
        check(write(output,scene)==length(scene),"short bundle scene write")
    end
    store.records,store.history,store.chunks=records,history,chunks
    store.disk_bytes,store.index_bytes=layout.disk_bytes,layout.index_bytes
    scene
end

"""
    bundle_scene_bindings(resources, bindings, declared)

Require exact agreement between the scene's live external bindings and the
bundle table. Reject surplus or conflicting archive revisions before names
are admitted and before the directory is published.
"""
function bundle_scene_bindings(resources,bindings,declared)
    live=Dict{AssetKey,AssetBinding}()
    for (key,payload) in resources
        payload isa V.RasterReference || continue
        bound=bindings[key]
        identity=asset_key(bound)
        check(get(declared,identity,nothing)==bound,"bundle scene binding mismatch")
        live[identity]=bound
    end
    check(length(live)==length(declared),"unused bundle binding")
    nothing
end

"""
    decode_bundle_scene(scene, resolver) -> Snapshot

Open a complete bundle root using exactly the archived binding table in
the resolver's private store. Reject missing, conflicting or unused
bindings before acquiring pins or admitting names.
"""
function decode_bundle_scene(scene,resolver)
    declared=resolver.store.history
    return decode(nothing,scene;assets=resolver,
        validate_assets=(resources,bindings)->bundle_scene_bindings(resources,bindings,declared))
end

"""
    import_bundle(path, directory; limits=AssetLimits(), cancelled=()->false)

Verify a complete VTRB file and publish a new host-owned store directory.
Return `(; store, resolver, snapshot)` with a live snapshot and its own pins.
The directory must be new, with a host-owned parent on the same filesystem as
the private staging directory. Invalid content, a quota failure, cancellation
or I/O errors propagate. A failed import never changes a previously committed
receiver. Close the returned snapshot, resolver and store when finished.
"""
function import_bundle(path::AbstractString,directory::AbstractString;limits=AssetLimits(),cancelled=()->false)
    destination=abspath(directory)
    check(!ispath(destination) && !islink(destination),"bundle receiver already exists")
    cancelled() && throw(InterruptException())
    check(isfile(path),"bundle source is not a file")
    mktempdir(dirname(destination)) do scratch
        store=nothing
        resolver=nothing
        snapshot=nothing
        published=false
        try
            scene=open(path,"r") do input
                count,chunk_count,scene_length=read_bundle_header(input,limits)
                bindings,manifests=read_bundle_manifests(input,count,limits;cancelled)
                layout=asset_layout(manifests,limits;cancelled)
                check(length(layout.tiles)==chunk_count,"bundle distinct chunk count mismatch")
                check(3layout.largest+256<=limits.import_workspace,"bundle import workspace limit")
                check(bundle_size(count,layout,scene_length)==filesize(input),"bundle manifest data length mismatch")
                store=RasterAssetStore(joinpath(scratch,"store");limits)
                stage_bundle_archive(input,store,bindings,manifests,layout,scene_length;cancelled)
            end
            cancelled() && throw(InterruptException())
            resolver=RasterAssetResolver(store)
            snapshot=decode_bundle_scene(scene,resolver)
            check(!ispath(destination) && !islink(destination),"bundle receiver already exists")
            # Move the private writer lock and its independently pinned catalog together.
            Base.disable_sigint() do
                bundle_rename(store.directory,destination)
                store.directory=destination
                published=true
            end
            return (;store,resolver,snapshot)
        finally
            if !published
                try
                    snapshot===nothing || close(snapshot)
                finally
                    resolver===nothing || close(resolver)
                    store===nothing || close(store)
                end
            end
        end
    end
end

"""
    open_bundle_store(directory; limits=AssetLimits())

Open a dedicated persisted bundle receiver without its original sender.
Check the catalog, chunks, and exact agreement between the stored scene
and the bundle binding table. Return `(; store, resolver, snapshot)`.
An ordinary close retains the files. Incomplete or corrupt stores and I/O
errors propagate without leaking a writer reservation.
"""
function open_bundle_store(directory::AbstractString;limits=AssetLimits())
    scene_path=joinpath(directory,BUNDLE_SCENE)
    check(isfile(scene_path),"bundle store scene unavailable")
    store=RasterAssetStore(directory;limits)
    resolver=RasterAssetResolver(store)
    try
        scene=open(scene_path,"r") do io
            bytes=asset_bytes(io,filesize(io),MAX_MESSAGE)
            check(eof(io),"trailing persisted scene bytes")
            bytes
        end
        snapshot=decode_bundle_scene(scene,resolver)
        return (;store,resolver,snapshot)
    catch
        try
            close(resolver)
        finally
            close(store)
        end
        rethrow()
    end
end
