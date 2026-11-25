"""
    write_buffer!(buffer,offset,data)

Copy Julia-owned bytes into a bounded, mapped Vulkan allocation.
"""
function write_buffer!(buffer,offset,data)
    n = sizeof(data)
    0 <= offset <= buffer.bytes-n || throw(ArgumentError("Vulkan mapped write exceeds allocation"))
    GC.@preserve data unsafe_copyto!(buffer.mapped+offset,Ptr{UInt8}(pointer(data)),n)
    return nothing
end

"""
    bind_output!(t,index)

Bind the draw packet, resident sources, physical slot offsets and unpublished output.
"""
function bind_output!(t,index)
    info = [VkDescriptorBufferInfo(b.handle,0,b.bytes) for b in (t.plan,t.atlas,t.offsets,t.output[index])]
    GC.@preserve info begin
        writes = [VkWriteDescriptorSet(VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,C_NULL,t.descriptor,i-1,0,1,
            VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,C_NULL,pointer(info,i),C_NULL) for i in eachindex(info)]
        vkUpdateDescriptorSets(t.device,length(writes),writes,0,C_NULL)
    end
end

"""
    memory_barrier(command,src_stage,src_access,dst_stage,dst_access)

Synchronize earlier commands' writes with the next pipeline or mapped-memory reader.
"""
function memory_barrier(command,src_stage,src_access,dst_stage,dst_access)
    barrier = VkMemoryBarrier(VK_STRUCTURE_TYPE_MEMORY_BARRIER,C_NULL,src_access,dst_access)
    vkCmdPipelineBarrier(command,src_stage,dst_stage,0,1,Ref(barrier),0,C_NULL,0,C_NULL)
end

"""
    record_uploads!(t,uploads,bytes)

Transfer only changed sources into unpublished physical slots. Return the candidate bank selection.
"""
function record_uploads!(t,uploads,bytes)
    banks = copy(t.banks)
    if bytes>0
        if t.staging.bytes<bytes
            buffer = alloc_buffer(t,bytes,VK_BUFFER_USAGE_TRANSFER_SRC_BIT;host=true)
            free_buffer(t.device,t.staging)
            t.staging = buffer
        end
        regions = VkBufferCopy[]
        pos = 0
        for upload in uploads
            i = upload.slot+1
            banks[i] ⊻= UInt32(1)
            offset = 4slot_offset(upload.slot,Int(banks[i]))
            write_buffer!(t.staging,pos,upload.bytes)
            n = sizeof(upload.bytes)
            push!(regions,VkBufferCopy(pos,offset,n))
            pos += n
        end
        vkCmdCopyBuffer(t.command,t.staging.handle,t.atlas.handle,length(regions),regions)
    end
    # The barrier also makes retained transfers from earlier submissions visible to this dispatch.
    memory_barrier(t.command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_ACCESS_SHADER_READ_BIT)
    offsets = UInt32[slot_offset(i-1,Int(banks[i])) for i in eachindex(banks)]
    write_buffer!(t.offsets,0,offsets)
    return banks
end

"""
    retire!(t)

Wait until abandoned work releases the single command buffer and staging allocation.
"""
function retire!(t)
    t.in_flight || return
    checked(vkWaitForFences(t.device,1,Ref(t.fence),1,typemax(UInt64)),:vkWaitForFences)
    t.in_flight = false
end

