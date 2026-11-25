"""Select, stage and retain bounded source pages for the shared native GPU shader."""
module RasterPages

import ...Vellum as V
import ...Vellum: ImageStorage as Storage, ImageTiles as Tiles
import ..RasterAssets as Dense
"""Version marker for packets containing sparse source lookup tables."""
const MAGIC = 20261123
"""Page width and height in source pixels."""
const SIDE = 64
"""Maximum source pages cached on targets within `COMPACT_EXTENT`."""
const CAPACITY = 128
"""Largest physical extent using the original 128-page allocation."""
const COMPACT_EXTENT = (768,512)
"""Maximum source pages cached on the extended physical target."""
const EXTENDED_CAPACITY = 768
"""Negotiated packet marker for a Vulkan surface with reserved replacement slots."""
const STREAM_MAGIC = 20261124
"""Packet marker for a Vulkan stream with overlapping completed and candidate page sets."""
const LAYER_MAGIC = 20261125
"""Maximum simultaneously drawn source pages in the streamed 8K Vulkan profile."""
const STREAM_ACTIVE = 8160
"""Maximum active pages in a layered Vulkan frame with a bounded replacement union."""
const LAYER_ACTIVE = 10_240
"""Page slots reserved for the completed and replacement drawings in the streamed profile."""
const STREAM_SLOTS = 2*STREAM_ACTIVE
"""Maximum owned Julia pixel payload passed to one Vulkan source transfer."""
const STREAM_BATCH_BYTES = 2*1024^2
"""Bits used to record one supported source dimension minus one."""
const SOURCE_DIMENSION_BITS = 24
"""Maximum logical dimension admitted for paged sources."""
const SOURCE_SIDE = 1 << SOURCE_DIMENSION_BITS
"""Mask for either source dimension in the private packed descriptor."""
const SOURCE_DIMENSION_MASK = UInt64(SOURCE_SIDE-1)
"""Physical halo and sampling are expressed in quarter-pixel units."""
const SAMPLE_AXIS = 4
"""Maximum number of visited sections of the coverage sample grid per plan."""
const VISITS_LIMIT = 65_536
"""Number of packed words in each sorted page lookup entry."""
const PAGE_WORDS = 5
"""Upper bound in bytes for one native packet and its resident record buffer."""
const RECORD_BYTES = 524_288
"""Maximum lookup rows even when multiple draws reference the same resident pages."""
const MAX_LOOKUPS = RECORD_BYTES ÷ (sizeof(Float64)*PAGE_WORDS)
"""Staging budget per tile, covering provider output, independent lease and normalized pixels."""
const CONVERSION_BYTES = 3 * SIDE * SIDE * 4
"""
Exact native-planning reference: two 24-bit dimension-minus-one values and
a descriptor index, alongside the full opaque authority identifiers.
Only validated top-left tiled references within `SOURCE_SIDE` are admitted.
"""
struct PageSource
    """Full resolver namespace."""
    namespace::UInt128
    """Asset identifier within the namespace."""
    asset::UInt64
    """Exact immutable revision identifier."""
    revision::UInt64
    """Width and height minus one followed by the format, alpha and color code."""
    descriptor::UInt64
end

"""Pixel formats admitted by the portable raster reference."""
const PAGE_FORMATS = (:gray8,:rgb8,:bgr8,:rgba8,:bgra8)
"""Alpha modes admitted by the portable raster reference."""
const PAGE_ALPHAS = (:none,:straight,:premultiplied)
"""Color spaces admitted by the portable raster reference."""
const PAGE_COLORS = (:srgb,:linear_srgb)

