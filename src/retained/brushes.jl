"""Edit a sparse paint layer with pressure-sensitive round strokes and checkpointed history."""
module Brushes

using ..Vellum: ImageTiles
using ..Vellum.ImageTiles: RgbaTile

export PointerSample, RoundBrush, PaintLayer, begin_stroke!, append_samples!,
       commit_stroke!, cancel_stroke!, undo!, redo!, paint_revision, paint_usage

"""Number of subpixel positions on each axis of a paint coverage pixel."""
const SAMPLE_AXIS = 4

"""Coverage mask for a pixel whose sixteen sample positions are inside the stroke."""
const FULL_COVERAGE = typemax(UInt16)

"""Fixed logical history charge for each command, in addition to its samples and tiles."""
const COMMAND_CHARGE = 96

"""Logical history charge for each retained normalized input sample."""
const SAMPLE_CHARGE = 72

"""Logical history charge for each patch, in addition to its checkpoint bytes."""
const PATCH_CHARGE = 64

"""Zero-based `(column, row)` key in the paint layer's tile grid."""
const TileKey = Tuple{Int,Int}

"""Immutable packed RGBA8 tile bytes, or `nothing` for a transparent tile."""
const PaintTile = Union{RgbaTile,Nothing}

"""
    PointerSample(x, y, time, pointer; pressure=nothing, tilt=nothing)

Normalize a pointer event into an owned sample. Positions are in logical
canvas units, `time` is in seconds, and `pointer` is an unsigned device-local
identity. `pressure` is in `[0, 1]`. `tilt` is an optional pair in `[-1, 1]`.
Reject nonfinite values, out-of-range pressure or tilt, and invalid IDs.
"""
struct PointerSample
    x::Float64
    y::Float64
    time::Float64
    pointer::UInt64
    pressure::Union{Nothing,Float64}
    tilt::Union{Nothing,Tuple{Float64,Float64}}

    function PointerSample(x::Real, y::Real, time::Real, pointer::Integer;
                           pressure::Union{Real,Nothing}=nothing,
                           tilt::Union{Tuple{Real,Real},Nothing}=nothing)
        px, py, clock = Float64.((x,y,time))
        all(isfinite,(px,py,clock)) && max(abs(px),abs(py)) <= 2.0^32 ||
            throw(ArgumentError("invalid canvas position or time"))
        !(pointer isa Bool) && 0 <= pointer <= typemax(UInt64) ||
            throw(ArgumentError("pointer must be an unsigned integer identity"))
        p = isnothing(pressure) ? nothing : Float64(pressure)
        (isnothing(p) || 0 <= p <= 1) || throw(ArgumentError("pressure must be in [0, 1]"))
        angles = isnothing(tilt) ? nothing : Float64.(tilt)
        (isnothing(angles) || all(angle -> -1 <= angle <= 1, angles)) ||
            throw(ArgumentError("tilt components must be in [-1, 1]"))
        return new(px,py,clock,UInt64(pointer),p,angles)
    end
end

"""
    RoundBrush(; diameter=24, color=(32,192,240), opacity=255, mode=:paint)

Configure a round brush. `diameter` is in canvas units and may be in `(0,256]`.
Pressure multiplies the diameter, with full pressure for a mouse. `color` is
straight sRGB encoded as three bytes, and `opacity` is a byte. The round recipe
preserves tilt in the input journal and gives it no effect on the pixels.
`:paint` uses source-over and `:erase` uses destination-out on the paint only.
Throw `ArgumentError` for invalid diameter, color, opacity, or mode.
"""
struct RoundBrush
    diameter::Float64
    color::NTuple{3,UInt8}
    opacity::UInt8
    mode::Symbol

    function RoundBrush(; diameter::Real=24, color::NTuple{3,Integer}=(32,192,240),
                        opacity::Integer=255, mode::Symbol=:paint)
        d = Float64(diameter)
        0 < d <= 256 && all(v -> 0 <= v <= 255, color) && 0 <= opacity <= 255 &&
            mode in (:paint,:erase) || throw(ArgumentError("invalid round brush settings"))
        return new(d,UInt8.(color),UInt8(opacity),mode)
    end
end

