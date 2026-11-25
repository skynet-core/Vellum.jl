"""One Vulkan allocation bound to a storage or staging buffer. Mapped storage is host-coherent."""
struct Buffer
    handle::VkBuffer
    memory::VkDeviceMemory
    mapped::Ptr{UInt8}
    bytes::Int
end

"""A handle-free buffer used during partial initialization and teardown."""
const EMPTY_BUFFER = Buffer(C_NULL,C_NULL,C_NULL,0)

"""Native objects owned by one offscreen target. All queue and pool calls run on its creating thread."""
Base.@kwdef mutable struct Target
    size::NTuple{2,Int}
    owner::Int = Threads.threadid()
    instance::VkInstance = C_NULL
    device::VkDevice = C_NULL
    queue::VkQueue = C_NULL
    pool::VkCommandPool = C_NULL
    command::VkCommandBuffer = C_NULL
    fence::VkFence = C_NULL
    queries::VkQueryPool = C_NULL
    set_layout::VkDescriptorSetLayout = C_NULL
    layout::VkPipelineLayout = C_NULL
    pipeline::VkPipeline = C_NULL
    descriptors::VkDescriptorPool = C_NULL
    descriptor::VkDescriptorSet = C_NULL
    memory_types::Vector{UInt32} = UInt32[]
    plan::Buffer = EMPTY_BUFFER
    atlas::Buffer = EMPTY_BUFFER
    offsets::Buffer = EMPTY_BUFFER
    output::NTuple{2,Buffer} = (EMPTY_BUFFER,EMPTY_BUFFER)
    staging::Buffer = EMPTY_BUFFER
    renderer::String = ""
    pci::NTuple{2,UInt32} = (0,0)
    driver_version::UInt32 = 0
    family::UInt32 = 0
    valid_bits::UInt32 = 0
    period_ns::Float64 = 0
    ticks::Union{Nothing,NTuple{2,UInt64}} = nothing
    sources::Packed.RasterPages.Resident = Packed.RasterPages.EMPTY
    shapes::Packed.FrameCurves.ShapeCache = Packed.FrameCurves.EMPTY_SHAPES
    workspace::Packed.FrameCurves.Workspace = Packed.FrameCurves.Workspace()
    banks::Vector{UInt32} = zeros(UInt32,Packed.RasterAssets.SLOT_COUNT+Packed.RasterPages.page_capacity(size))
    published::Int = 0
    frames::Int = 0
    uploaded::Int = 0
    committed::Int = 0
    recording::Bool = false
    in_flight::Bool = false
    pending::Union{Nothing,Backend.QueueSubmission} = nothing
end

"""
    checked(result,operation)

Raise a driver error at the operation that returned it.
"""
function checked(result,operation)
    result == VK_SUCCESS || error(operation," failed: ",result)
    return nothing
end

"""
    create_handle(::Type{T},create,args...) where T

Create a Vulkan object whose final two arguments are the allocator and output handle.
"""
function create_handle(::Type{T},create,args...) where T
    result = Ref{T}()
    checked(create(args...,C_NULL,result),nameof(create))
    return result[]
end

"""
    refptr(value::Ref{T}) where T

Return a pointer to a rooted, isbits C structure for a nested create-info.
"""
refptr(value::Ref{T}) where T = Base.unsafe_convert(Ptr{T},value)

"""
    device_name(properties)

Return a null-terminated Vulkan device name without exposing the fixed-size padding.
"""
device_name(properties) = String(UInt8[unsigned(c) for c in Iterators.takewhile(!iszero,properties.deviceName)])