"""
    PageSource(source::RasterReference) -> PageSource

Pack one validated top-left tiled reference. A dimension outside
`1:SOURCE_SIDE` raises `ArgumentError`. Preserve the full resolver identity.
"""
function PageSource(source::V.RasterReference)
    m = source.metadata
    1 <= m.width <= SOURCE_SIDE && 1 <= m.height <= SOURCE_SIDE ||
        throw(ArgumentError("GPU tiled images require addressable source dimensions"))
    format = findfirst(isequal(m.format),PAGE_FORMATS)-1
    alpha = findfirst(isequal(m.alpha),PAGE_ALPHAS)-1
    color = findfirst(isequal(m.color_space),PAGE_COLORS)-1
    code = format + length(PAGE_FORMATS)*(alpha + length(PAGE_ALPHAS)*color)
    descriptor = UInt64(m.width-1) | UInt64(m.height-1)<<SOURCE_DIMENSION_BITS |
                 UInt64(code)<<(2*SOURCE_DIMENSION_BITS)
    return PageSource(source.namespace,source.asset,source.revision,descriptor)
end
"""Keep an already packed source when lowering a draw."""
PageSource(source::PageSource) = source

"""Decode the two positive source dimensions from a validated packed descriptor."""
function source_dimensions(source::PageSource)
    bits = source.descriptor
    return (Int(bits & SOURCE_DIMENSION_MASK)+1,
            Int((bits >> SOURCE_DIMENSION_BITS) & SOURCE_DIMENSION_MASK)+1)
end

"""Reconstruct the public reference only when a changed page needs its authority."""
function reference(source::PageSource)
    code = Int(source.descriptor >> (2*SOURCE_DIMENSION_BITS))
    alpha_color,format = divrem(code,length(PAGE_FORMATS))
    color,alpha = divrem(alpha_color,length(PAGE_ALPHAS))
    width,height = source_dimensions(source)
    metadata = V.ImageMetadata(width,height;format=PAGE_FORMATS[format+1],
        alpha=PAGE_ALPHAS[alpha+1],color_space=PAGE_COLORS[color+1],
        storage=:tiled)
    return V.RasterReference(source.namespace,source.asset,source.revision,metadata)
end

"""Retain the portable reference's seeded identity hash."""
Base.hash(source::PageSource,seed::UInt) = hash((source.namespace,source.asset,source.revision),seed)

"""
One exact authority and zero-based page coordinates for uploads. A nonzero
identity proves that this page's packed pixels are shared across revisions.
The cache holds only numeric identity and descriptor metadata.
"""
struct TileKey
    """Packed exact source reference."""
    packed::PageSource
    """Zero-based page column."""
    x::Int32
    """Zero-based page row."""
    y::Int32
    """Validated shared identity, or zero for an exact revision page."""
    identity::UInt64
end

"""Pack a reference and page coordinates while preserving any shared identity."""
TileKey(source::V.RasterReference,x,y,identity) = TileKey(PageSource(source),x,y,identity)
"""Compatibility accessor; reconstructing the reference is intended for cold paths."""
Base.getproperty(key::TileKey,name::Symbol) = name === :source ? reference(getfield(key,:packed)) : getfield(key,name)
"""Construct a page key specific to one exact revision."""
TileKey(source,x,y) = TileKey(source,x,y,UInt64(0))

"""Match shared pages by validated tile identity and other pages by revision and location."""
function Base.isequal(a::TileKey,b::TileKey)
    a.identity == b.identity || return false
    return a.identity != 0 || (a.x == b.x && a.y == b.y && isequal(a.packed,b.packed))
end

"""Hash the same tile identity or exact revision coordinates used for equality."""
Base.hash(key::TileKey,seed::UInt) = key.identity == 0 ? hash((key.packed,key.x,key.y),seed) : hash(key.identity,seed)

include("page_cache.jl")

"""Return the cache slot count for a validated two-dimensional target extent."""
page_capacity(size) = all(size .<= COMPACT_EXTENT) ? CAPACITY : EXTENDED_CAPACITY

"""
Completed source slots and the bounded page cache. `pages` contains active
draw references. `cached` includes inactive device pages. `recency` orders
physical slot numbers (UInt16) from least to most recently drawn. Slot values are zero-based.
Treat all published maps and orderings as read-only so later frames can
share a completed cache without changing its state on failure.
"""
struct Resident
    dense::Dense.Slots
    pages::Dict{TileKey,Int}
    cached::Union{Dict{TileKey,Int},PageCache}
    recency::Vector{UInt16}
    retain_inactive::Bool
end