"""Committed before/after checkpoints of a single tile in one history entry."""
struct TilePatch
    key::TileKey
    before::PaintTile
    after::PaintTile
end

"""A retained stroke identity, ordered input events, brush recipe and changed tiles."""
struct StrokeCommand
    id::UInt64
    brush::RoundBrush
    samples::Vector{PointerSample}
    patches::Vector{TilePatch}
    charge::Int
end

"""An active tile's accumulated sample bits and latest immutable preview bytes."""
struct StrokeTile
    bits::Vector{UInt16}
    pixels::PaintTile
end

"""Private staged tile storage for one batch, discarded on a validation error."""
struct WorkTile
    bits::Vector{UInt16}
    pixels::Vector{UInt8}
end

"""A single in-progress stroke plus its ordered events and pending tile checkpoints."""
struct ActiveStroke
    id::UInt64
    brush::RoundBrush
    samples::Vector{PointerSample}
    tiles::Dict{TileKey,StrokeTile}
end

"""
    PaintLayer(width, height; tile_size=64, max_tiles=4096, max_active_tiles=256,
               max_samples=4096, max_stamps_per_batch=16384,
               max_entries=64, history_bytes=256*1024^2)

Create a sparse premultiplied sRGB RGBA8 paint layer with independent committed
and preview states. Editing operations are serialized per layer. `max_tiles`
limits populated tiles, `max_active_tiles` limits scratch tiles per stroke,
`max_samples` limits its ordered samples, and `max_stamps_per_batch` bounds
resampling per event batch. History is limited by both entries and charged
checkpoint bytes. Invalid dimensions or limits throw `ArgumentError`.
Use `paint_revision` to publish the pixels separately from the artwork beneath
or above them. The layer itself owns no Canvas, provider registry or GPU object.
"""
mutable struct PaintLayer
    size::Tuple{Int,Int}
    tile_size::Int
    max_tiles::Int
    max_active_tiles::Int
    max_samples::Int
    max_stamps_per_batch::Int
    max_entries::Int
    history_bytes::Int
    guard::ReentrantLock
    committed::Dict{TileKey,RgbaTile}
    active::Union{Nothing,ActiveStroke}
    commands::Vector{StrokeCommand}
    cursor::Int
    charged_history::Int
    sequence::UInt64
    revision::UInt64

    function PaintLayer(width::Integer,height::Integer;tile_size::Integer=64,
                        max_tiles::Integer=4096,max_active_tiles::Integer=256,
                        max_samples::Integer=4096,max_stamps_per_batch::Integer=16384,
                        max_entries::Integer=64,history_bytes::Integer=256*1024^2)
        all(n -> 0 < n <= 2^24, (width,height)) && 1 <= tile_size <= 256 ||
            throw(ArgumentError("invalid paint dimensions or tile size"))
        all(n -> 0 < n <= typemax(Int), (max_tiles,max_active_tiles,max_samples,
            max_stamps_per_batch,max_entries,history_bytes)) ||
            throw(ArgumentError("paint limits must be positive and addressable"))
        return new((Int(width),Int(height)),Int(tile_size),Int(max_tiles),Int(max_active_tiles),
            Int(max_samples),Int(max_stamps_per_batch),Int(max_entries),Int(history_bytes),
            ReentrantLock(),Dict{TileKey,RgbaTile}(),nothing,StrokeCommand[],0,0,0,0)
    end
end

"""Return the checked successor for a stroke identity or paint revision counter."""
next_counter(counter::UInt64) = Base.checked_add(counter,UInt64(1))

"""Return the clipped physical `(width, height)` of a valid zero-based paint tile."""
function tile_extent(layer::PaintLayer,key::TileKey)
    return min.(layer.tile_size,layer.size .- key .* layer.tile_size)
end

"""Return the active stroke for this identity or reject a missing or stale event."""
function active_stroke(layer::PaintLayer,id::Integer)
    stroke = layer.active
    stroke !== nothing && stroke.id == id || throw(ArgumentError("stroke is no longer active"))
    return stroke
end

"""Return the input disk `(x,y,radius)` using full pressure when the sample has none."""
disk(brush::RoundBrush,sample::PointerSample) =
    (sample.x,sample.y,brush.diameter*0.5*something(sample.pressure,1.0))