"""
    select_device(instance,selector)

Select a physical device and compute queue family supporting the packet's double coordinates.
"""
function select_device(instance,selector)
    count = Ref{UInt32}(0)
    devices = VkPhysicalDevice[]
    while true
        checked(vkEnumeratePhysicalDevices(instance,count,C_NULL),:vkEnumeratePhysicalDevices)
        count[] > 0 || throw(ArgumentError("Vulkan loader has no physical devices"))
        resize!(devices,count[])
        result = vkEnumeratePhysicalDevices(instance,count,devices)
        result == VK_INCOMPLETE && continue
        checked(result,:vkEnumeratePhysicalDevices)
        resize!(devices,count[])
        break
    end
    vendor = selector === :nvidia ? 0x10de : selector === :amd ? 0x1002 : selector === :intel ? 0x8086 : 0
    choices = NamedTuple[]
    for physical in devices
        props = Ref{VkPhysicalDeviceProperties}()
        vkGetPhysicalDeviceProperties(physical,props)
        p = props[]
        selector isa Tuple && selector != (p.vendorID,p.deviceID) && continue
        vendor != 0 && p.vendorID != vendor && continue
        features = Ref{VkPhysicalDeviceFeatures}()
        vkGetPhysicalDeviceFeatures(physical,features)
        iszero(features[].shaderFloat64) && continue
        count[] = 0
        vkGetPhysicalDeviceQueueFamilyProperties(physical,count,C_NULL)
        families = Vector{VkQueueFamilyProperties}(undef,count[])
        vkGetPhysicalDeviceQueueFamilyProperties(physical,count,families)
        family = findfirst(f -> f.queueCount > 0 && !iszero(f.queueFlags & VK_QUEUE_COMPUTE_BIT),families)
        isnothing(family) && continue
        priority = p.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU ? 0 :
                   p.deviceType == VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU ? 1 : 2
        push!(choices,(;physical,props=p,family=UInt32(family-1),bits=families[family].timestampValidBits,priority))
    end
    isempty(choices) && throw(ArgumentError("no Vulkan compute queue with shaderFloat64 matches $selector"))
    selector !== :auto && length(choices)>1 && throw(ArgumentError("more than one Vulkan device matches $selector"))
    return choices[argmin([choice.priority for choice in choices])]
end

"""
    open_device!(t,selector)

Create the logical device and record its memory types and timestamp resolution.
"""
function open_device!(t,selector)
    info = VkInstanceCreateInfo(VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,C_NULL,0,C_NULL,0,C_NULL,0,C_NULL)
    t.instance = create_handle(VkInstance,vkCreateInstance,Ref(info))
    choice = select_device(t.instance,selector)
    p = choice.props
    t.renderer,t.pci,t.driver_version = device_name(p),(p.vendorID,p.deviceID),p.driverVersion
    t.family,t.valid_bits,t.period_ns = choice.family,choice.bits,p.limits.timestampPeriod
    properties = Ref{VkPhysicalDeviceMemoryProperties}()
    vkGetPhysicalDeviceMemoryProperties(choice.physical,properties)
    t.memory_types = [properties[].memoryTypes[i].propertyFlags for i in 1:Int(properties[].memoryTypeCount)]
    priority = Float32[1]
    queues = [VkDeviceQueueCreateInfo(VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,C_NULL,0,t.family,1,pointer(priority))]
    features = Ref(VkPhysicalDeviceFeatures((UInt32(name === :shaderFloat64) for name in fieldnames(VkPhysicalDeviceFeatures))...))
    GC.@preserve priority queues features begin
        info = VkDeviceCreateInfo(VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,C_NULL,0,1,pointer(queues),0,C_NULL,0,C_NULL,refptr(features))
        t.device = create_handle(VkDevice,vkCreateDevice,choice.physical,Ref(info))
    end
    queue = Ref{VkQueue}()
    vkGetDeviceQueue(t.device,t.family,0,queue)
    t.queue = queue[]
end

