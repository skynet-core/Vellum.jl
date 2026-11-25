"""Window handles claimed by this provider until its Vulkan surface is released."""
const leased_windows = Set{Union{Backend.X11Window,Backend.WaylandWindow}}()
"""Serialize claims from toolkit threads sharing a native window."""
const window_lock = ReentrantLock()

"""Presentation resources owned by a queue target. The native display and window remain borrowed."""
Base.@kwdef mutable struct WindowState
    host::Union{Backend.X11Window,Backend.WaylandWindow}
    surface::VkSurfaceKHR = C_NULL
    physical::VkPhysicalDevice = C_NULL
    chain::VkSwapchainKHR = C_NULL
    images::Vector{VkImage} = VkImage[]
    format::VkFormat = VK_FORMAT_UNDEFINED
    extent::NTuple{2,Int} = (0,0)
    source::VkImage = C_NULL
    memory::VkDeviceMemory = C_NULL
    fence::VkFence = C_NULL
    queries::VkQueryPool = C_NULL
    last_device_ns::Union{Nothing,Float64} = nothing
    recreate::Bool = true
    failed::Bool = false
    offered_frame::Int = 0
    last_scale::Union{Nothing,Int} = nothing
    revision::UInt64 = 0
    accepted::Int = 0
    swapchains::Int = 0
    transfer_bytes::Int = 0
    queue_present_ns::UInt64 = 0
end

"""
    lease_window(window)

Claim exclusive use of a borrowed native window until the owning target closes.
"""
function lease_window(window)
    state = WindowState(host=window)
    lock(window_lock) do
        window in leased_windows && throw(ArgumentError("window already has a Vulkan queue surface"))
        push!(leased_windows,window)
    end
    return state
end

"""
    native_surface(instance,w::Backend.X11Window)

Create an instance-owned Vulkan surface from an Xlib connection and window ID.
"""
function native_surface(instance,w::Backend.X11Window)
    info = VkXlibSurfaceCreateInfoKHR(VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,C_NULL,0,w.display,w.xid)
    return create_handle(VkSurfaceKHR,vkCreateXlibSurfaceKHR,instance,Ref(info))
end

"""
    native_surface(instance,w::Backend.WaylandWindow)

Create an instance-owned Vulkan surface from a Wayland connection and configured wl_surface.
"""
function native_surface(instance,w::Backend.WaylandWindow)
    info = VkWaylandSurfaceCreateInfoKHR(VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,C_NULL,0,w.display,w.surface)
    return create_handle(VkSurfaceKHR,vkCreateWaylandSurfaceKHR,instance,Ref(info))
end

"""
    wsi_list(::Type{T},query,args...) where T

Read a Vulkan enumeration whose size may change between the count and fill calls.
"""
function wsi_list(::Type{T},query,args...) where T
    count = Ref{UInt32}(0)
    while true
        checked(query(args...,count,C_NULL),nameof(query))
        count[] > 0 || throw(ArgumentError("empty Vulkan enumeration from $(nameof(query))"))
        items = Vector{T}(undef,count[])
        result = query(args...,count,items)
        result == VK_INCOMPLETE && continue
        checked(result,nameof(query))
        return resize!(items,count[])
    end
end

"""
    window_formats(w)

Find a swapchain color format and corresponding RGBA blit source that preserve authored sRGB bytes.
"""
function window_formats(w)
    supported = wsi_list(VkSurfaceFormatKHR,vkGetPhysicalDeviceSurfaceFormatsKHR,w.physical,w.surface)
    for output in (VK_FORMAT_B8G8R8A8_UNORM,VK_FORMAT_R8G8B8A8_UNORM,VK_FORMAT_B8G8R8A8_SRGB,VK_FORMAT_R8G8B8A8_SRGB)
        i = findfirst(f -> f.colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR &&
                           f.format in (output,VK_FORMAT_UNDEFINED),supported)
        isnothing(i) && continue
        source = output in (VK_FORMAT_R8G8B8A8_SRGB,VK_FORMAT_B8G8R8A8_SRGB) ? VK_FORMAT_R8G8B8A8_SRGB : VK_FORMAT_R8G8B8A8_UNORM
        props = Ref{VkFormatProperties}()
        vkGetPhysicalDeviceFormatProperties(w.physical,output,props)
        iszero(props[].optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_DST_BIT) && continue
        vkGetPhysicalDeviceFormatProperties(w.physical,source,props)
        iszero(props[].optimalTilingFeatures & VK_FORMAT_FEATURE_BLIT_SRC_BIT) && continue
        return (;output,source,space=supported[i].colorSpace)
    end
    throw(ArgumentError("window has no supported 8-bit sRGB blit formats"))