"""
    coverage(bits,x,y,cx,cy,radius_squared) -> UInt16

Union one round stamp into the existing 4×4 coverage mask for a pixel. `x,y`
are zero-based canvas pixel coordinates. Sample centers lie at eighths within
that pixel, and points on the circle count as covered.
"""
function coverage(bits::UInt16,x,y,cx,cy,radius_squared)
    bits == FULL_COVERAGE && return bits
    for row in 0:SAMPLE_AXIS-1
        dy = y+(row+0.5)/SAMPLE_AXIS-cy
        dy_squared = dy*dy
        for col in 0:SAMPLE_AXIS-1
            dx = x+(col+0.5)/SAMPLE_AXIS-cx
            if dx*dx+dy_squared <= radius_squared
                bits |= UInt16(1) << (SAMPLE_AXIS*row+col)
            end
        end
    end
    return bits
end

"""Return a tile's old channel byte as an integer, or zero for a transparent checkpoint."""
old_byte(base::PaintTile,offset::Int) = isnothing(base) ? 0 : Int(base[offset])

"""
    apply_pixel!(pixels, offset, base, coverage, brush)

Write one premultiplied RGBA8 pixel from the committed checkpoint and active
coverage. Quantize coverage once and apply stroke opacity once, even when
stamps overlap. An eraser attenuates all four committed channels equally.
"""
function apply_pixel!(pixels::Vector{UInt8},offset::Int,base::PaintTile,bits::UInt16,brush::RoundBrush)
    covered = (255*count_ones(bits)+8) ÷ 16
    alpha = (covered*Int(brush.opacity)+127) ÷ 255
    retained = 255-alpha
    erase = brush.mode === :erase
    for channel in 1:3
        color = erase ? 0 : (alpha*Int(brush.color[channel])+127) ÷ 255
        pixels[offset+channel] = color+(old_byte(base,offset+channel)*retained+127) ÷ 255
    end
    pixels[offset+4] = (erase ? 0 : alpha)+(old_byte(base,offset+4)*retained+127) ÷ 255
    return nothing
end

"""Copy just one staged tile from its prior active or committed checkpoint."""
function stage_tile(layer::PaintLayer,key::TileKey,prior::Union{Nothing,StrokeTile},base::PaintTile)
    n = prod(tile_extent(layer,key))
    bits = isnothing(prior) ? zeros(UInt16,n) : copy(prior.bits)
    checkpoint = isnothing(prior) ? base : prior.pixels
    pixels = isnothing(checkpoint) ? zeros(UInt8,4*n) : collect(codeunits(checkpoint.pixels.bytes))
    return WorkTile(bits,pixels)
end

"""
    stamp!(staged, layer, stroke, center, max_new_tiles, new_tiles)

Union one `(x,y,radius)` disk into affected staged tiles, clipped to the
layer extent. Throw `ArgumentError` before allocating a tile above the active
limit. A rejected batch leaves the live layers and sample journal untouched.
"""
function stamp!(staged,layer::PaintLayer,stroke::ActiveStroke,center,max_new_tiles,new_tiles)
    cx,cy,r = center
    (r > 0 && stroke.brush.opacity != 0) || return nothing
    width,height = layer.size
    left,top = floor(Int,clamp(cx-r,0,width)),floor(Int,clamp(cy-r,0,height))
    right,bottom = ceil(Int,clamp(cx+r,0,width)),ceil(Int,clamp(cy+r,0,height))
    left < right && top < bottom || return nothing
    side = layer.tile_size
    for ty in div(top,side):div(bottom-1,side), tx in div(left,side):div(right-1,side)
        key = (tx,ty)
        origin_x,origin_y = key .* side
        w,h = tile_extent(layer,key)
        base = get(layer.committed,key,nothing)
        tile = get!(staged,key) do
            prior = get(stroke.tiles,key,nothing)
            if isnothing(prior)
                new_tiles[] < max_new_tiles || throw(ArgumentError("stroke tile limit exceeded"))
                new_tiles[] += 1
            end
            stage_tile(layer,key,prior,base)
        end
        for y in max(top,origin_y):min(bottom,origin_y+h)-1
            for x in max(left,origin_x):min(right,origin_x+w)-1
                index = (y-origin_y)*w+x-origin_x+1
                previous = tile.bits[index]
                bits = coverage(previous,x,y,cx,cy,r*r)
                if bits != previous
                    tile.bits[index] = bits
                    apply_pixel!(tile.pixels,4*(index-1),base,bits,stroke.brush)
                end
            end
        end
    end
    return nothing