"""
    alloc_buffer(t,bytes,usage;host=false)

Allocate and bind a buffer. Map host-coherent buffers for the duration of the allocation.
"""
function alloc_buffer(t,bytes,usage;host=false)
    info = VkBufferCreateInfo(VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,C_NULL,0,bytes,usage,VK_SHARING_MODE_EXCLUSIVE,0,C_NULL)
    handle = create_handle(VkBuffer,vkCreateBuffer,t.device,Ref(info))
    memory = VkDeviceMemory(C_NULL)
    try
        requirements = Ref{VkMemoryRequirements}()
        vkGetBufferMemoryRequirements(t.device,handle,requirements)
        req = requirements[]
        flags = host ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT : UInt32(VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)
        index = findfirst(eachindex(t.memory_types)) do i
            !iszero(req.memoryTypeBits & (UInt32(1)<<(i-1))) && (t.memory_types[i] & flags) == flags
        end
        isnothing(index) && throw(ArgumentError("Vulkan device lacks the required buffer memory type"))
        allocate = VkMemoryAllocateInfo(VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,C_NULL,req.size,index-1)
        memory = create_handle(VkDeviceMemory,vkAllocateMemory,t.device,Ref(allocate))
        checked(vkBindBufferMemory(t.device,handle,memory,0),:vkBindBufferMemory)
        mapped = Ref{Ptr{Cvoid}}(C_NULL)
        host && checked(vkMapMemory(t.device,memory,0,bytes,0,mapped),:vkMapMemory)
        return Buffer(handle,memory,mapped[],bytes)
    catch
        vkDestroyBuffer(t.device,handle,C_NULL)
        memory != C_NULL && vkFreeMemory(t.device,memory,C_NULL)
        rethrow()
    end
end

"""
    free_buffer(device,b)

Unmap a buffer and release its handle before freeing the bound memory.
"""
function free_buffer(device,b)
    b.handle == C_NULL && return
    b.mapped != C_NULL && vkUnmapMemory(device,b.memory)
    vkDestroyBuffer(device,b.handle,C_NULL)
    vkFreeMemory(device,b.memory,C_NULL)
end

"""
    setup_pipeline!(t,program)

Construct the storage descriptor set, compute pipeline and command submission resources.
"""
function setup_pipeline!(t,program)
    storage = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER
    bindings = [VkDescriptorSetLayoutBinding(i,storage,1,VK_SHADER_STAGE_COMPUTE_BIT,C_NULL) for i in 0:3]
    GC.@preserve bindings begin
        info = VkDescriptorSetLayoutCreateInfo(VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,C_NULL,0,length(bindings),pointer(bindings))
        t.set_layout = create_handle(VkDescriptorSetLayout,vkCreateDescriptorSetLayout,t.device,Ref(info))
    end
    layouts = [t.set_layout]
    GC.@preserve layouts begin
        info = VkPipelineLayoutCreateInfo(VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,C_NULL,0,1,pointer(layouts),0,C_NULL)
        t.layout = create_handle(VkPipelineLayout,vkCreatePipelineLayout,t.device,Ref(info))
        sizes = [VkDescriptorPoolSize(storage,4)]
        GC.@preserve sizes begin
            pool = VkDescriptorPoolCreateInfo(VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,C_NULL,0,1,1,pointer(sizes))
            t.descriptors = create_handle(VkDescriptorPool,vkCreateDescriptorPool,t.device,Ref(pool))
        end
        allocate = VkDescriptorSetAllocateInfo(VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,C_NULL,t.descriptors,1,pointer(layouts))
        descriptor = Ref{VkDescriptorSet}()
        checked(vkAllocateDescriptorSets(t.device,Ref(allocate),descriptor),:vkAllocateDescriptorSets)
        t.descriptor = descriptor[]
    end
    code = compile_program(program)
    shader = GC.@preserve code begin
        info = VkShaderModuleCreateInfo(VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,C_NULL,0,sizeof(code),pointer(code))
        create_handle(VkShaderModule,vkCreateShaderModule,t.device,Ref(info))
    end
    try
        entry = "main"
        GC.@preserve entry begin
            stage = VkPipelineShaderStageCreateInfo(VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,C_NULL,0,
                VK_SHADER_STAGE_COMPUTE_BIT,shader,pointer(entry),C_NULL)
            info = VkComputePipelineCreateInfo(VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,C_NULL,0,stage,t.layout,C_NULL,-1)
            t.pipeline = create_handle(VkPipeline,vkCreateComputePipelines,t.device,C_NULL,1,Ref(info))
        end
    finally
        vkDestroyShaderModule(t.device,shader,C_NULL)
    end
    info = VkCommandPoolCreateInfo(VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,C_NULL,0,t.family)
    t.pool = create_handle(VkCommandPool,vkCreateCommandPool,t.device,Ref(info))
    cmd = Ref{VkCommandBuffer}()
    allocate = VkCommandBufferAllocateInfo(VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,C_NULL,t.pool,VK_COMMAND_BUFFER_LEVEL_PRIMARY,1)
    checked(vkAllocateCommandBuffers(t.device,Ref(allocate),cmd),:vkAllocateCommandBuffers)
    t.command = cmd[]
    fence = VkFenceCreateInfo(VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,C_NULL,0)
    t.fence = create_handle(VkFence,vkCreateFence,t.device,Ref(fence))
    if t.valid_bits>0
        queries = VkQueryPoolCreateInfo(VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO,C_NULL,0,VK_QUERY_TYPE_TIMESTAMP,2,0)
        t.queries = create_handle(VkQueryPool,vkCreateQueryPool,t.device,Ref(queries))
    end