"""Vacant dense and source-page slots before initial execution."""
const EMPTY = Resident(Dense.EMPTY_SLOTS,Dict{TileKey,Int}(),Dict{TileKey,Int}(),UInt16[],true)

"""Select whether the installed bridge preserves inactive pages. Use only at surface initialization."""
with_cache(resident::Resident,enabled::Bool) =
    Resident(resident.dense,resident.pages,resident.cached,resident.recency,enabled)

"""
One compact row in a draw's source page table. The source key lives in
`Selection.distinct` at `ordinal`. Preserve the draw's coordinates and
extent even when it shares a device slot with a page at another position.
"""
struct PageLookup
    x::Int32
    y::Int32
    ordinal::Int32
    width::UInt8
    height::UInt8
end

"""
One frame's row-ordered lookups and distinct source tiles in first-use order.
Until packing consumes it, `slots` maps each key to its negative distinct index.
"""
mutable struct Selection
    ordered::Vector{PageLookup}
    slots::Dict{TileKey,Int}
    distinct::Vector{TileKey}
    visits::Int
    has_paged_draws::Bool
    capacity::Int
    shared::Union{Nothing,Dict{V.RasterReference,Tiles.OwnedTileRevision}}
end

"""Create empty source lookup scratch for a single pack operation."""
Selection(capacity=CAPACITY,shared=nothing) =
    Selection(PageLookup[],Dict{TileKey,Int}(),TileKey[],0,false,capacity,shared)

"""Return the packed source extent, including right and bottom partial pages."""
function dimensions(key::TileKey)
    (;packed,x,y) = key
    width,height = source_dimensions(packed)
    return (min(SIDE,width-x*SIDE),min(SIDE,height-y*SIDE))
end

"""
    texel_range(low, high, origin, finish, linear) -> Tuple{Int,Int}

Find the inclusive source indices reached by an interval of coverage samples.
Linear filtering includes both neighbors and clamps them to the source crop.
Inputs are finite affine extrema and addressable crop bounds.
"""
function texel_range(low,high,origin,finish,linear)
    shift = linear ? 0.5 : 0.0
    upper_tap = Int(linear)
    first = clamp(floor(Int,low-shift),origin,finish)
    last = clamp(floor(Int,high-shift)+upper_tap,origin,finish)
    return first,last
end

"""
    footprint(mapping, crop, linear, grid) -> NTuple{4,Int}

Bound the zero-based source page rectangle touched by a sample-grid block.
Crop bounds and the affine source map must already be validated.
"""
function footprint(mapping,crop,linear,grid)
    x0,y0,x1,y1 = grid
    first_x,first_y = (x0+0.5)/SAMPLE_AXIS,(y0+0.5)/SAMPLE_AXIS
    last_x,last_y = (x1+0.5)/SAMPLE_AXIS,(y1+0.5)/SAMPLE_AXIS
    a,b,c,d = (V.map_point(mapping,point) for point in
        ((first_x,first_y),(last_x,first_y),(first_x,last_y),(last_x,last_y)))
    lx,hx = texel_range(min(a[1],b[1],c[1],d[1]),max(a[1],b[1],c[1],d[1]),crop[1],crop[3],linear)
    ly,hy = texel_range(min(a[2],b[2],c[2],d[2]),max(a[2],b[2],c[2],d[2]),crop[2],crop[4],linear)
    return (lx÷SIDE,hx÷SIDE,ly÷SIDE,hy÷SIDE)
end

"""Register one footprint visit and reject excess packing work."""
function record_visit!(selection)
    selection.visits += 1
    selection.visits <= VISITS_LIMIT || V.model_error(:resource_limit,"GPU source selection work limit exceeded")
    return nothing
end

"""Use exact-revision identity when the provider has no shared tile index."""
page_key(source,x,y,::Nothing) = TileKey(source,x,y)

"""Return the shared page key, or `nothing` for an absent transparent tile."""
function page_key(source,x,y,index)
    tile = get(index,(x,y),nothing)
    return isnothing(tile) ? nothing : TileKey(source,x,y,tile.id)
end