end

"""Preflight a batch of ordered events without modifying the caller's journal."""
function stage_samples(layer::PaintLayer,stroke::ActiveStroke,batch)
    staged = PointerSample[]
    previous = isempty(stroke.samples) ? nothing : last(stroke.samples)
    remaining = layer.max_samples-length(stroke.samples)
    for sample in batch
        sample isa PointerSample || throw(ArgumentError("expected a PointerSample"))
        length(staged) < remaining || throw(ArgumentError("stroke sample limit exceeded"))
        if previous !== nothing
            sample.pointer == previous.pointer && sample.time >= previous.time ||
                throw(ArgumentError("stroke samples must use one pointer and nondecreasing time"))
        end
        push!(staged,sample)
        previous = sample
    end
    return staged
end

"""Report the logical checkpoint bytes owned by one immutable tile, excluding metadata."""
tile_bytes(pixels::PaintTile) = isnothing(pixels) ? 0 : length(pixels)

"""Report whether two packed checkpoints contain identical paint."""
same_tile(a::PaintTile,b::PaintTile) = a === b ||
    (a !== nothing && b !== nothing && a.pixels.bytes == b.pixels.bytes)

"""Keep the previous tile identity if its bytes still match the staged preview."""
function freeze_preview(layer::PaintLayer,stroke::ActiveStroke,key::TileKey,tile::WorkTile)
    prior = get(stroke.tiles,key,nothing)
    before = isnothing(prior) ? get(layer.committed,key,nothing) : prior.pixels
    pixels = tile.pixels
    if before !== nothing && pixels == codeunits(before.pixels.bytes)
        return StrokeTile(tile.bits,before)
    end
    next = all(iszero,pixels) ? nothing : RgbaTile(tile_extent(layer,key)...,pixels)
    return StrokeTile(tile.bits,next)
end

"""
    plan_batch(layer, stroke, samples)

Resample straight segments by half the smaller radius, with a half-pixel
minimum spacing to handle zero pressure. Return only touched tile patches.
Work, visible-tile and history limits reject the batch before publication.
"""
function plan_batch(layer::PaintLayer,stroke::ActiveStroke,samples::Vector{PointerSample})
    staged = Dict{TileKey,WorkTile}()
    previous = isempty(stroke.samples) ? nothing : disk(stroke.brush,last(stroke.samples))
    remaining = layer.max_stamps_per_batch
    maximum_new = layer.max_active_tiles-length(stroke.tiles)
    new_tiles = Ref(0)
    for sample in samples
        target = disk(stroke.brush,sample)
        if previous === nothing
            remaining > 0 || throw(ArgumentError("batch stamp limit exceeded"))
            stamp!(staged,layer,stroke,target,maximum_new,new_tiles)
            remaining -= 1
        else
            x,y,r = previous
            dx,dy,dr = target .- previous
            subdivisions = max(1.0,ceil(sqrt(dx*dx+dy*dy)/max(0.5,min(r,target[3])/2)))
            subdivisions <= remaining || throw(ArgumentError("batch stamp limit exceeded"))
            steps = Int(subdivisions)
            for step in 1:steps
                fraction = step/steps
                stamp!(staged,layer,stroke,(x+dx*fraction,y+dy*fraction,r+dr*fraction),maximum_new,new_tiles)
            end
            remaining -= steps
        end
        previous = target
    end
    updates = Dict(key => freeze_preview(layer,stroke,key,tile) for (key,tile) in staged)
    visible = length(layer.committed)
    charge = Int128(COMMAND_CHARGE)+Int128(SAMPLE_CHARGE)*(length(stroke.samples)+length(samples))
    for key in union(keys(stroke.tiles),keys(updates))
        before = get(layer.committed,key,nothing)
        current = haskey(updates,key) ? updates[key] : stroke.tiles[key]
        after = current.pixels
        visible += (after !== nothing)-(before !== nothing)
        same_tile(before,after) || (charge += PATCH_CHARGE+tile_bytes(before)+tile_bytes(after))
    end
    visible <= layer.max_tiles || throw(ArgumentError("paint tile limit exceeded"))
    charge <= layer.history_bytes || throw(ArgumentError("stroke checkpoint exceeds history budget"))
    return updates
