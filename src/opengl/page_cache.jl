"""Number of independently copied dictionaries in a streamed page cache."""
const CACHE_PARTITIONS = 64

"""
    PageCache

Read-only index of streamed device pages. Each publication shares unchanged
partitions. The slot index locates the partition to copy when a physical slot
is overwritten or discarded. Both arrays and all dictionaries are owned by
the publication and must be treated as read-only.
"""
struct PageCache <: AbstractDict{TileKey,Int}
    """One key-to-slot dictionary per partition."""
    partitions::Vector{Dict{TileKey,Int}}
    """One partition number per page slot, or zero for a vacant slot."""
    slot_partitions::Vector{UInt8}
    """Total count of physically retained pages."""
    count::Int
end

"""
    page_partition(key) -> Int

Return an index from 1 to `CACHE_PARTITIONS`. Equal shared keys depend only
on their tile identity. Other keys use coordinates mixed across rows and
columns. Each partition still compares the complete tile key.
"""
@inline function page_partition(key::TileKey)
    code = if key.identity == 0
        reinterpret(UInt32,key.x) + UInt32(0x9e3779b9)*reinterpret(UInt32,key.y)
    else
        key.identity ⊻ (key.identity >> 32)
    end
    return Int(code & (CACHE_PARTITIONS-1))+1
end

"""Return the number of keys in the published cache."""
Base.length(cache::PageCache) = cache.count

"""Iterate retained key/physical-slot pairs without copying any partition."""
Base.iterate(cache::PageCache, state...) = iterate(Iterators.flatten(cache.partitions),state...)

"""Look up a key, using `default` when the completed cache has no matching page."""
@inline Base.get(cache::PageCache,key::TileKey,default) =
    get(cache.partitions[page_partition(key)],key,default)

"""
    already_cached(before, after, key, slot) -> Bool

Check whether the completed cache already has the candidate's key at its
physical slot. A partition shared between the two read-only caches proves
the match without hashing the key. The caller supplies an active entry in
the candidate cache.
"""
@inline function already_cached(before::PageCache,after::PageCache,key::TileKey,slot::Int)
    part = page_partition(key)
    entries = before.partitions[part]
    return entries === after.partitions[part] || get(entries,key,-1) == slot
end

"""Compare physical slots when either cache uses an ordinary dictionary."""
@inline already_cached(before,after,key,slot) = get(before,key,-1) == slot

"""Return the retained slot or raise `KeyError` when the key is absent."""
Base.getindex(cache::PageCache,key::TileKey) = cache.partitions[page_partition(key)][key]

"""Report whether an exact or shared tile key is present."""
Base.haskey(cache::PageCache,key::TileKey) = haskey(cache.partitions[page_partition(key)],key)

"""Return an independent mutable copy of the complete mapping."""
Base.copy(cache::PageCache) = Dict(cache)

"""Reuse a partitioned cache without touching the completed publication."""
partitioned_cache(cache::PageCache) = cache

"""
    partitioned_cache(pages) -> PageCache

Index the validated completed pages using the streamed slot capacity. Invalid
physical slots raise a bounds error. The original dictionary is read-only.
"""
function partitioned_cache(pages::Dict{TileKey,Int})
    partitions = [Dict{TileKey,Int}() for _ in 1:CACHE_PARTITIONS]
    owners = zeros(UInt8,STREAM_SLOTS)
    for (key,slot) in pages
        part = page_partition(key)
        partitions[part][key] = slot
        owners[slot-Dense.SLOT_COUNT+1] = part
    end
    return PageCache(partitions,owners,length(pages))
end

"""
    replace_pages(cache, removed, keys, missing, resolved) -> PageCache

Remove occupied page slots marked in the `removed` bit vector. Insert the
keys at the first-use ordinals in `missing` at their assigned physical slots.
Share untouched partitions and keep the input valid if allocation fails.
All ordinals and slot assignments have already passed allocator validation.
"""
function replace_pages(cache::PageCache,removed::BitVector,keys,missing,resolved)
    partitions = copy(cache.partitions)
    owners = copy(cache.slot_partitions)
    lost = 0
    touched = UInt64(0)
    for index in eachindex(removed)
        removed[index] || continue
        part = owners[index]
        part == 0 && continue
        touched |= UInt64(1) << (part-1)
        owners[index] = 0
        lost += 1
    end
    while touched != 0
        part = trailing_zeros(touched)+1
        touched &= touched-1
        entries = copy(partitions[part])
        filter!(entry -> !removed[last(entry)-Dense.SLOT_COUNT+1],entries)
        partitions[part] = entries
    end
    for ordinal in missing
        key,slot = keys[ordinal],resolved[ordinal]
        part = page_partition(key)
        if partitions[part] === cache.partitions[part]
            partitions[part] = copy(partitions[part])
        end
        partitions[part][key] = slot
        owners[slot-Dense.SLOT_COUNT+1] = part
    end
    return PageCache(partitions,owners,cache.count-lost+length(missing))
end

"""Discard overwritten physical slots while retaining untouched partitions."""
function forget_cached_slots(cache::PageCache,overwritten)
    removed = falses(length(cache.slot_partitions))
    for slot in overwritten
        index = slot-Dense.SLOT_COUNT+1
        1 <= index <= length(removed) && (removed[index] = true)
    end
    return replace_pages(cache,removed,(),(),())
end

"""Discard overwritten slots from a compact profile's ordinary page dictionary."""
forget_cached_slots(cache::Dict,overwritten) = filter(entry -> last(entry) ∉ overwritten,cache)