"""
Append one ordered lookup and record the key's first use. A distinct page
over the configured capacity raises a resource-limit error.
"""
function append_page!(selection,key)
    next = length(selection.distinct)+1
    ordinal = -get!(selection.slots,key,-next)
    length(selection.slots)<=selection.capacity || V.model_error(:resource_limit,"GPU source page capacity exceeded")
    length(selection.ordered)<MAX_LOOKUPS || throw(ArgumentError("packed native vector record budget exceeded"))
    ordinal == next && push!(selection.distinct,key)
    width,height = dimensions(key)
    push!(selection.ordered,PageLookup(key.x,key.y,ordinal,width,height))
    return nothing
end

"""
    reserve_page_vector!(table, count)

Reserve scratch capacity without shrinking storage. Julia 1.10 has no
nonshrinking hint, so vectors grow through their ordinary append operations.
"""
function reserve_page_vector!(table::Vector,count::Integer)
    @static if VERSION >= v"1.11"
        sizehint!(table,count;shrink=false)
    end
    return nothing
end

"""
    reserve_lookup!(selection, count)

Reserve append space for a draw's candidate lookups and distinct keys.
When the current sizes approach the page budget, reserve the rest of that
budget in the same allocation so the next layered draw can append in place.
Bound hints for the ordered lookup table even when separate draws repeat
the same pages.
"""
function reserve_lookup!(selection,count)
    capacity = selection.capacity
    ordered = length(selection.ordered)+count
    distinct = length(selection.slots)+count
    ordered_hint = ordered >= capacity÷2 ? max(capacity,ordered) : ordered
    distinct_hint = distinct >= capacity÷2 ? capacity : distinct
    reserve_page_vector!(selection.ordered,min(MAX_LOOKUPS,ordered_hint))
    sizehint!(selection.slots,distinct_hint)
    reserve_page_vector!(selection.distinct,distinct_hint)
    return nothing
end

"""
    visit!(selection, local_pages, source, mapping, crop, linear, grid, [index])

Conservatively collect pages from a rectangle of quarter-pixel sample
positions. Subdivide sparse minification footprints before considering
provider reads. Raise a resource-limit error before expanding an oversized
working set or iterating an unbounded grid.
"""
function visit!(selection,local_pages,source,mapping,crop,linear,grid,index=nothing)
    record_visit!(selection)
    x0,y0,x1,y1 = grid
    left,right,top,bottom = footprint(mapping,crop,linear,grid)
    columns,rows = x1-x0+1,y1-y0+1
    tiles = (right-left+1)*(bottom-top+1)
    if tiles==1 || columns*rows==1
        for y in top:bottom, x in left:right
            key = page_key(source,x,y,index)
            key === nothing && continue
            push!(local_pages,(x,y))
            length(local_pages)<=selection.capacity || V.model_error(:resource_limit,"GPU page lookup exceeds capacity")
        end
    elseif columns >= rows
        mid = x0+(x1-x0)÷2
        visit!(selection,local_pages,source,mapping,crop,linear,(x0,y0,mid,y1),index)
        visit!(selection,local_pages,source,mapping,crop,linear,(mid+1,y0,x1,y1),index)
    else
        mid = y0+(y1-y0)÷2
        visit!(selection,local_pages,source,mapping,crop,linear,(x0,y0,x1,mid),index)
        visit!(selection,local_pages,source,mapping,crop,linear,(x0,mid+1,x1,y1),index)
    end
    return nothing
end

"""
    append_grid!(selection, source, bounds)

Append a dense page rectangle directly in row order. A source whose exact
rectangle exceeds the active-page capacity is rejected before enumeration.
"""
function append_grid!(selection,source,bounds)
    record_visit!(selection)
    source = PageSource(source)
    left,right,top,bottom = bounds
    count = (right-left+1)*(bottom-top+1)
    count <= selection.capacity || V.model_error(:resource_limit,"GPU source page capacity exceeded")
    reserve_lookup!(selection,count)
    for y in top:bottom, x in left:right
        append_page!(selection,TileKey(source,x,y))
    end
    return nothing
end

