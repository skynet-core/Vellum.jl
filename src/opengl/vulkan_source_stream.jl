"""
    check_stream_status!(surface, status, operation)

Check a Vulkan stream operation's ABI status. A driver failure quarantines
the surface. Rejected, busy or wrong-thread operations raise `ArgumentError`.
"""
function check_stream_status!(surface,status,operation)
    status == 0 && return nothing
    if status == 3
        surface.valid = false
        error("Vulkan $operation failed on the device")
    end
    throw(ArgumentError("Vulkan $operation rejected with status $status"))
end

"""
    transfer_stream_batch!(surface, batch, overwritten, entry)

Root one owned page batch while Vulkan copies it. Record its destinations
before the transfer so an abort can forget overwritten inactive slots.
Throws on ownership, validation or device errors.
"""
function transfer_stream_batch!(surface,batch,overwritten,entry)
    session = require_session(surface)
    for item in batch
        push!(overwritten,item.slot)
    end
    status = GC.@preserve batch begin
        uploads = RasterAssets.describe(batch)
        ccall(entry,Cint,(Ptr{Cvoid},Ptr{RasterAssets.Upload},Csize_t),session.handle,uploads,length(uploads))
    end
    check_stream_status!(surface,status,:stream_pages)
    empty!(batch)
    return nothing
end

"""
    stream_page_uploads!(surface, plan, assets, registry, overwritten, entry)

Read the exact pinned source revision a page at a time, completing bounded
2 MiB host batches in Vulkan. Each transfer accepts only pages outside the
completed drawing. Provider and native failures propagate to the transaction.
"""
function stream_page_uploads!(surface,plan,assets,registry,overwritten,entry)
    batch = RasterAssets.StagedUpload[]
    bytes = 0
    RasterPages.visit_uploads(plan,surface.assets,assets,registry) do item
        amount = sizeof(item.bytes)
        if bytes+amount > RasterPages.STREAM_BATCH_BYTES
            transfer_stream_batch!(surface,batch,overwritten,entry)
            bytes = 0
        end
        push!(batch,item)
        bytes += amount
    end
    isempty(batch) || transfer_stream_batch!(surface,batch,overwritten,entry)
    return nothing
end

"""
    enqueue_source_stream!(surface, plan, packet, base, uploads; combined=false) -> Token

Validate the candidate before source reads. In the ordinary stream, transfer
bounded page batches before the render and use `uploads` for final dense
images. In combined mode, `uploads` starts empty and receives the bounded
source pages to copy with the draw. Return the publication fence. On failure,
abort the stream and forget any inactive slots already overwritten. Driver
failures quarantine the surface for teardown on its owner thread.
"""
function enqueue_source_stream!(surface,plan,packet,base,uploads;combined::Bool=false)
    session = require_session(surface)
    begin_stream = raster_entry(session.library,:vulkan,:begin_stream)
    finish = raster_entry(session.library,:vulkan,combined ? :finish_stream_combined : :finish_stream)
    abort = raster_entry(session.library,:vulkan,:abort_stream)
    item = Token(surface,plan.frame,packet.assets,UInt64(0),:pending)
    token = Ref{UInt64}(0)
    overwritten = BitSet()
    status = ccall(begin_stream,Cint,(Ptr{Cvoid},Ptr{Cdouble},Csize_t,UInt64),
        session.handle,packet.words,length(packet.words),base)
    check_stream_status!(surface,status,:begin_stream)
    submitted = false
    try
        registry = surface.backend.raster_registry
        if combined
            RasterPages.visit_uploads(item -> push!(uploads,item),plan,surface.assets,packet.assets,registry)
        else
            transfer = raster_entry(session.library,:vulkan,:stream_pages)
            stream_page_uploads!(surface,plan,packet.assets,registry,overwritten,transfer)
        end
        require_owner(surface.backend)
        status = GC.@preserve uploads begin
            descriptors = RasterAssets.describe(uploads)
            ccall(finish,Cint,(Ptr{Cvoid},Ref{UInt64},Ptr{RasterAssets.Upload},Csize_t),
                session.handle,token,descriptors,length(descriptors))
        end
        check_stream_status!(surface,status,:finish_stream)
        submitted = true
        item.value = token[]
        surface.item = item
        return item
    finally
        if !submitted
            status = ccall(abort,Cint,(Ptr{Cvoid},),session.handle)
            status == 0 || (surface.valid = false)
            surface.assets = RasterPages.forget_slots(surface.assets,overwritten)
        end
    end