end

"""
    free_chain!(device,w)

Release acquired image handles, swapchain and intermediate transfer image after queue work retires.
"""
function free_chain!(device,w)
    w.chain != C_NULL && vkDestroySwapchainKHR(device,w.chain,C_NULL)
    w.source != C_NULL && vkDestroyImage(device,w.source,C_NULL)
    w.memory != C_NULL && vkFreeMemory(device,w.memory,C_NULL)
    w.chain,w.source,w.memory = C_NULL,C_NULL,C_NULL
    empty!(w.images)
    w.extent = (0,0)
    w.offered_frame = 0
    w.recreate = true
end

"""
    free_window_device!(t)

Release a window's device objects during partial initialization or final teardown.
"""
function free_window_device!(t)
    w = t.window
    free_chain!(t.device,w)
    w.queries != C_NULL && vkDestroyQueryPool(t.device,w.queries,C_NULL)
    w.queries = C_NULL
    w.fence != C_NULL && vkDestroyFence(t.device,w.fence,C_NULL)
    w.fence = C_NULL
end

"""
    make_chain!(t,extent)

Create the FIFO swapchain and a format-matched, device-local image for scaling and channel conversion.
"""
function make_chain!(t,extent)
    w = t.window
    caps = Ref{VkSurfaceCapabilitiesKHR}()
    checked(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(w.physical,w.surface,caps),:vkGetPhysicalDeviceSurfaceCapabilitiesKHR)
    c = caps[]
    current = (Int(c.currentExtent.width),Int(c.currentExtent.height))
    c.currentExtent.width != typemax(UInt32) && current != extent && return :resize
    c.minImageExtent.width <= extent[1] <= c.maxImageExtent.width &&
        c.minImageExtent.height <= extent[2] <= c.maxImageExtent.height || return :resize
    usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT
    iszero(c.supportedUsageFlags & usage) && throw(ArgumentError("window does not support Vulkan transfer destinations"))
    formats = window_formats(w)
    # Prefer opaque presentation when fitting a frame against the black window background.
    modes = (VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
             VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR)
    alpha = findfirst(mode -> !iszero(c.supportedCompositeAlpha & mode),modes)
    isnothing(alpha) && throw(ArgumentError("window lacks a compatible composite alpha mode"))
    checked(vkQueueWaitIdle(t.queue),:vkQueueWaitIdle)
    free_chain!(t.device,w)
    count = c.maxImageCount == 0 ? c.minImageCount+1 : min(c.minImageCount+1,c.maxImageCount)
    info = VkSwapchainCreateInfoKHR(VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,C_NULL,0,w.surface,count,formats.output,
        formats.space,VkExtent2D(extent...),1,usage,VK_SHARING_MODE_EXCLUSIVE,0,C_NULL,c.currentTransform,
        modes[alpha],VK_PRESENT_MODE_FIFO_KHR,1,C_NULL)
    try
        chain = Ref{VkSwapchainKHR}(C_NULL)
        result = vkCreateSwapchainKHR(t.device,Ref(info),C_NULL,chain)
        result == VK_ERROR_OUT_OF_DATE_KHR && return :resize
        checked(result,:vkCreateSwapchainKHR)
        w.chain = chain[]
        w.images = wsi_list(VkImage,vkGetSwapchainImagesKHR,t.device,w.chain)
        image = VkImageCreateInfo(VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,C_NULL,0,VK_IMAGE_TYPE_2D,formats.source,
            VkExtent3D(t.size...,1),1,1,VK_SAMPLE_COUNT_1_BIT,VK_IMAGE_TILING_OPTIMAL,
            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,VK_SHARING_MODE_EXCLUSIVE,
            0,C_NULL,VK_IMAGE_LAYOUT_UNDEFINED)
        w.source = create_handle(VkImage,vkCreateImage,t.device,Ref(image))
        req = Ref{VkMemoryRequirements}()
        vkGetImageMemoryRequirements(t.device,w.source,req)
        w.memory = allocate_memory(t,req[],UInt32(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
        checked(vkBindImageMemory(t.device,w.source,w.memory,0),:vkBindImageMemory)
        if w.fence == C_NULL
            fence = VkFenceCreateInfo(VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,C_NULL,0)
            w.fence = create_handle(VkFence,vkCreateFence,t.device,Ref(fence))
        end
        if t.valid_bits > 0 && w.queries == C_NULL
            queries = VkQueryPoolCreateInfo(VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,C_NULL,0,VK_QUERY_TYPE_TIMESTAMP,2,0)
            w.queries = create_handle(VkQueryPool,vkCreateQueryPool,t.device,Ref(queries))
        end
        w.extent,w.format,w.recreate = extent,formats.output,false
        w.swapchains += 1
        return :ready
    catch
        free_chain!(t.device,w)
        rethrow()
    end
end

"""Color aspect, base mip and array layer affected by presentation commands."""
const color_range = VkImageSubresourceRange(VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1)
"""Single color image layer shared by the copy and the fitted blit."""
const color_layer = VkImageSubresourceLayers(VK_IMAGE_ASPECT_COLOR_BIT,0,0,1)

"""
    image_barrier(command,image,old,new,src_stage,src_access,dst_stage,dst_access)

Transition the complete color image and order earlier writes against its next access.
"""
function image_barrier(command,image,old,new,src_stage,src_access,dst_stage,dst_access)
    barrier = VkImageMemoryBarrier(VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,C_NULL,src_access,dst_access,old,new,
        VK_QUEUE_FAMILY_IGNORED,VK_QUEUE_FAMILY_IGNORED,image,color_range)
    vkCmdPipelineBarrier(command,src_stage,dst_stage,0,0,C_NULL,0,C_NULL,1,Ref(barrier))
end

"""
    record_blit!(t,destination)

Record a device-side copy and fitted color-converting blit into one acquired swapchain image.
"""
function record_blit!(t,destination)
    w,cmd = t.window,t.command
    transfer = VK_PIPELINE_STAGE_TRANSFER_BIT
    write,read = VK_ACCESS_TRANSFER_WRITE_BIT,VK_ACCESS_TRANSFER_READ_BIT
    dst,src = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
    frame = Backend.fitted_rect(t.size,w.extent)
    checked(vkResetCommandPool(t.device,t.pool,0),:vkResetCommandPool)
    info = VkCommandBufferBeginInfo(VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,C_NULL,VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,C_NULL)
    checked(vkBeginCommandBuffer(cmd,Ref(info)),:vkBeginCommandBuffer)
    if w.queries != C_NULL
        vkCmdResetQueryPool(cmd,w.queries,0,2)
        vkCmdWriteTimestamp(cmd,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,w.queries,0)
    end
    memory_barrier(cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_ACCESS_SHADER_WRITE_BIT,transfer,read)
    for image in (w.source,destination)
        image_barrier(cmd,image,VK_IMAGE_LAYOUT_UNDEFINED,dst,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,0,transfer,write)
    end
    origin = VkOffset3D(0,0,0)
    region = VkBufferImageCopy(0,0,0,color_layer,origin,VkExtent3D(t.size...,1))
    vkCmdCopyBufferToImage(cmd,t.output[t.published].handle,w.source,dst,1,Ref(region))
    image_barrier(cmd,w.source,dst,src,transfer,write,transfer,read)
    if (frame.width,frame.height) != w.extent
        black = VkClearColorValue(reinterpret(NTuple{16,UInt8},(0f0,0f0,0f0,1f0)))
        vkCmdClearColorImage(cmd,destination,dst,Ref(black),1,Ref(color_range))
        image_barrier(cmd,destination,dst,dst,transfer,write,transfer,write)
    end
    target = (VkOffset3D(frame.x,frame.y,0),VkOffset3D(frame.x+frame.width,frame.y+frame.height,1))
    blit = VkImageBlit(color_layer,(origin,VkOffset3D(t.size...,1)),color_layer,target)
    vkCmdBlitImage(cmd,w.source,src,destination,dst,1,Ref(blit),VK_FILTER_NEAREST)
    image_barrier(cmd,destination,dst,VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,transfer,write,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0)
    w.queries != C_NULL && vkCmdWriteTimestamp(cmd,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,w.queries,1)
    checked(vkEndCommandBuffer(cmd),:vkEndCommandBuffer)
    return 4*frame.width*frame.height
end

"""
    finish_blit!(t)

Submit the recorded transfer and wait for its image layout transition before offering it for presentation.
"""
function finish_blit!(t)
    fence = Ref(t.window.fence)
    checked(vkResetFences(t.device,1,fence),:vkResetFences)
    command = Ref(t.command)
    GC.@preserve command begin
        info = VkSubmitInfo(VK_STRUCTURE_TYPE_SUBMIT_INFO,C_NULL,0,C_NULL,C_NULL,1,refptr(command),0,C_NULL)
        checked(vkQueueSubmit(t.queue,1,Ref(info),fence[]),:vkQueueSubmit)
    end
    checked(vkWaitForFences(t.device,1,fence,1,typemax(UInt64)),:vkWaitForFences)
end

"""
    offer_image!(t,index)

Offer the acquired image after its copy fence has signaled. Queue acceptance precedes compositor display.
"""
function offer_image!(t,index)
    chain = Ref(t.window.chain)
    GC.@preserve chain index begin
        info = VkPresentInfoKHR(VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,C_NULL,0,C_NULL,1,refptr(chain),refptr(index),C_NULL)
        start = time_ns()
        result = vkQueuePresentKHR(t.queue,Ref(info))
        t.window.queue_present_ns = time_ns()-start
        return result
    end
end

"""
    present_window!(t,extent,scale)

Acquire without blocking, fit the published buffer on the GPU and handle FIFO swapchain lifecycle outcomes.
"""
function present_window!(t,extent,scale)
    check_open(t)
    w = t.window
    isnothing(w) && throw(ArgumentError("Vulkan queue surface has no borrowed window"))
    w.failed && throw(ArgumentError("Vulkan presentation failed; close and reopen the surface"))
    if !isnothing(scale)
        w.host isa Backend.WaylandWindow || throw(ArgumentError("buffer_scale applies only to Wayland windows"))
        Vellum.WaylandSHM.wl_version(w.host.surface) >= 3 || throw(ArgumentError("Wayland buffer scaling requires wl_surface version 3"))
    end
    if 0 in extent
        w.recreate = true
        return :suspended
    end
    (t.recording || t.pending !== nothing || t.published == 0) && return :busy
    if w.recreate || w.extent != extent
        status = make_chain!(t,extent)
        status === :ready || return status
    elseif w.offered_frame == t.frames && (isnothing(scale) || scale == w.last_scale)
        return :unchanged
    end
    retire!(t)
    checked(vkResetFences(t.device,1,Ref(w.fence)),:vkResetFences)
    index = Ref{UInt32}()
    result = vkAcquireNextImageKHR(t.device,w.chain,0,C_NULL,w.fence,index)
    result in (VK_TIMEOUT,VK_NOT_READY) && return :busy
    if result == VK_ERROR_OUT_OF_DATE_KHR
        w.recreate = true
        return :resize
    end
    try
        result == VK_SUBOPTIMAL_KHR || checked(result,:vkAcquireNextImageKHR)
        w.recreate = result == VK_SUBOPTIMAL_KHR
        checked(vkWaitForFences(t.device,1,Ref(w.fence),1,typemax(UInt64)),:vkWaitForFences)
        bytes = record_blit!(t,w.images[Int(index[])+1])
        finish_blit!(t)
        ticks = query_ticks(t,w.queries)
        # wl_surface.set_buffer_scale becomes current with the WSI buffer commit.
        isnothing(scale) || Vellum.WaylandSHM.wl_request(w.host.surface,8,Cint(scale))
        result = offer_image!(t,index)
        if result == VK_ERROR_OUT_OF_DATE_KHR
            w.recreate = true
            return :resize
        end
        result == VK_SUBOPTIMAL_KHR || checked(result,:vkQueuePresentKHR)
        w.recreate |= result == VK_SUBOPTIMAL_KHR
        w.last_scale = scale
        w.last_device_ns = elapsed_ns(t,ticks)
        w.offered_frame,w.revision = t.frames,t.revision
        w.accepted += 1
        w.transfer_bytes += bytes
        return :accepted
    catch
        # After acquisition an error may leave an image owned by the application.
        w.failed = true
        rethrow()
    end
end

"""
    window_stats(t)

Read window counters without accessing the presentation queue or the compositor.
"""
function window_stats(t)
    check_open(t)
    w = t.window
    isnothing(w) && throw(ArgumentError("Vulkan queue surface has no borrowed window"))
    return (;w.accepted,w.revision,w.swapchains,width=w.extent[1],height=w.extent[2],images=length(w.images),
        format=UInt32(w.format),w.transfer_bytes,w.queue_present_ns,gpu_ns=w.last_device_ns,present_mode=UInt32(VK_PRESENT_MODE_FIFO_KHR))
end