"""
    append_shared_grid!(selection, source, bounds, index)

Append populated tiles within a rectangular grid in row-major order. Walk
the smaller of the requested grid and the validated sparse index. Missing
entries sample transparent black without occupying device slots.
"""
function append_shared_grid!(selection,source,bounds,index)
    record_visit!(selection)
    source = PageSource(source)
    left,right,top,bottom = bounds
    area = (right-left+1)*(bottom-top+1)
    if area < length(index)
        coords = ((x,y) for y in top:bottom for x in left:right)
        count = area
    else
        coords = sort!([(x,y) for (x,y) in keys(index) if left<=x<=right && top<=y<=bottom];by=reverse)
        count = length(coords)
    end
    first = length(selection.ordered)
    reserve_lookup!(selection,min(selection.capacity,count))
    for (x,y) in coords
        key = page_key(source,x,y,index)
        key === nothing && continue
        length(selection.ordered)-first < selection.capacity || V.model_error(:resource_limit,"GPU page lookup exceeds capacity")
        append_page!(selection,key)
    end
    return nothing
end

"""Append one draw's sorted page lookup from its sample grid and optional validated index."""
function append_lookup!(selection,source,mapping,crop,linear,grid,dense_grid,index)
    index !== nothing && isempty(index) && return nothing
    source = PageSource(source)
    if dense_grid
        bounds = footprint(mapping,crop,linear,grid)
        return isnothing(index) ? append_grid!(selection,source,bounds) :
            append_shared_grid!(selection,source,bounds,index)
    end
    local_pages = Set{Tuple{Int,Int}}()
    visit!(selection,local_pages,source,mapping,crop,linear,grid,index)
    for (x,y) in sort!(collect(local_pages);by=reverse)
        append_page!(selection,page_key(source,x,y,index)::TileKey)
    end
    return nothing
end

"""
    append_record!(records, selection, source, op, transform, bounds, size, halo) -> Int

Describe a paged image draw and append its row-sorted page lookup. Clip the
sample grid to physical geometry and effect support. No provider I/O occurs.
Invalid affine coordinates, layouts or an over-budget footprint throw.
"""
function append_record!(records,selection,source,op,transform,bounds,size,halo)
    m = source.metadata
    1 <= m.width <= SOURCE_SIDE && 1 <= m.height <= SOURCE_SIDE && ENDIAN_BOM == 0x04030201 ||
        throw(ArgumentError("GPU tiled images require little-endian data and addressable source dimensions"))
    crop = Dense.crop_bounds(op)
    0 <= crop[1] <= crop[3] < m.width && 0 <= crop[2] <= crop[4] < m.height ||
        throw(ArgumentError("image source crop exceeds tiled asset bounds"))
    mapping = Dense.source_mapping(op,transform)
    linear = op.state.sampling === :linear
    a,b,c,d,_,_ = mapping.coefficients
    dense_grid = (iszero(b) && iszero(c) || iszero(a) && iszero(d)) &&
        max(abs(a),abs(b),abs(c),abs(d)) <= SIDE*SAMPLE_AXIS
    first = length(selection.ordered)
    if bounds !== nothing
        l,t,r,b = bounds
        x0 = max(-halo[1],floor(Int,l))
        y0 = max(-halo[2],floor(Int,t))
        x1 = min(size[1]+halo[1],ceil(Int,r))
        y1 = min(size[2]+halo[2],ceil(Int,b))
        if x0 < x1 && y0 < y1
            grid = (SAMPLE_AXIS*x0,SAMPLE_AXIS*y0,SAMPLE_AXIS*x1-1,SAMPLE_AXIS*y1-1)
            authority = isnothing(selection.shared) ? nothing : get(selection.shared,source,nothing)
            if isnothing(authority)
                append_lookup!(selection,source,mapping,crop,linear,grid,dense_grid,nothing)
            else
                Tiles.with_shared_tiles(authority) do index
                    append_lookup!(selection,source,mapping,crop,linear,grid,dense_grid,index)
                end
            end
        end
    end
    index = length(records) ÷ Dense.RECORD_WORDS
    append!(records,(first,length(selection.ordered)-first,0,crop...,Int(linear),mapping.coefficients...))
    selection.has_paged_draws = true
    return index
end

