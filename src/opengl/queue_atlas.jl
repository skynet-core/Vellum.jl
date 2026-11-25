"""Maximum concurrent dense image identities in the owned Vulkan sampler."""
const QUEUE_DENSE_SLOTS = 64
"""Maximum bytes in one Vulkan source atlas, including both banks of every slot."""
const MAX_ATLAS_BYTES = 128*1024*1024

"""Physical word offsets for double-buffered source pages and independently sized dense images."""
struct QueueAtlas
    pages::Int
    capacities::Vector{Int}
    starts::Vector{Int}
    words::Int
end

"""Place the fixed-size page banks before the dense banks. All offsets count RGBA8 texels."""
function QueueAtlas(pages,capacities)
    offset = 2*pages*OpenGLBackend.RasterPages.SIDE^2
    starts = Vector{Int}(undef,length(capacities))
    for (i,capacity) in pairs(capacities)
        starts[i] = offset
        offset += 2capacity
    end
    offset <= MAX_ATLAS_BYTES÷4 || throw(ArgumentError("Vulkan resident sources exceed 128 MiB"))
    return QueueAtlas(pages,capacities,starts,offset)
end

"""Keep the current atlas when its banks fit. Compact unused high-water allocations when growing."""
function atlas_for_sources(current::QueueAtlas,sources)
    required = [isnothing(image) ? 0 : image.width*image.height for image in sources]
    all(required .<= current.capacities) && return current
    limits = max.(required,current.capacities)
    if 2*(current.pages*OpenGLBackend.RasterPages.SIDE^2 + sum(limits)) > MAX_ATLAS_BYTES÷4
        limits = required
    end
    return QueueAtlas(current.pages,limits)
end

"""Return the texel offset for a logical source slot and its selected physical bank."""
function atlas_offset(layout::QueueAtlas,slot,bank)
    dense = length(layout.capacities)
    slot < dense && return layout.starts[slot+1] + bank*layout.capacities[slot+1]
    return (2*(slot-dense)+bank)*OpenGLBackend.RasterPages.SIDE^2
end

"""Start a queue with empty dense identities and a cache of reusable source pages."""
function empty_queue_sources()
    slots = Union{Nothing,Vellum.ImageData}[nothing for _ in 1:QUEUE_DENSE_SLOTS]
    pages = OpenGLBackend.RasterPages
    return pages.Resident(slots,Dict{pages.TileKey,Int}(),Dict{pages.TileKey,Int}(),UInt16[],true)
end