end

"""Validate and publish one ordered batch under the layer lock, returning touched-tile count."""
function append_batch!(layer::PaintLayer,stroke::ActiveStroke,batch)
    expected = layer.revision
    samples = stage_samples(layer,stroke,batch)
    layer.revision == expected || throw(ArgumentError("paint changed while reading the batch"))
    isempty(samples) && return 0
    revision = next_counter(expected)
    updates = plan_batch(layer,stroke,samples)
    append!(stroke.samples,samples)
    merge!(stroke.tiles,updates)
    layer.revision = revision
    return length(updates)
end

"""
    begin_stroke!(layer, brush, sample) -> UInt64

Start one live preview with `sample` and return its stroke identity. An
existing stroke or an exceeded stroke budget raises `ArgumentError` without
changing the current paint. Counter exhaustion raises `OverflowError`.
"""
function begin_stroke!(layer::PaintLayer,brush::RoundBrush,sample::PointerSample)
    return lock(layer.guard) do
        layer.active === nothing || throw(ArgumentError("finish or cancel the active stroke"))
        id = next_counter(layer.sequence)
        stroke = ActiveStroke(id,brush,PointerSample[],Dict{TileKey,StrokeTile}())
        append_batch!(layer,stroke,(sample,))
        layer.active = stroke
        layer.sequence = id
        return id
    end
end

"""
    append_samples!(layer, id, batch) -> Int

Append an iterable of `PointerSample`s to the matching stroke and return
how many tiles were staged. Equal times retain input order. Invalid IDs,
samples, timestamps, or exceeded work budgets raise `ArgumentError` and
leave earlier paint and input unchanged. Counter exhaustion raises
`OverflowError`. Errors from iterating `batch` propagate. The batch is
rejected if its iterator edits the same layer before it finishes.
"""
function append_samples!(layer::PaintLayer,id::Integer,batch)
    return lock(layer.guard) do
        append_batch!(layer,active_stroke(layer,id),batch)
    end
end

"""Build an undo entry from only the active tiles whose paint has changed."""
function checkpoint(layer::PaintLayer,stroke::ActiveStroke)
    patches = TilePatch[]
    charge = Int128(COMMAND_CHARGE)+Int128(SAMPLE_CHARGE)*length(stroke.samples)
    for (key,tile) in stroke.tiles
        before = get(layer.committed,key,nothing)
        after = tile.pixels
        same_tile(before,after) && continue
        push!(patches,TilePatch(key,before,after))
        charge += PATCH_CHARGE+tile_bytes(before)+tile_bytes(after)
    end
    charge <= layer.history_bytes || throw(ArgumentError("stroke checkpoint exceeds history budget"))
    return StrokeCommand(stroke.id,stroke.brush,stroke.samples,patches,Int(charge))
end

"""Install the requested side of one undo entry, without rerasterizing its samples."""
function restore_tiles!(layer::PaintLayer,command::StrokeCommand,forward::Bool)
    for patch in command.patches
        pixels = forward ? patch.after : patch.before
        if pixels === nothing
            delete!(layer.committed,patch.key)
        else
            layer.committed[patch.key] = pixels
        end
    end
    return nothing
end

"""
    commit_stroke!(layer, id) -> NamedTuple

Commit the live brush preview as one command and clear the active stroke.
Return the command identity, changed-tile count, and IDs evicted or discarded
from redo history. Oldest undo entries are evicted to fit the configured
limits. An invalid identity raises `ArgumentError`. Counter exhaustion raises
`OverflowError` before changing the paint.
"""
function commit_stroke!(layer::PaintLayer,id::Integer)
    return lock(layer.guard) do
        command = checkpoint(layer,active_stroke(layer,id))
        revision = next_counter(layer.revision)
        planned = layer.commands[1:layer.cursor]
        discarded = map(cmd -> cmd.id,layer.commands[layer.cursor+1:end])
        push!(planned,command)
        charge = sum(cmd -> Int128(cmd.charge),planned)
        first_kept = 1
        while length(planned)-first_kept+1 > layer.max_entries || charge > layer.history_bytes
            charge -= planned[first_kept].charge
            first_kept += 1
        end
        evicted = [planned[i].id for i in 1:first_kept-1]
        kept = planned[first_kept:end]
        restore_tiles!(layer,command,true)
        layer.active = nothing
        layer.commands = kept
        layer.cursor = length(kept)
        layer.charged_history = Int(charge)
        layer.revision = revision
        return (; id=command.id,tiles=length(command.patches),evicted,discarded_redo=discarded)
    end