"""
    allocate_slots!(selection, resident, dense, [resolved]; streamed=false) -> Resident

Keep matching revision keys in their physical device slots. Fill vacant
slots, then evict least recently drawn pages outside the new working set.
In streamed mode, reserve the previous drawing's active slots until its
replacement is complete. Older bridges keep only the active working set.
Throw before pixel reads if the union of the two active sets exceeds the
available slots. The candidate may take ownership of the selection's slot
table. Discard the selection after a failure. Its ordered lookups remain
available after success. The completed resident is read-only. The exclusive
`resolved` scratch receives physical slots in first-use order; it is emptied
on failure and is never owned by the returned resident.
"""
function allocate_slots!(selection::Selection,resident::Resident,dense,resolved::Vector{Int}=Int[];streamed=false)
    empty!(resolved)
    try
        active = selection.slots
        recent = selection.distinct
        if length(active) == length(resident.pages)
            for key in recent
                slot = get(resident.pages,key,-1)
                slot < 0 && break
                push!(resolved,slot)
            end
            if length(resolved) == length(recent)
                return Resident(dense,resident.pages,resident.cached,resident.recency,resident.retain_inactive)
            end
            empty!(resolved)
        end
        selection.slots = Dict{TileKey,Int}()
        missing = Int[]
        retained = resident.retain_inactive
        previous = retained ? resident.cached : resident.pages
        for (ordinal,key) in enumerate(recent)
            slot = get(previous,key,-1)
            active[key] = slot
            push!(resolved,slot)
            slot < 0 && push!(missing,ordinal)
        end
        capacity = streamed ? STREAM_SLOTS : selection.capacity
        idle = UInt16[]
        if retained
            sizehint!(idle,min(capacity,length(previous)+length(missing)))
            selected = falses(capacity)
            for slot in values(active)
                slot >= 0 && (selected[slot-Dense.SLOT_COUNT+1] = true)
            end
            for slot in resident.recency
                selected[Int(slot)-Dense.SLOT_COUNT+1] || push!(idle,slot)
            end
        end
        if isempty(missing)
            append!(idle,(UInt16(slot) for slot in resolved))
            return Resident(dense,active,retained ? previous : active,idle,retained)
        end
        retained || sizehint!(active,min(capacity,length(previous)+length(missing)))
        free = trues(capacity)
        if previous isa PageCache && length(free) == length(previous.slot_partitions)
            @inbounds for index in eachindex(free)
                free[index] = previous.slot_partitions[index] == 0
            end
        else
            for slot in values(retained ? previous : active)
                slot >= 0 && (free[slot-Dense.SLOT_COUNT+1] = false)
            end
        end
        protected = falses(capacity)
        if streamed
            for slot in values(resident.pages)
                protected[slot-Dense.SLOT_COUNT+1] = true
                retained || (free[slot-Dense.SLOT_COUNT+1] = false)
            end
        end

        first_idle, first_free = 1, 1
        evicted = falses(capacity)
        for ordinal in missing
            index = findnext(free,first_free)
            if index === nothing
                while streamed && first_idle <= length(idle) && protected[Int(idle[first_idle])-Dense.SLOT_COUNT+1]
                    first_idle += 1
                end
                first_idle <= length(idle) || V.model_error(:resource_limit,"replacement would evict a completed source page")
                slot = Int(idle[first_idle])
                evicted[slot-Dense.SLOT_COUNT+1] = true
                first_idle += 1
            else
                slot = Dense.SLOT_COUNT+index-1
                first_free = index+1
            end
            active[recent[ordinal]] = slot
            resolved[ordinal] = slot
        end
        if any(evicted)
            filter!(slot -> !evicted[Int(slot)-Dense.SLOT_COUNT+1],idle)
        end
        cached = if !retained
            active
        elseif streamed
            replace_pages(partitioned_cache(previous),evicted,recent,missing,resolved)
        else
            cache = copy(previous)
            sizehint!(cache,min(capacity,length(previous)+length(missing)))
            if any(evicted)
                filter!(entry -> !evicted[last(entry)-Dense.SLOT_COUNT+1],cache)
            end
            for ordinal in missing
                cache[recent[ordinal]] = resolved[ordinal]
            end
            cache
        end
        append!(idle,(UInt16(slot) for slot in resolved))
        return Resident(dense,active,cached,idle,retained)
    catch
        empty!(resolved)
        rethrow()
    end