end

"""
    slot_offset(slot,bank)

Return the RGBA-word offset for one physical version of a dense slot or page.
"""
function slot_offset(slot,bank)
    dense = Packed.RasterAssets.SLOT_COUNT
    dense_words = Packed.RasterAssets.MAX_SIDE^2
    page_words = Packed.RasterPages.SIDE^2
    return slot < dense ? (2slot+bank)*dense_words : 2dense*dense_words+(2(slot-dense)+bank)*page_words
end

"""
    open_target(selector,size;program=draw_program())

Open an independent Vulkan device and double-buffered target, unwinding partial initialization on error.
"""
function open_target(selector,size;program=draw_program())
    t = Target(;size)
    try
        open_device!(t,selector)
        setup_pipeline!(t,program)
        storage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT
        t.plan = alloc_buffer(t,Packed.RECORD_BYTES,storage;host=true)
        t.offsets = alloc_buffer(t,sizeof(t.banks),storage;host=true)
        t.atlas = alloc_buffer(t,4slot_offset(length(t.banks),0),storage|VK_BUFFER_USAGE_TRANSFER_DST_BIT)
        t.output = (alloc_buffer(t,4prod(size),storage;host=true),EMPTY_BUFFER)
        t.output = (t.output[1],alloc_buffer(t,4prod(size),storage;host=true))
        return t
    catch
        release!(t)
        rethrow()
    end
end

"""
    check_open(t)

Require an open target on its creating thread.
"""
function check_open(t)
    t.owner == Threads.threadid() || throw(ArgumentError("Vulkan queue belongs to another thread"))
    t.device != C_NULL || throw(ArgumentError("Vulkan queue is closed"))
end

"""
    release!(t)

Drain all submitted work and destroy native objects in dependency order.
"""
function release!(t)
    t.owner == Threads.threadid() || throw(ArgumentError("Vulkan queue belongs to another thread"))
    t.recording && throw(ArgumentError("Vulkan draw is recording"))
    if t.device != C_NULL
        status = vkDeviceWaitIdle(t.device)
        status in (VK_SUCCESS,VK_ERROR_DEVICE_LOST) || checked(status,:vkDeviceWaitIdle)
        if t.pending !== nothing
            t.pending.state = :cancelled
            t.pending.candidate = nothing
            t.pending = nothing
        end
        for buffer in (t.staging,t.output...,t.atlas,t.offsets,t.plan)
            free_buffer(t.device,buffer)
        end
        for (destroy,handle) in ((vkDestroyQueryPool,t.queries),(vkDestroyFence,t.fence),(vkDestroyCommandPool,t.pool),
                (vkDestroyDescriptorPool,t.descriptors),(vkDestroyPipeline,t.pipeline),(vkDestroyPipelineLayout,t.layout),
                (vkDestroyDescriptorSetLayout,t.set_layout))
            handle != C_NULL && destroy(t.device,handle,C_NULL)
        end
        vkDestroyDevice(t.device,C_NULL)
        t.device = C_NULL
    end
    if t.instance != C_NULL
        vkDestroyInstance(t.instance,C_NULL)
        t.instance = C_NULL
    end
    t.sources = Packed.RasterPages.EMPTY
    t.shapes = Packed.FrameCurves.EMPTY_SHAPES
    return nothing
end