"""
    submit_draw!(t,plan)

Pack the frame, record the source transfers and dispatch, and submit them under one fence.
"""
function submit_draw!(t,plan)
    check_open(t)
    (t.recording || t.pending !== nothing) && throw(ArgumentError("Vulkan surface already has a pending draw"))
    t.recording = true
    try
        staged = Packed.stage_frame(plan,t.size,t.sources,plan.backend.raster_registry;shapes=t.shapes,blur_radius=0,workspace=t.workspace)
        bytes = sum(upload -> sizeof(upload.bytes),staged.uploads;init=0)
        retire!(t)
        index = t.published==1 ? 2 : 1
        bind_output!(t,index)
        write_buffer!(t.plan,0,staged.words)
        checked(vkResetCommandPool(t.device,t.pool,0),:vkResetCommandPool)
        begin_info = VkCommandBufferBeginInfo(VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,C_NULL,VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,C_NULL)
        checked(vkBeginCommandBuffer(t.command,Ref(begin_info)),:vkBeginCommandBuffer)
        if t.queries != C_NULL
            vkCmdResetQueryPool(t.command,t.queries,0,2)
            vkCmdWriteTimestamp(t.command,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,t.queries,0)
        end
        banks = record_uploads!(t,staged.uploads,bytes)
        vkCmdBindPipeline(t.command,VK_PIPELINE_BIND_POINT_COMPUTE,t.pipeline)
        vkCmdBindDescriptorSets(t.command,VK_PIPELINE_BIND_POINT_COMPUTE,t.layout,0,1,Ref(t.descriptor),0,C_NULL)
        vkCmdDispatch(t.command,cld(t.size[1],8),cld(t.size[2],8),1)
        t.queries != C_NULL && vkCmdWriteTimestamp(t.command,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,t.queries,1)
        memory_barrier(t.command,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_ACCESS_SHADER_WRITE_BIT,
            VK_PIPELINE_STAGE_HOST_BIT,VK_ACCESS_HOST_READ_BIT)
        checked(vkEndCommandBuffer(t.command),:vkEndCommandBuffer)
        candidate = (;index,banks,staged.assets,staged.shapes,bytes,plan.frame.revision)
        token = Backend.QueueSubmission(t,candidate,:pending)
        cmds = [t.command]
        GC.@preserve cmds begin
            submit = VkSubmitInfo(VK_STRUCTURE_TYPE_SUBMIT_INFO,C_NULL,0,C_NULL,C_NULL,1,pointer(cmds),0,C_NULL)
            checked(vkResetFences(t.device,1,Ref(t.fence)),:vkResetFences)
            checked(vkQueueSubmit(t.queue,1,Ref(submit),t.fence),:vkQueueSubmit)
        end
        t.in_flight = true
        t.pending = token
        t.uploaded += bytes
        return token
    finally
        t.recording = false
    end
end

"""
    advance!(token,timeout)

Publish the completed buffer and page identities together after the Vulkan fence has signaled.
"""
function advance!(token,timeout)
    t = token.native
    t.owner == Threads.threadid() || throw(ArgumentError("Vulkan submission belongs to another thread"))
    token.state === :pending || return token.state === :complete
    check_open(t)
    result = vkWaitForFences(t.device,1,Ref(t.fence),1,timeout)
    result == VK_TIMEOUT && return false
    checked(result,:vkWaitForFences)
    ticks = query_ticks(t,t.queries)
    c = token.candidate
    t.published,t.banks,t.sources,t.shapes,t.ticks = c.index,c.banks,c.assets,c.shapes,ticks
    t.revision = c.revision
    t.committed += c.bytes
    t.frames += 1
    t.in_flight = false
    t.pending = nothing
    token.candidate = nothing
    token.state = :complete
    return true
end

"""
    cancel_draw!(token)

Withdraw publication immediately. Earlier committed storage remains valid while the GPU finishes.
"""
function cancel_draw!(token)
    t = token.native
    t.owner == Threads.threadid() || throw(ArgumentError("Vulkan submission belongs to another thread"))
    token.state === :pending || return nothing
    t.pending = nothing
    token.candidate = nothing
    token.state = :cancelled
    return nothing
end

"""
    capture(t)

Read only the published mapped output buffer after its shader-to-host memory barrier.
"""
function capture(t)
    check_open(t)
    t.published>0 || throw(ArgumentError("Vulkan surface has no completed frame"))
    image = Vellum.Image(t.size...)
    dest = image.data
    GC.@preserve dest unsafe_copyto!(pointer(dest),t.output[t.published].mapped,sizeof(dest))
    return image
end

"""
    device_statistics(t)

Describe device timings with queue tick wraparound and transfer counts for the last publication.
"""
function device_statistics(t)
    check_open(t)
    duration = elapsed_ns(t,t.ticks)
    dense = count(!isnothing,t.sources.dense)
    return (;t.renderer,t.pci,t.driver_version,queue_family=t.family,t.frames,pending=t.pending!==nothing,
        uploaded_bytes=t.uploaded,committed_upload_bytes=t.committed,resident_images=dense+length(t.sources.pages),
        cached_pages=length(t.sources.cached),gpu_ns=duration,device_ticks=t.ticks,timestamp_period_ns=t.period_ns,
        timestamp_valid_bits=t.valid_bits)
end

"""
    query_ticks(t,pool)

Read the start and end ticks after the corresponding draw or transfer fence has signaled.
"""
function query_ticks(t,pool)
    pool == C_NULL && return nothing
    data = zeros(UInt64,2)
    checked(vkGetQueryPoolResults(t.device,pool,0,2,sizeof(data),data,sizeof(UInt64),VK_QUERY_RESULT_64_BIT),:vkGetQueryPoolResults)
    return Tuple(data)
end

"""
    elapsed_ns(t,ticks)

Convert the queue's wrapping timestamp counter into elapsed device nanoseconds.
"""
function elapsed_ns(t,ticks)
    isnothing(ticks) && return nothing
    mask = typemax(UInt64) >> (64-Int(t.valid_bits))
    return ((ticks[2]-ticks[1]) & mask)*t.period_ns
end