end

"""
    forget_slots(resident, overwritten) -> Resident

Return a completed page cache without inactive slots touched by an aborted
stream. The active draw must have independent slots. Throws if a stream
attempted to touch a slot used by the completed revision.
"""
function forget_slots(resident::Resident,overwritten::BitSet)
    isempty(overwritten) && return resident
    any(in(overwritten),values(resident.pages)) && error("stream changed an active source slot")
    cached = forget_cached_slots(resident.cached,overwritten)
    recency = filter(slot -> slot ∉ overwritten,resident.recency)
    return Resident(resident.dense,resident.pages,cached,recency,resident.retain_inactive)
end

"""
    append_pages!(words, selection, active) -> Vector{Float64}

Append five native words per selected page in draw order, retaining
partial edge dimensions. Every selected key must have an assigned slot
in `active`. A missing slot raises `KeyError`.
"""
function append_pages!(words::Vector{Float64},selection,active::Dict{TileKey,Int})
    resolved = [active[key] for key in selection.distinct]
    return append_pages!(words,selection,resolved)
end

"""
    append_pages!(words, selection, resolved) -> Vector{Float64}

Append ordered rows using fully assigned first-use ordinal slots. `words` is
mutated; `selection` and the exclusive resolved scratch are read-only. The
caller must supply one resolved slot per distinct key.
"""
function append_pages!(words::Vector{Float64},selection,resolved::Vector{Int})
    length(resolved) == length(selection.distinct) || throw(ArgumentError("incomplete page slot resolution"))
    offset = length(words)
    resize!(words,offset+PAGE_WORDS*length(selection.ordered))
    for lookup in selection.ordered
        @inbounds begin
            words[offset+1] = lookup.x
            words[offset+2] = lookup.y
            words[offset+3] = resolved[lookup.ordinal]
            words[offset+4] = lookup.width
            words[offset+5] = lookup.height
        end
        offset += PAGE_WORDS
    end
    return words
end

"""
    check_cancelled(cancelled) -> nothing

Throw `InterruptException` when the caller withdrew the source request.
"""
check_cancelled(cancelled) = cancelled() ? throw(InterruptException()) : nothing

"""Revision lease adapter carrying the worker's cooperative cancellation predicate."""
struct CancellableSource{L,F} <: Storage.AbstractImageProvider
    lease::L
    cancelled::F
end

"""Read the authoritative, immutable image metadata from the wrapped lease."""
Storage.image_metadata(source::CancellableSource) = Storage.image_metadata(source.lease)

"""Borrow exactly this page from the lease, forwarding cooperative cancellation."""
function Storage.borrow_pixels(source::CancellableSource,region;kwargs...)
    return Storage.borrow_pixels(source.lease,region;cancelled=source.cancelled,kwargs...)
end

"""
    stage_page(lease, key, cancelled) -> Vector{UInt8}

Read one bounded source rectangle through the exact authority, convert it
to packed premultiplied sRGB RGBA8, and return the independent owned bytes.
Provider, cancellation and conversion errors propagate before a native
upload. An existing provider read may finish before cancellation is seen.
"""
function stage_page(lease,key::TileKey,cancelled)
    region = (key.x*SIDE,key.y*SIDE,dimensions(key)...)
    check_cancelled(cancelled)
    source = CancellableSource(lease,cancelled)
    converted = Storage.convert_buffer(source;region,format=:rgba8,alpha=:premultiplied,
                                       color_space=:srgb,budget_bytes=CONVERSION_BYTES)
    try
        check_cancelled(cancelled)
        return converted.buffer.owner.bytes::Vector{UInt8}
    finally
        close(converted.buffer)
    end
end