end

"""
    cancel_stroke!(layer, id) -> Nothing

Discard the matching preview and restore the committed appearance. Throw
`ArgumentError` for a stale identity or `OverflowError` on counter exhaustion.
"""
function cancel_stroke!(layer::PaintLayer,id::Integer)
    lock(layer.guard) do
        active_stroke(layer,id)
        layer.revision = next_counter(layer.revision)
        layer.active = nothing
    end
    return nothing
end

"""Move the committed history cursor under the layer lock by one undo or redo."""
function restore_command!(layer::PaintLayer,forward::Bool)
    return lock(layer.guard) do
        layer.active === nothing || throw(ArgumentError("finish or cancel the active stroke"))
        index = layer.cursor+Int(forward)
        1 <= index <= length(layer.commands) || return nothing
        revision = next_counter(layer.revision)
        command = layer.commands[index]
        restore_tiles!(layer,command,forward)
        layer.cursor += forward ? 1 : -1
        layer.revision = revision
        return command.id
    end
end

"""
    undo!(layer) -> Union{UInt64,Nothing}

Restore the previous committed tile checkpoints and return the undone stroke
identity, or `nothing` at the history boundary. An active stroke raises
`ArgumentError` and counter exhaustion raises `OverflowError`.
"""
undo!(layer::PaintLayer) = restore_command!(layer,false)

"""
    redo!(layer) -> Union{UInt64,Nothing}

Restore the next committed tile checkpoints and return their stroke identity,
or `nothing` when no redo is available. An active stroke raises
`ArgumentError` and counter exhaustion raises `OverflowError`.
"""
redo!(layer::PaintLayer) = restore_command!(layer,true)

"""
    paint_revision(layer; preview=true, source_bytes=256*1024^2,
                   max_region_bytes=1024^2) -> ImageTiles.OwnedTileRevision

Capture a sparse immutable raster authority from the committed paint and,
by default, the active preview. The authority owns its tile index and shares
immutable tile bytes. Its metadata uses the layer's full logical extent and
absent tiles are transparent. Publish it in an `ImageTiles.RasterRegistry`
and keep the publication lease while frames need it. Source or staging
budget errors propagate from `ImageTiles`.
"""
function paint_revision(layer::PaintLayer;preview::Bool=true,source_bytes::Integer=256*1024^2,
                        max_region_bytes::Integer=1024^2)
    return lock(layer.guard) do
        chunks = layer.committed
        if preview && layer.active !== nothing
            chunks = copy(chunks)
            for (key,tile) in layer.active.tiles
                if tile.pixels === nothing
                    delete!(chunks,key)
                else
                    chunks[key] = tile.pixels
                end
            end
        end
        ImageTiles.OwnedTileRevision(layer.size...,chunks;tile_size=layer.tile_size,
            revision=layer.revision,source_bytes,max_tiles=layer.max_tiles,max_region_bytes,share_pages=true)
    end
end

"""
    paint_usage(layer) -> NamedTuple

Report the current revision, live stroke ID, active sample and tile counts,
committed tile count, and retained undo/redo and charged history usage. The
history charge covers retained checkpoint bytes and logical metadata.
"""
function paint_usage(layer::PaintLayer)
    return lock(layer.guard) do
        active = layer.active
        (; revision=layer.revision,active=isnothing(active) ? nothing : active.id,
           active_samples=isnothing(active) ? 0 : length(active.samples),
           active_tiles=isnothing(active) ? 0 : length(active.tiles),
           committed_tiles=length(layer.committed),undo=layer.cursor,
           redo=length(layer.commands)-layer.cursor,history_bytes=layer.charged_history)
    end
end

end