end

"""
    initialize_stream!(surface, backend, plan; host...) -> Surface

Open the negotiated Vulkan source pool, then stream and complete the first
render. Admission and provider failures before the first publication close
the provisional native handle. Host window arguments follow `open_session`.
"""
function initialize_stream!(surface,backend,plan;host...)
    packet = pack_frame(plan,surface.size;streamed=true,layered=backend.source_pool===:streamed_layers,
                        blur_radius=box_blur_radius(backend),workspace=surface.workspace)
    dense = RasterAssets.uploads(surface.assets.dense,packet.assets.dense)
    surface.session = open_session(backend,packet.words,dense;host...)
    try
        wait(enqueue_source_stream!(surface,plan,packet,UInt64(0),dense))
        surface.valid = true
        return surface
    catch
        release_native!(surface)
        rethrow()
    end
end

"""
    combined_source_capacity(surface) -> Int

Return the source payload budget of a bridge that can combine page uploads
with the drawing. Older bridges return zero. An invalid session raises
the normal session error.
"""
function combined_source_capacity(surface)
    library = require_session(surface).library
    query = Libdl.dlsym_e(library,:vetra_vulkan_combined_source_capacity)
    query == C_NULL && return 0
    Libdl.dlsym_e(library,:vetra_vulkan_finish_stream_combined) == C_NULL && return 0
    return Int(min(ccall(query,Csize_t,()),Csize_t(RasterPages.STREAM_BATCH_BYTES)))
end

"""
    source_upload_route(before, after, budget) -> Symbol

Inspect changed page slots without reading the provider. Return `:resident`
when all pages are ready, `:combined` for a batch within the negotiated byte
and descriptor bounds, or `:stream` when batches must transfer separately.
The slot maps come from validated page packing and a completed surface.
"""
function source_upload_route(before,after,budget)
    after.pages === before.pages && return :resident
    count = 0
    for (key,slot) in after.pages
        get(before.cached,key,-1) == slot && continue
        count += 1
        count > RasterPages.EXTENDED_CAPACITY && return :stream
        budget -= 4*prod(RasterPages.dimensions(key))
        budget < 0 && return :stream
    end
    return count == 0 ? :resident : :combined
end

"""
    submit_stream!(surface, backend, plan, base) -> Token

Pack a consecutive frame using the streamed source pool. Enqueue resident
drawings directly, combine small page updates with their draw on a capable
bridge, and stream larger updates in bounded batches. Return the fence that
publishes the frame. Packing, provider and submission errors propagate.
"""
function submit_stream!(surface,backend,plan,base)
    previous = surface.assets
    packet = pack_frame(plan,surface.size,previous;streamed=true,layered=backend.source_pool===:streamed_layers,
                        blur_radius=box_blur_radius(backend),workspace=surface.workspace)
    dense = RasterAssets.uploads(previous.dense,packet.assets.dense)
    if isempty(dense)
        route = source_upload_route(previous,packet.assets,combined_source_capacity(surface))
        if route === :resident
            return enqueue_staged!(backend,surface,plan.frame,base,StagedFrame(packet.words,packet.assets,FrameCurves.EMPTY_SHAPES,dense))
        end
        route === :combined && return enqueue_source_stream!(surface,plan,packet,base,dense;combined=true)
    end
    return enqueue_source_stream!(surface,plan,packet,base,dense)
end