"""
    shared_upload_bytes(authority, key, cancelled) -> String

Return the existing immutable upload bytes for a page from a pinned owned
revision. Check its identity, extent and per-region limit under the source
lock. The returned string owns its payload after the lock is released.
Invalid or retired sources and cancellation raise before an upload.
"""
function shared_upload_bytes(authority::Tiles.OwnedTileRevision,key::TileKey,cancelled)
    check_cancelled(cancelled)
    bytes = Tiles.with_shared_tiles(authority) do index
        tile = get(index,(Int(key.x),Int(key.y)),nothing)
        tile !== nothing && tile.id == key.identity && tile.extent == dimensions(key) ||
            V.model_error(:invalid_input,"shared GPU tile no longer matches its exact revision")
        length(tile) <= authority.max_region_bytes ||
            V.model_error(:resource_limit,"owned revision region exceeds staging budget")
        return tile.pixels.bytes
    end
    check_cancelled(cancelled)
    return bytes
end

"""Compact changed-page coordinates, identity and destination for one grouped source."""
struct UploadPage
    """Zero-based source tile column."""
    x::Int32
    """Zero-based source tile row."""
    y::Int32
    """Validated shared tile identity, or zero for an exact-revision page."""
    identity::UInt64
    """Zero-based destination slot in the candidate resident map."""
    slot::Int
end

"""
    upload_delta(before::Resident, after::Resident)

Return the changed sources in first-encounter order and a parallel array
of compact page records in candidate map order within each source. A page
changes when the completed cache lacks its key at the candidate slot.
Source reads and cache mutations occur outside this function.
"""
function upload_delta(before::Resident,after::Resident)
    indices = Dict{V.RasterReference,Int}()
    sources = V.RasterReference[]
    groups = Vector{UploadPage}[]
    for (key,slot) in after.pages
        already_cached(before.cached,after.cached,key,slot) && continue
        source = key.source
        index = get(indices,source,0)
        if index == 0
            push!(sources,source)
            push!(groups,UploadPage[])
            index = length(sources)
            indices[source] = index
        end
        push!(groups[index],UploadPage(key.x,key.y,key.identity,slot))
    end
    return sources,groups
end

"""
    visit_uploads(emit, plan, before, after, resolver; cancelled) -> nothing

Obtain independent execution pins and pass each newly selected page's
owned bytes to `emit`. Region leases close before each call to `emit`.
Always close execution and source leases. Provider, cancellation and
consumer exceptions propagate to the caller.
"""
function visit_uploads(emit,plan::V.PreparedFrame,before::Resident,after::Resident,resolver;cancelled=()->false)
    check_cancelled(cancelled)
    external = any(record -> record.payload isa V.RasterReference,plan.frame.resources)
    external || return nothing
    plan.retention isa Tiles.AbstractRevisionLease && Tiles.revision_resolver(plan.retention) === resolver ||
        V.model_error(:invalid_input,"GPU provider plan lacks its resolver retention")
    owned = V.execution_retention(plan)
    try
        shared = owned isa Tiles.RevisionLease ? Tiles.shared_tile_sources(owned,SIDE) : nothing
        revisions,groups = upload_delta(before,after)
        for (source,group) in zip(revisions,groups)
            check_cancelled(cancelled)
            lease = Tiles.acquire_revision(owned,source)
            try
                authority = shared === nothing ? nothing : get(shared,source,nothing)
                for page in group
                    key = TileKey(source,page.x,page.y,page.identity)
                    bytes = authority !== nothing && key.identity != 0 ?
                        shared_upload_bytes(authority,key,cancelled) : stage_page(lease,key,cancelled)
                    emit(Dense.StagedUpload(page.slot,bytes))
                end
            finally
                close(lease)
            end
        end
    finally
        close(owned)
    end
    check_cancelled(cancelled)
    return nothing
end

"""
    stage_uploads(plan, before, after, resolver; cancelled) -> Vector{StagedUpload}

Collect the compact profile's changed dense images and source pages. Any
exception discards the owned staging before native submission.
"""
function stage_uploads(plan::V.PreparedFrame,before::Resident,after::Resident,resolver;cancelled=()->false)
    uploads = Dense.uploads(before.dense,after.dense)
    visit_uploads(item -> push!(uploads,item),plan,before,after,resolver;cancelled)
    return uploads
end

end
