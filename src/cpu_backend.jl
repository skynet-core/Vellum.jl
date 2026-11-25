"""Bounded CPU adapter for portable frames; independent of presentation and timers."""
module CPUBackend

import ..Vetra
using ..Vetra: Frame, PreparedFrame, Transform2D, FillPath, StrokePath, ImageRegion,
    ClearRegion, CompositeGroup, ImageData, RasterReference, Solid, DrawingState, rectangle_path
import ..ImageTiles
import ..ImageStorage
const T=ImageTiles
const S=ImageStorage
using ..PortableGeometry: PreparedGeometry, lower_fill, contains,
    paint_color, inverse_transform

export Renderer, CPUSurface, Cancellation, cancel!, pixels, render_reference, scratch_usage, provider_usage

const RGBA = NTuple{4,Float64}
const TRANSPARENT = (0.0,0.0,0.0,0.0)

mutable struct Cancellation
    requested::Threads.Atomic{Bool}
end
Cancellation() = Cancellation(Threads.Atomic{Bool}(false))
cancel!(token::Cancellation) = (token.requested[]=true; nothing)
const RenderCancelled=Vetra.PortableGeometry.RenderCancelled
check_cancel(token) = token !== nothing && token.requested[] ? throw(RenderCancelled()) : nothing

mutable struct CPUSurface <: Vetra.Surface
    image::Vetra.Image
    valid::Threads.Atomic{Bool}
    guard::ReentrantLock
end
CPUSurface(image::Vetra.Image) = CPUSurface(image,Threads.Atomic{Bool}(true),ReentrantLock())
function pixels(surface::CPUSurface)
    lock(surface.guard) do
        surface.valid[] || throw(ArgumentError("surface invalid after interrupted rendering"))
        copy(surface.image)
    end
end

struct CPUPaint
    color::RGBA
    stops::Vector{Tuple{Float64,RGBA}}
    start::Tuple{Float64,Float64}
    unit::Tuple{Float64,Float64}
    length::Float64
    mapping::Transform2D
end
premultiply(color) = (color.channels[1]*color.channels[4],color.channels[2]*color.channels[4],
    color.channels[3]*color.channels[4],color.channels[4])
function CPUPaint(geometry)
    paint=geometry.paint
    paint isa Solid && return CPUPaint(premultiply(paint.color),Tuple{Float64,RGBA}[],
        (0.0,0.0),(0.0,0.0),1.0,Transform2D())
    axis=(paint.stop[1]-paint.start[1],paint.stop[2]-paint.start[2])
    length=hypot(axis...)
    CPUPaint(TRANSPARENT,[(stop.position,premultiply(stop.color)) for stop in paint.stops],
        paint.start,(axis[1]/length,axis[2]/length),length,geometry.canvas_to_paint)
end
@inline function sample_paint(paint::CPUPaint,point)::RGBA
    isempty(paint.stops) && return paint.color
    q=Vetra.map_point(paint.mapping,point)
    t=clamp(((q[1]-paint.start[1])*paint.unit[1]+(q[2]-paint.start[2])*paint.unit[2])/paint.length,0,1)
    for index in eachindex(paint.stops)
        position,color=paint.stops[index]
        if position>t
            index==1 && return color
            previous,left=paint.stops[index-1]
            weight=(t-previous)/(position-previous)
            return ntuple(i -> left[i]*(1-weight)+color[i]*weight,4)
        end
    end
    last(paint.stops)[2]
end

struct Draw
    geometry::PreparedGeometry
    paint::CPUPaint
    clips::Vector{PreparedGeometry}
    opacity::Float64
    blend::Symbol
    clear::Bool
    image::Union{Nothing,ImageData,RasterReference}
    mapping::Transform2D
    source::NTuple{4,Float64}
    sampling::Symbol
end
struct Group
    children::Vector{Union{Draw,Group}}
    opacity::Float64
    blend::Symbol
    radius::NTuple{2,Int}
end
const Node = Union{Draw,Group}

mutable struct RasterTile
    buffer::S.PixelBuffer
    used::UInt64
end
mutable struct ProviderState
    registry::Union{Nothing,T.AbstractRasterResolver}
    tile_size::Int
    cache_limit::Int
    workspace_limit::Int
    output_limit::Int
    source_limit::Int
    sample_limit::Int
    tiles::Dict{Tuple{RasterReference,Int,Int},RasterTile}
    output::Vector{UInt8}
    colors::Matrix{RGBA}
    execution::Union{Nothing,T.AbstractRevisionLease}
    bindings::Dict{RasterReference,T.AbstractRevisionLease}
    clock::UInt64
    hits::Int
    loads::Int
    evictions::Int
    copied::Int
    source_pixels::Int
    samples::Int
    admitted_source_pixels::Int
    admitted_samples::Int
    peak_cache::Int
    peak_workspace::Int
    peak_output::Int
    active_region_leases::Int
    peak_region_leases::Int
    peak_region_bytes::Int
    peak_conversion_bytes::Int
    committed_output_bytes::Int
    running::Bool
    closed::Bool
end
function ProviderState(registry,tile,cache,workspace,output,source,samples)
    registry===nothing || registry isa T.AbstractRasterResolver || throw(ArgumentError("invalid raster registry"))
    all(x->x isa Integer && 0<x<=typemax(Int),(tile,cache,workspace,output,source,samples)) &&
        tile<=1024 || throw(ArgumentError("provider budgets must be positive and addressable"))
    BigInt(tile)^2*4<=cache || throw(ArgumentError("provider cache must hold one source tile"))
    ProviderState(registry,Int(tile),Int(cache),Int(workspace),Int(output),Int(source),Int(samples),
        Dict{Tuple{RasterReference,Int,Int},RasterTile}(),UInt8[],Matrix{RGBA}(undef,0,0),
        nothing,Dict{RasterReference,T.AbstractRevisionLease}(),0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,false,false)
end

"""One work estimate for the current lowered plan and actual scratch capacities."""
struct WorkCache
    """Region dimensions, tile size, sample axis, and lengths of the estimator's scratch arrays."""
    dimensions::NTuple{7,Int}
    """Whether the reference coverage path is selected."""
    reference::Bool
    """Private arbitrary-width report, never returned directly to callers."""
    report::NamedTuple{(:tiles,:vertices,:contours,:masks,:predicates,:traversal_units,
        :fallback_primitives,:commit_bytes,:reference),
        Tuple{BigInt,BigInt,BigInt,BigInt,BigInt,BigInt,BigInt,BigInt,Bool}}
end

mutable struct Renderer <: Vetra.Backend
    tile_size::Int
    samples::Int
    max_depth::Int
    max_vertices::Int
    max_nodes::Int
    scratch::Vector{Matrix{RGBA}}
    mask::BitMatrix
    clip_mask::BitMatrix
    crossings::Vector{Int}
    guard::ReentrantLock
    cached_frame::Union{Nothing,Frame}
    cached_size::Tuple{Int,Int}
    cached_nodes::Vector{Node}
    horizontal::Matrix{RGBA}
    scratch_budget::Int
    reserved_bytes::Int
    peak_reserved_bytes::Int
    text_cache::Vetra._CapturedTextCache
    text_preparation_bytes::Int
    provider::ProviderState
    orientation::Vector{UInt64}
    work_bound::NamedTuple
    """Latest estimate for the current lowered plan, protected by `guard`."""
    work_cache::Union{Nothing,WorkCache}
end

"""
    scratch_payload(width, height, samples, depth, effect)

Return the scratch byte charge as a `BigInt`. The extent and sampling
are physical. Count all configured pixel layers, both masks, the crossing
row and the shared orientation workspace. Include the horizontal
intermediate when `effect` is true. Callers validate the extent and budget.
"""
function scratch_payload(width,height,samples,depth,effect)
    pixels=BigInt(width)*height
    pixels*32*(depth+1+Int(effect))+
        2*cld(pixels*samples^2,64)*8+BigInt(width)*samples*sizeof(Int)+
        Vetra.PortableGeometry.ORIENTATION_BYTES
end

"""
    scratch_usage(renderer::Renderer)

Return a snapshot of the reserved scratch payload, growth peak and last
admitted work bound. The payload measures array storage and the orientation
allowance. The returned work counters are independent of the renderer's cache.
"""
function scratch_usage(renderer::Renderer)
    lock(renderer.guard) do
        (;reserved_bytes=renderer.reserved_bytes,peak_reserved_bytes=renderer.peak_reserved_bytes,
           budget_bytes=renderer.scratch_budget,extent=size(renderer.scratch[1]),
           layers=length(renderer.scratch),horizontal_extent=size(renderer.horizontal),
           orientation_bytes=renderer.provider.closed ? 0 : Vetra.PortableGeometry.ORIENTATION_BYTES,
           work_bound=deepcopy(renderer.work_bound))
    end
end

function Renderer(;tile_size::Integer=32,samples::Integer=4,max_depth::Integer=8,
                  max_vertices::Integer=1_000_000,max_nodes::Integer=100_000,
                  scratch_bytes::Integer=32*1024*1024,text_cache_bytes::Integer=32*1024*1024,
                  text_preparation_bytes::Integer=128*1024*1024,
                  raster_registry=nothing,provider_tile_size::Integer=32,
                  provider_cache_bytes::Integer=16*1024*1024,
                  provider_workspace_bytes::Integer=8*1024*1024,
                  provider_output_bytes::Integer=64*1024*1024,
                  provider_max_source_pixels::Integer=min(Int128(256)*1024^3,typemax(Int)),
                  provider_max_samples::Integer=128*1024*1024)
    provider=ProviderState(raster_registry,provider_tile_size,provider_cache_bytes,
        provider_workspace_bytes,provider_output_bytes,provider_max_source_pixels,provider_max_samples)
    0 < text_cache_bytes <= typemax(Int) && 0 < text_preparation_bytes <= typemax(Int) ||
        throw(ArgumentError("invalid text cache budget"))
    1 <= tile_size <= 1024 && samples in (1,2,4,8) && 0 <= max_depth <= 64 &&
        0 < max_vertices <= typemax(Int) && 0 < max_nodes <= typemax(Int) &&
        0 < scratch_bytes <= typemax(Int) ||
        throw(ArgumentError("invalid CPU renderer limits"))
    needed=scratch_payload(tile_size,tile_size,samples,max_depth,false)
    needed <= scratch_bytes || throw(ArgumentError("CPU scratch budget exceeded"))
    scratch=[Matrix{RGBA}(undef,tile_size,tile_size) for _ in 0:max_depth]
    Renderer(tile_size,samples,max_depth,max_vertices,max_nodes,scratch,
        falses(tile_size*samples,tile_size*samples),falses(tile_size*samples,tile_size*samples),
        zeros(Int,tile_size*samples),ReentrantLock(),
        nothing,(0,0),Node[],Matrix{RGBA}(undef,0,0),scratch_bytes,Int(needed),Int(needed),
        Vetra._CapturedTextCache(Int(text_cache_bytes)),Int(text_preparation_bytes),provider,
        Vetra.PortableGeometry.orientation_workspace(),(;),nothing)
end

"""Derived text Julia residency, including deferred layouts; excludes native heap."""
function text_cache_usage(renderer::Renderer)
    lock(renderer.guard) do
        cache=renderer.text_cache
        (;bytes=cache.bytes,budget=cache.budget,entries=length(cache.entries),
          hits=cache.hits,misses=cache.misses,evictions=cache.evictions)
    end
end

function clear_text_cache!(renderer::Renderer)
    lock(renderer.guard) do
        foreach(Vetra._releaseTextValue!,values(renderer.text_cache.entries))
        renderer.text_cache=Vetra._CapturedTextCache(renderer.text_cache.budget)
        nothing
    end
end

"""
    cpu_capabilities(with_raster_provider)

Return the supported CPU features and formats. Include external raster
features only when `with_raster_provider` is true.
"""
function cpu_capabilities(with_raster_provider::Bool)
    # Captured glyf outlines need no shaping provider; deferred preflight loads it.
    text = (:text,:text_captured_glyphs_v1,:text_single_face_ascii_v1,
        :text_single_face_unicode_v1,:text_ordered_fallback_v1,:text_features_v1)
    external=with_raster_provider ?
        (:image_provider_revision_v1,Symbol("image_storage.tiled"),:linear_srgb_image) : ()
    Vetra.Capabilities(features=(
        :fill_path,:stroke_path,:image,:clear,:group,:float64,:clip,:curve_paths,
        :gradient,:linear_sampling,:multiply,:effect_box_blur_v1,text...,external...),
        formats=isempty(external) ? (:rgba8,) : (:gray8,:rgb8,:bgr8,:rgba8,:bgra8))
end

"""Return CPU capabilities for the renderer's configured provider profile."""
Vetra.capabilities(renderer::Renderer) = cpu_capabilities(renderer.provider.registry !== nothing)

function Vetra.prepare_retention(renderer::Renderer,frame::Frame)
    lock(renderer.guard) do
        renderer.provider.closed && Vetra.model_error(:resource_unavailable,"CPU renderer is closed")
        any(r->r.payload isa RasterReference,frame.resources) || return nothing
        registry=renderer.provider.registry
        registry===nothing && Vetra.model_error(:resource_unavailable,"CPU renderer has no raster registry")
        T.retain_frame(registry,frame)
    end
end
Vetra.make_surface(::Renderer,size) = CPUSurface(Vetra.newImage(Vetra.checked_dimensions(size...)...))

function physical_radius(radius,pixels,logical)
    isfinite(radius) && radius>=0 && isfinite(logical) && logical>0 && pixels>0 ||
        throw(ArgumentError("box-blur radius and viewport must be finite and nonnegative/positive"))
    # Exact ceiling prevents positive underflow or multiplication rounding from losing support.
    value=Rational{BigInt}(radius)*pixels/Rational{BigInt}(logical)
    support=cld(numerator(value),denominator(value))
    support<=typemax(Int)÷4 ||
        throw(ArgumentError("box-blur radius/scale exceeds addressable CPU support"))
    Int(support)
end
function halo_sum(a,b)
    result=Int128(a)+b
    result<=typemax(Int)÷4 || throw(ArgumentError("nested box-blur support exceeds CPU address limits"))
    Int(result)
end
function nested_support(nodes)
    x=y=0
    for node in nodes
        if node isa Group
            child=nested_support(node.children)
            x=max(x,halo_sum(node.radius[1],child[1]))
            y=max(y,halo_sum(node.radius[2],child[2]))
        end
    end
    (x,y)
end

function reserve_scratch!(renderer,support)
    width=renderer.tile_size+2*support[1]
    height=renderer.tile_size+2*support[2]
    effect=support!=(0,0)
    needed=scratch_payload(width,height,renderer.samples,renderer.max_depth,effect)
    needed<=renderer.scratch_budget ||
        throw(ArgumentError("CPU box-blur halo scratch exceeds scratch_bytes; reduce radius/tile/depth or raise the budget"))
    oldwidth,oldheight=size(renderer.scratch[1])
    if width<=oldwidth && height<=oldheight && (!effect || !isempty(renderer.horizontal))
        return nothing
    end
    peak=renderer.reserved_bytes+needed-Vetra.PortableGeometry.ORIENTATION_BYTES
    peak<=renderer.scratch_budget ||
        throw(ArgumentError("CPU halo scratch growth peak exceeds scratch_bytes; use a fresh renderer or raise the budget"))
    # Allocate transactionally; failed reservations preserve both destination and old cached plan.
    scratch=[Matrix{RGBA}(undef,width,height) for _ in 0:renderer.max_depth]
    horizontal=effect ? Matrix{RGBA}(undef,width,height) : Matrix{RGBA}(undef,0,0)
    mask=falses(width*renderer.samples,height*renderer.samples)
    clip_mask=falses(width*renderer.samples,height*renderer.samples)
    crossings=zeros(Int,width*renderer.samples)
    renderer.scratch=scratch
    renderer.horizontal=horizontal
    renderer.mask=mask
    renderer.clip_mask=clip_mask
    renderer.crossings=crossings
    renderer.reserved_bytes=Int(needed)
    renderer.peak_reserved_bytes=max(renderer.peak_reserved_bytes,Int(peak))
    nothing
end

function lower_nodes(renderer,nodes,frame,viewport,target,depth,counts,preparation)
    depth <= renderer.max_depth || throw(ArgumentError("CPU group depth exceeded"))
    result=Node[]
    for node in nodes
        counts[1]+=1
        counts[1] <= renderer.max_nodes || throw(ArgumentError("CPU node budget exceeded"))
        op=node.operation
        if op isa CompositeGroup
            radius=op.effect===nothing ? (0,0) :
                (physical_radius(op.effect.radius_x,target[1],frame.size[1]),
                 physical_radius(op.effect.radius_y,target[2],frame.size[2]))
            push!(result,Group(lower_nodes(renderer,op.nodes,frame,viewport,target,depth+1,counts,preparation),
                op.opacity,op.blend,radius))
            continue
        end
        if op isa Vetra.TextRun
            path=Vetra._portable_text_path(op,frame,node.id;max_commands=renderer.max_vertices,
                cache=renderer.text_cache,preparation)
            outlined=Vetra.SemanticNode(node.id,node.revision,FillPath(path,op.state,:nonzero))
            append!(result,lower_nodes(renderer,(outlined,),frame,viewport,target,depth,counts,preparation))
            continue
        end
        state=op.state
        op isa ImageRegion && (op.source[3]==0 || op.source[4]==0) && continue
        transform=viewport*state.transform
        # Lowering uses local tolerance; scale it to keep physical curve error bounded.
        a,b,c,d,_,_=transform.coefficients
        scale=max(hypot(a,b)+hypot(c,d),1.0)
        tolerance=1/(256*scale)
        options=(;tolerance,max_vertices=renderer.max_vertices)
        geometry = if op isa FillPath
            lower_fill(op.path,state.fill;transform,winding=op.winding,options...)
        elseif op isa StrokePath
            Vetra.PortableGeometry.lower_stroke(op.path,state.stroke,state.stroke_style;transform,options...)
        else
            rectangle=op isa ImageRegion ? op.destination : op.rectangle
            lower_fill(rectangle_path(rectangle...),Solid(0,0,0);transform,options...)
        end
        if geometry.paint isa Vetra.LinearGradient && geometry.paint.space === :canvas
            geometry=PreparedGeometry(geometry.contours,geometry.winding,geometry.union_pieces,
                geometry.paint,geometry.canvas_to_paint*inverse_transform(viewport),geometry.bounds)
        end
        clips=PreparedGeometry[]
        for clip in state.clips
            counts[1]+=1
            counts[1] <= renderer.max_nodes || throw(ArgumentError("CPU clip budget exceeded"))
            push!(clips,lower_fill(clip.path,Solid(0,0,0);
                transform=viewport*clip.transform,winding=clip.winding,options...))
        end
        counts[1]+=geometry.paint isa Vetra.LinearGradient ? length(geometry.paint.stops) : 0
        counts[1] <= renderer.max_nodes || throw(ArgumentError("CPU paint stop budget exceeded"))
        for item in (geometry,clips...)
            for contour in item.contours
                vertices=length(contour.points)
                vertices <= renderer.max_vertices-counts[2] ||
                    throw(ArgumentError("CPU total vertex budget exceeded"))
                counts[2]+=vertices
            end
        end
        image=op isa ImageRegion ? Vetra.resource(frame,op.image) : nothing
        image === nothing || image isa ImageData ||
            (image isa RasterReference && renderer.provider.registry!==nothing) ||
            throw(Vetra.CapabilityError(node.id,:cpu_image_provider))
        source=op isa ImageRegion ? op.source : (0.0,0.0,0.0,0.0)
        mapping=Transform2D()
        if op isa ImageRegion && op.destination[3]>0 && op.destination[4]>0
            x,y,w,h=op.destination
            sx,sy,sw,sh=source
            mapping=Transform2D(sw/w,0,0,sh/h,sx-x*sw/w,sy-y*sh/h)*inverse_transform(transform)
        end
        push!(result,Draw(geometry,CPUPaint(geometry),clips,state.opacity,state.blend,op isa ClearRegion,
            image,mapping,source,state.sampling))
    end
    result
end

function cpu_plan(renderer,plan,size)
    plan.backend === renderer || throw(ArgumentError("prepared frame belongs to another renderer"))
    if renderer.cached_frame !== plan.frame || renderer.cached_size != size
        width,height=plan.frame.size
        isfinite(width) && isfinite(height) && width>0 && height>0 ||
            throw(ArgumentError("CPU logical viewport must be finite and positive"))
        viewport=Transform2D(size[1]/width,0,0,size[2]/height)
        preparation=Vetra._TextPreparation(renderer.text_preparation_bytes)
        nodes=lower_nodes(renderer,plan.frame.nodes,plan.frame,viewport,size,0,[0,0],preparation)
        reserve_scratch!(renderer,nested_support(nodes))
        renderer.work_cache=nothing
        renderer.cached_nodes=nodes
        renderer.cached_frame=plan.frame
        renderer.cached_size=size
    end
    renderer.cached_nodes
end

# Preflight arithmetic is arbitrary-width; execution never increments a wrapping work counter.
function coverage_work_bound(renderer,nodes,w,h,reference)
    vertices=BigInt(0); contours=BigInt(0); masks=BigInt(0); groups=BigInt(0)
    function count_nodes(items)
        for node in items
            if node isa Group
                groups+=1
                count_nodes(node.children)
            else
                for geometry in (node.geometry,node.clips...)
                    masks+=1
                    contours+=length(geometry.contours)
                    vertices+=sum(c->BigInt(length(c.points)),geometry.contours;init=BigInt(0))
                end
            end
        end
    end
    count_nodes(nodes)
    hx,hy=nested_support(nodes)
    columns=(BigInt(renderer.tile_size)+2hx)*renderer.samples
    rows=(BigInt(renderer.tile_size)+2hy)*renderer.samples
    tiles=cld(BigInt(w),renderer.tile_size)*cld(BigInt(h),renderer.tile_size)
    search=ndigits(columns;base=2) # ceil(log2(columns+1))
    predicates=reference ? 2rows*columns*vertices : rows*vertices*search
    # Include inactive edges, empty contours, bin updates, row clears,
    # clip intersections and span writes. The fill estimate keeps
    # the conservative allowance for a separate prefix per contour.
    traversals=reference ? 2rows*columns*(vertices+contours+masks) :
        rows*(vertices*(search+4)+contours+
              8columns*(contours+masks)+2BigInt(length(renderer.crossings))*masks)+
        2BigInt(length(renderer.mask))*masks
    traversals+=BigInt(length(renderer.scratch[1]))*(groups+1)
    (;tiles,vertices,contours,masks,
      predicates=tiles*predicates,traversal_units=tiles*traversals,
      fallback_primitives=tiles*predicates*Vetra.PortableGeometry.ORIENTATION_PRIMITIVE_BOUND,
      commit_bytes=BigInt(4)*w*h,reference)
end

"""
    coverage_work_candidate(renderer, nodes, w, h, reference)

Return the current plan's work estimate, or compute a new candidate when
the estimator's inputs differ. The caller holds the renderer lock and
passes its current prepared nodes. Retain the candidate after admission.
"""
function coverage_work_candidate(renderer,nodes,w::Int,h::Int,reference::Bool)
    dimensions=(w,h,renderer.tile_size,renderer.samples,length(renderer.crossings),
        length(renderer.mask),length(renderer.scratch[1]))
    cache=renderer.work_cache
    if cache !== nothing && cache.dimensions==dimensions && cache.reference==reference
        return cache
    end
    report=coverage_work_bound(renderer,nodes,w,h,reference)
    WorkCache(dimensions,reference,report)
end

@inline function composite(dst::RGBA,src::RGBA,blend)
    alpha=src[4]+dst[4]*(1-src[4])
    blend === :source_over && return (
        src[1]+dst[1]*(1-src[4]),src[2]+dst[2]*(1-src[4]),
        src[3]+dst[3]*(1-src[4]),alpha)
    return ntuple(i -> i==4 ? alpha :
        src[i]*(1-dst[4])+dst[i]*(1-src[4])+src[i]*dst[i],4)
end

@inline function image_pixel(image,x,y,source)
    sx,sy,sw,sh=source
    # Clamp the filter footprint to the declared source region, not adjacent atlas pixels.
    x=clamp(x,max(0,floor(Int,sx)),min(image.width-1,ceil(Int,sx+sw)-1))
    y=clamp(y,max(0,floor(Int,sy)),min(image.height-1,ceil(Int,sy+sh)-1))
    offset=y*image.row_stride+4*x
    ntuple(c -> image.pixels[offset+c]/255,4)
end
function sample_image(draw,point)::RGBA
    x,y=Vetra.map_point(draw.mapping,point)
    if draw.sampling === :nearest
        return image_pixel(draw.image,floor(Int,x),floor(Int,y),draw.source)
    end
    x-=0.5; y-=0.5
    ix,iy=floor(Int,x),floor(Int,y)
    wx,wy=x-ix,y-iy
    a=image_pixel(draw.image,ix,iy,draw.source)
    b=image_pixel(draw.image,ix+1,iy,draw.source)
    c=image_pixel(draw.image,ix,iy+1,draw.source)
    d=image_pixel(draw.image,ix+1,iy+1,draw.source)
    ntuple(i -> (a[i]*(1-wx)+b[i]*wx)*(1-wy)+(c[i]*(1-wx)+d[i]*wx)*wy,4)
end

function clear_provider_cache!(renderer::Renderer)
    lock(renderer.guard) do
        p=renderer.provider
        p.running && Vetra.model_error(:invalid_state,"cannot clear a CPU cache from an execution callback")
        foreach(t->close(t.buffer),values(p.tiles))
        empty!(p.tiles)
    end
    nothing
end
"""Separate payload reservations/work/copy traffic; not aggregate Julia/native RSS."""
function provider_usage(renderer::Renderer)
    lock(renderer.guard) do
        p=renderer.provider
        (;cache_bytes=length(p.tiles)*p.tile_size^2*4,cache_entries=length(p.tiles),
          resident_cache_bytes=sum(t->S.descriptor_extent(t.buffer.descriptor),values(p.tiles);init=0),
          peak_cache_bytes=p.peak_cache,cache_limit=p.cache_limit,
          output_bytes=length(p.output),peak_output_bytes=p.peak_output,output_limit=p.output_limit,
          color_bytes=length(p.colors)*32,peak_workspace_bytes=p.peak_workspace,
          workspace_limit=p.workspace_limit,source_pixels=p.source_pixels,samples=p.samples,
          admitted_source_pixels=p.admitted_source_pixels,admitted_samples=p.admitted_samples,
          source_limit=p.source_limit,sample_limit=p.sample_limit,
          hits=p.hits,loads=p.loads,evictions=p.evictions,copied_bytes=p.copied,
          active_region_leases=p.active_region_leases,peak_region_leases=p.peak_region_leases,
          peak_region_bytes=p.peak_region_bytes,peak_conversion_bytes=p.peak_conversion_bytes,
          source_staging_reservation=p.admitted_samples>0 ? p.tile_size^2*12 : 0,
          committed_output_bytes=p.committed_output_bytes,
          active_bindings=length(p.bindings),execution_active=p.execution!==nothing,running=p.running,closed=p.closed)
    end
end
function Base.close(renderer::Renderer)
    lock(renderer.guard) do
        renderer.provider.closed && return nothing
        renderer.provider.running && Vetra.model_error(:invalid_state,"cannot close a CPU renderer from an execution callback")
        renderer.provider.closed=true
        clear_provider_cache!(renderer)
        renderer.provider.output=UInt8[]
        renderer.provider.colors=Matrix{RGBA}(undef,0,0)
        renderer.orientation=UInt64[]
        renderer.reserved_bytes-=Vetra.PortableGeometry.ORIENTATION_BYTES
        renderer.work_bound=(;)
        renderer.work_cache=nothing
        renderer.cached_frame=nothing
        empty!(renderer.cached_nodes)
        clear_text_cache!(renderer)
    end
    nothing
end
function begin_provider_execution!(renderer,plan)
    p=renderer.provider
    p.closed && Vetra.model_error(:resource_unavailable,"CPU renderer is closed")
    plan.backend===renderer || throw(ArgumentError("prepared frame belongs to another renderer"))
    external=any(r->r.payload isa RasterReference,plan.frame.resources)
    if external
        plan.retention isa T.AbstractRevisionLease && T.revision_resolver(plan.retention)===p.registry ||
            Vetra.model_error(:invalid_input,"CPU provider plan lacks its registry retention")
    else
        plan.retention===nothing || Vetra.model_error(:invalid_input,"unexpected CPU plan retention")
        return false
    end
    # This admission linearizes with plan close before geometry-cache access.
    p.execution=Vetra.execution_retention(plan)
    for record in plan.frame.resources
        d=record.payload
        d isa RasterReference || continue
        if !haskey(p.bindings,d)
            lease=T.acquire_revision(p.execution,d)
            try
                p.bindings[d]=lease
            catch
                close(lease)
                rethrow()
            end
        end
    end
    true
end
function end_provider_execution!(p)
    failures=Any[]
    for lease in values(p.bindings)
        try close(lease) catch error;push!(failures,error) end
    end
    empty!(p.bindings)
    execution=p.execution
    p.execution=nothing
    if execution!==nothing
        try close(execution) catch error;push!(failures,error) end
    end
    isempty(failures) || throw(CompositeException(failures))
    nothing
end
function provider_samples_bound(nodes,w,h,samples)
    total=BigInt(0)
    for node in nodes
        if node isa Group
            total+=provider_samples_bound(node.children,w+2*node.radius[1],h+2*node.radius[2],samples)
        elseif node.image isa RasterReference
            total+=BigInt(w)*h*samples^2
        end
    end
    total
end
function reserve_provider!(renderer,nodes,w,h)
    p=renderer.provider
    # Cover every output tile's expanded group support, including edge tiles conservatively.
    support=nested_support(nodes)
    tw,th=renderer.tile_size+2*support[1],renderer.tile_size+2*support[2]
    tiles=BigInt(cld(w,renderer.tile_size))*cld(h,renderer.tile_size)
    samples=tiles*provider_samples_bound(nodes,renderer.tile_size,renderer.tile_size,renderer.samples)
    source=samples*4*p.tile_size^2
    samples<=p.sample_limit && source<=p.source_limit ||
        Vetra.model_error(:resource_limit,"CPU provider sample/source work reservation exceeded")
    output=BigInt(w)*h*4
    output<=p.output_limit || Vetra.model_error(:resource_limit,"CPU provider output budget exceeded")
    output_growth=output>length(p.output)
    output_peak=output_growth ? output+length(p.output) : BigInt(length(p.output))
    output_peak<=p.output_limit || Vetra.model_error(:resource_limit,"CPU provider output growth exceeds budget")
    cw,ch=tw*renderer.samples,th*renderer.samples
    color_growth=samples>0 && (cw>size(p.colors,1) || ch>size(p.colors,2))
    colors=BigInt(cw)*ch*32
    temporary=samples>0 ? BigInt(p.tile_size)^2*12 : BigInt(0)
    workspace=(color_growth ? colors+length(p.colors)*32 : BigInt(length(p.colors))*32)+temporary
    workspace<=p.workspace_limit || Vetra.model_error(:resource_limit,"CPU provider workspace/growth budget exceeded")
    new_output=output_growth ? Vector{UInt8}(undef,Int(output)) : p.output
    new_colors=color_growth ? Matrix{RGBA}(undef,cw,ch) : p.colors
    p.output=new_output
    p.colors=new_colors
    p.peak_output=max(p.peak_output,Int(output_peak))
    p.peak_workspace=max(p.peak_workspace,Int(workspace))
    p.admitted_samples=Int(samples);p.admitted_source_pixels=Int(source)
    p.source_pixels=0;p.samples=0
    nothing
end
function checked_source_floor(value)
    isfinite(value) && typemin(Int)<value<typemax(Int) ||
        throw(ArgumentError("mapped raster coordinate is not addressable"))
    floor(Int,value)
end
function provider_pixel!(renderer,d,x,y,source,token)::RGBA
    p=renderer.provider
    m=d.metadata
    sx,sy,sw,sh=source
    lx=sx<=0 ? 0 : checked_source_floor(sx)
    ly=sy<=0 ? 0 : checked_source_floor(sy)
    hx=sx+sw>=m.width ? Int(m.width-1) : ceil(Int,sx+sw)-1
    hy=sy+sh>=m.height ? Int(m.height-1) : ceil(Int,sy+sh)-1
    x=clamp(x,lx,hx);y=clamp(y,ly,hy)
    t=p.tile_size
    tx,ty=div(x,t)*t,div(y,t)*t
    key=(d,tx,ty)
    p.clock=Base.checked_add(p.clock,UInt64(1))
    tile=get(p.tiles,key,nothing)
    if tile===nothing
        check_cancel(token)
        width,height=min(t,Int(m.width)-tx),min(t,Int(m.height)-ty)
        pixels=width*height
        pixels<=p.source_limit-p.source_pixels ||
            Vetra.model_error(:resource_limit,"CPU provider source work exhausted")
        p.source_pixels+=pixels
        capacity=div(p.cache_limit,t*t*4)
        if length(p.tiles)==capacity
            oldest=first(keys(p.tiles))
            for (candidate,value) in p.tiles
                value.used<p.tiles[oldest].used && (oldest=candidate)
            end
            close(pop!(p.tiles,oldest).buffer)
            p.evictions=Base.checked_add(p.evictions,1)
        end
        # Region/source read-close finishes inside the retained revision adapter.
        raw=S.borrow_pixels(p.bindings[d],(tx,ty,width,height);copy_policy=:allow,
                            budget_bytes=t*t*12,cancelled=()->(check_cancel(token);false))
        p.active_region_leases+=1
        p.peak_region_leases=max(p.peak_region_leases,p.active_region_leases)
        native_bytes=S.descriptor_extent(raw.buffer.descriptor)
        p.peak_region_bytes=max(p.peak_region_bytes,native_bytes)
        p.peak_conversion_bytes=max(p.peak_conversion_bytes,native_bytes+pixels*4)
        converted=nothing
        try
            converted=S.convert_buffer(raw.buffer;format=:rgba8,alpha=:premultiplied,
                                       color_space=:srgb,budget_bytes=t*t*4)
            p.copied=Base.checked_add(p.copied,Base.checked_add(raw.report.copied_bytes,converted.report.copied_bytes))
            check_cancel(token)
            tile=RasterTile(converted.buffer,p.clock)
            p.tiles[key]=tile
            converted=nothing
            p.loads=Base.checked_add(p.loads,1)
            p.peak_cache=max(p.peak_cache,length(p.tiles)*t*t*4)
        finally
            converted===nothing || close(converted.buffer)
            try close(raw) finally p.active_region_leases-=1 end
        end
    else
        p.hits=Base.checked_add(p.hits,1)
    end
    tile.used=p.clock
    buffer=tile.buffer
    offset=4*((y-ty)*buffer.descriptor.metadata.width+x-tx)
    bytes=buffer.owner.bytes::Vector{UInt8}
    ntuple(c->bytes[offset+c]/255,4)
end
function provider_color!(renderer,draw,point,token)::RGBA
    p=renderer.provider
    p.samples<p.sample_limit || Vetra.model_error(:resource_limit,"CPU provider sample work exhausted")
    p.samples+=1
    x,y=Vetra.map_point(draw.mapping,point)
    if draw.sampling===:nearest
        return provider_pixel!(renderer,draw.image,checked_source_floor(x),checked_source_floor(y),draw.source,token)
    end
    x-=0.5;y-=0.5
    ix,iy=checked_source_floor(x),checked_source_floor(y)
    wx,wy=x-ix,y-iy
    a=provider_pixel!(renderer,draw.image,ix,iy,draw.source,token)
    b=provider_pixel!(renderer,draw.image,ix+1,iy,draw.source,token)
    c=provider_pixel!(renderer,draw.image,ix,iy+1,draw.source,token)
    d=provider_pixel!(renderer,draw.image,ix+1,iy+1,draw.source,token)
    ntuple(i->(a[i]*(1-wx)+b[i]*wx)*(1-wy)+(c[i]*(1-wx)+d[i]*wx)*wy,4)
end
# Scale the exact integer numerator by a power of two after one Float64 rounding.
@inline function sample_coordinate(origin,index,samples)
    pixel,subsample=divrem(index-1,samples)
    numerator=(Int128(origin)+pixel)*(2*Int128(samples))+2*Int128(subsample)+1
    Float64(numerator)/(2*samples)
end
function covered_sample(draw,point,workspace,token)
    contains(draw.geometry,point,workspace,token) || return false
    for clip in draw.clips
        contains(clip,point,workspace,token) || return false
    end
    true
end
function provider_colors!(renderer,draw,x0,y0,w,h,reference,token)
    samples=renderer.samples
    for row in 1:h*samples
        check_cancel(token)
        for column in 1:w*samples
            (column-1)%256==0 && check_cancel(token)
            point=(sample_coordinate(x0,column,samples),sample_coordinate(y0,row,samples))
            covered=reference ? covered_sample(draw,point,renderer.orientation,token) :
                renderer.mask[column,row]
            covered || continue
            renderer.provider.colors[column,row]=provider_color!(renderer,draw,point,token)
        end
    end
    nothing
end

function crossing_column(a,b,y,x0,samples,columns,workspace=nothing,token=nothing)
    lo,hi=1,columns+1
    upward=b[2]>a[2]
    while lo<hi
        check_cancel(token)
        middle=lo+(hi-lo)÷2
        x=sample_coordinate(x0,middle,samples)
        side=Vetra.PortableGeometry.orientation_sign(a,b,(x,y),workspace,token)
        if upward ? side<=0 : side>=0
            hi=middle
        else
            lo=middle+1
        end
    end
    lo
end

function clear_mask!(mask,token)
    for i in eachindex(mask.chunks)
        (i-1)%4==0 && check_cancel(token)
        mask.chunks[i]=0
    end
end
function clear_pixels!(pixels,token)
    for i in eachindex(pixels)
        (i-1)%256==0 && check_cancel(token)
        pixels[i]=TRANSPARENT
    end
end
"""
    clear_columns!(bins, columns, token)

Clear the first `columns` entries. The caller admits this range against the
row capacity. Check cancellation every 256 writes and propagate
`RenderCancelled`; a later mask row clears its own active range again.
"""
function clear_columns!(bins,columns,token)
    for column in 1:columns
        (column-1)%256==0 && check_cancel(token)
        bins[column]=0
    end
end
"""
    sweep_crossings!(bins, mask, row, columns, rule, union_pieces, token)

Consume the signed crossing deltas for the active row. Replace the covered
samples using the fill rule, or OR the coverage of one union piece into
the mask. Check cancellation every 128 columns. The caller resets active
bins before retrying a cancelled row.
"""
function sweep_crossings!(bins,mask,row,columns,rule,union_pieces,token)
    winding=0
    for column in 1:columns
        (column-1)%128==0 && check_cancel(token)
        winding+=bins[column]
        bins[column]=0
        if union_pieces
            mask[column,row] |= winding!=0
        else
            mask[column,row]=rule === :nonzero ? winding!=0 : isodd(winding)
        end
    end
    return nothing
end
"""
    raster_mask!(renderer, mask, geometry, x0, y0, w, h, token=nothing)

Fill the reusable sample mask for the integer pixel tile at `(x0, y0)`.
Use half-open contour crossings and the geometry's winding or union rule.
The caller owns the renderer and admits an extent that fits its scratch.
Cancellation and predicate failures propagate. Each new row clears the
active crossing bins before use.
"""
function raster_mask!(renderer,mask,geometry,x0,y0,w,h,token=nothing)
    check_cancel(token)
    clear_mask!(mask,token)
    samples=renderer.samples
    for row in 1:h*samples
        check_cancel(token)
        y=sample_coordinate(y0,row,samples)
        columns=w*samples
        clear_columns!(renderer.crossings,columns,token)
        for contour in geometry.contours
            check_cancel(token)
            points=contour.points
            for i in eachindex(points)
                (i-1)%256==0 && check_cancel(token)
                a=points[i]; b=points[mod1(i+1,length(points))]
                if min(a[2],b[2])<=y<max(a[2],b[2])
                    column=crossing_column(a,b,y,x0,samples,columns,renderer.orientation,token)
                    if column<=columns
                        renderer.crossings[column]+=b[2]>a[2] ? 1 : -1
                    end
                end
            end
            # Union pieces must retain independent winding, even when opposite.
            geometry.union_pieces && sweep_crossings!(renderer.crossings,mask,row,columns,
                geometry.winding,true,token)
        end
        if !geometry.union_pieces
            # Signed bins and their prefix are bounded by the admitted segment count.
            sweep_crossings!(renderer.crossings,mask,row,columns,geometry.winding,false,token)
        end
    end
    nothing
end

reference_color(geometry,point)::RGBA = paint_color(geometry,point)

function source_pixel(draw,x,y,samples,reference,mask,mx,my,colors=nothing,workspace=nothing,token=nothing)
    check_cancel(token)
    if draw.image === nothing && isempty(draw.paint.stops)
        hits=0
        if reference
            # The predicate oracle owns coverage. Use the same normalization for
            # constant paint so repeated floating-point sums cannot shift a byte tie.
            for sy in 1:samples,sx in 1:samples
                point=(sample_coordinate(x,sx,samples),sample_coordinate(y,sy,samples))
                hits+=covered_sample(draw,point,workspace,token)
            end
        else
            for sy in 1:samples,sx in 1:samples
                hits+=mask[mx+sx,my+sy]
            end
        end
        coverage=hits/(samples*samples)
        factor=coverage*draw.opacity
        color=draw.paint.color
        return (color[1]*factor,color[2]*factor,color[3]*factor,color[4]*factor),coverage
    end
    r=g=b=a=0.0
    hits=0
    for sy in 1:samples, sx in 1:samples
        point=(sample_coordinate(x,sx,samples),sample_coordinate(y,sy,samples))
        if reference
            covered_sample(draw,point,workspace,token) || continue
        else
            mask[mx+sx,my+sy] || continue
        end
        hits+=1
        if !draw.clear
            color=(draw.image isa RasterReference ? colors[mx+sx,my+sy] :
                draw.image !== nothing ? sample_image(draw,point) :
                reference ? reference_color(draw.geometry,point) : sample_paint(draw.paint,point))::RGBA
            r+=color[1];g+=color[2];b+=color[3];a+=color[4]
        end
    end
    factor=draw.opacity/(samples*samples)
    return (r*factor,g*factor,b*factor,a*factor),hits/(samples*samples)
end

"""
    blur_group!(renderer, target, child, node, w, h, token)

Filter the isolated group in `child` and composite its `w × h` physical
interior into `target`. The lowered plan reserves distinct scratch
layers, including the child's horizontal and vertical halo and the
reusable horizontal sums. The caller holds the renderer lock and supplies
the admitted extent. Sum each window in order, normalize once, and apply
the group's opacity and blend. Check cancellation before each row and
propagate `RenderCancelled`. Return `nothing`.
"""
function blur_group!(renderer, target, child, node, w, h, token)
    rx, ry = node.radius
    horizontal = renderer.horizontal
    # Scratch from the lowered plan includes every offset of both passes.
    # Fixed window order keeps tile and region results identical.
    for y in 1:(h + 2*ry)
        check_cancel(token)
        @inbounds for x in 1:w
            r = g = b = a = 0.0
            for offset in 0:(2*rx)
                color = child[x + offset, y]
                r += color[1]
                g += color[2]
                b += color[3]
                a += color[4]
            end
            horizontal[x, y] = (r, g, b, a)
        end
    end
    normalization = Float64(2*rx + 1) * Float64(2*ry + 1)
    for y in 1:h
        check_cancel(token)
        @inbounds for x in 1:w
            r = g = b = a = 0.0
            for offset in 0:(2*ry)
                color = horizontal[x, y + offset]
                r += color[1]
                g += color[2]
                b += color[3]
                a += color[4]
            end
            source = (r/normalization*node.opacity, g/normalization*node.opacity,
                      b/normalization*node.opacity, a/normalization*node.opacity)
            target[x, y] = composite(target[x, y], source, node.blend)
        end
    end
    return nothing
end

function draw_tile!(renderer,nodes,x0,y0,w,h,depth,token,reference)
    target=renderer.scratch[depth+1]
    for node in nodes
        check_cancel(token)
        if node isa Group
            child=renderer.scratch[depth+2]
            clear_pixels!(child,token)
            rx,ry=node.radius
            draw_tile!(renderer,node.children,x0-rx,y0-ry,w+2*rx,h+2*ry,depth+1,token,reference)
            if node.radius==(0,0)
                for y in 1:h,x in 1:w
                    ((y-1)*w+x-1)%256==0 && check_cancel(token)
                    src=ntuple(i -> child[x,y][i]*node.opacity,4)
                    target[x,y]=composite(target[x,y],src,node.blend)
                end
            else
                blur_group!(renderer,target,child,node,w,h,token)
            end
        else
            bounds=node.geometry.bounds
            if !reference && (bounds === nothing ||
                bounds[3]<sample_coordinate(x0,1,renderer.samples) ||
                bounds[4]<sample_coordinate(y0,1,renderer.samples) ||
                bounds[1]>sample_coordinate(x0,w*renderer.samples,renderer.samples) ||
                bounds[2]>sample_coordinate(y0,h*renderer.samples,renderer.samples))
                continue
            end
            if !reference
                raster_mask!(renderer,renderer.mask,node.geometry,x0,y0,w,h,token)
                for clip in node.clips
                    raster_mask!(renderer,renderer.clip_mask,clip,x0,y0,w,h,token)
                    for i in eachindex(renderer.mask.chunks)
                        (i-1)%4==0 && check_cancel(token)
                        renderer.mask.chunks[i]&=renderer.clip_mask.chunks[i]
                    end
                end
            end
            node.image isa RasterReference && provider_colors!(renderer,node,x0,y0,w,h,reference,token)
            for y in 1:h
                check_cancel(token)
                for x in 1:w
                    (x-1)%256==0 && check_cancel(token)
                    src,coverage=source_pixel(node,Int128(x0)+x-1,Int128(y0)+y-1,renderer.samples,reference,
                         renderer.mask,(x-1)*renderer.samples,(y-1)*renderer.samples,
                         renderer.provider.colors,renderer.orientation,token)
                    target[x,y]=node.clear ?
                        ntuple(i -> target[x,y][i]*(1-coverage),4) :
                        composite(target[x,y],src,node.blend)
                end
            end
        end
    end
    nothing
end

"""
    draw_region!(renderer, nodes, x0, y0, w, h, destination, stride, ox, oy, token, reference)

Draw prepared `nodes` on the global pixel grid in the zero-based rectangle
`(x0, y0, w, h)`. Store premultiplied RGBA8 in `destination`, whose first
pixel is at `(ox, oy)` and whose row `stride` is in pixels.
The caller owns the renderer and validates the destination bounds and scratch
capacity. Drawing and cancellation errors propagate. Return `nothing`.
"""
function draw_region!(renderer, nodes, x0, y0, w, h, destination, stride, ox, oy, token, reference)
    for ty in y0:renderer.tile_size:y0+h-1,tx in x0:renderer.tile_size:x0+w-1
        check_cancel(token)
        tw=min(renderer.tile_size,x0+w-tx); th=min(renderer.tile_size,y0+h-ty)
        clear_pixels!(renderer.scratch[1],token)
        draw_tile!(renderer,nodes,tx,ty,tw,th,0,token,reference)
        check_cancel(token)
        dx,dy=tx-ox,ty-oy
        for y in 1:th,x in 1:tw
            ((y-1)*tw+x-1)%64==0 && check_cancel(token)
            color=renderer.scratch[1][x,y]
            offset=4*((dy+y-1)*stride+dx+x-1)
            for c in 1:4
                destination[offset+c]=round(UInt8,255*clamp(color[c],0,1))
            end
        end
    end
    return nothing
end

"""Blocking execution; external raster work commits only after full-request private completion."""
function Vetra.execute!(renderer::Renderer,surface::CPUSurface,plan::PreparedFrame;
                        region=nothing,cancellation=nothing,reference::Bool=false)
    lock(renderer.guard) do
        p=renderer.provider
        p.running && Vetra.model_error(:invalid_state,"reentrant CPU execution")
        p.running=true
        try
          lock(surface.guard) do
            image=surface.image
            size=(Int(image.width),Int(image.height))
            external=false
            try
                external=begin_provider_execution!(renderer,plan)
                if external
                    length(image.data)==BigInt(size[1])*size[2]*4 ||
                        throw(ArgumentError("provider destination storage extent is invalid"))
                    image.data===renderer.provider.output &&
                        throw(ArgumentError("destination aliases private provider output"))
                end
                nodes=cpu_plan(renderer,plan,size)
                region === nothing || (region isa Tuple && length(region)==4) ||
                    throw(ArgumentError("render region must be a four-element tuple"))
                x0,y0,w,h=region === nothing ? (0,0,size...) : region
                all(v -> v isa Integer,(x0,y0,w,h)) && x0>=0 && y0>=0 && w>0 && h>0 &&
                    Int128(x0)+w<=size[1] && Int128(y0)+h<=size[2] ||
                    throw(ArgumentError("render region exceeds surface"))
                x0,y0,w,h=Int(x0),Int(y0),Int(w),Int(h)
                region === nothing || surface.valid[] ||
                    throw(ArgumentError("invalid surface requires a full rerender"))
                work=coverage_work_candidate(renderer,nodes,w,h,reference)
                check_cancel(cancellation)
                external ? reserve_provider!(renderer,nodes,w,h) : (surface.valid[]=false)
                renderer.work_cache=work
                renderer.work_bound=work.report
                destination=external ? p.output : image.data
                stride=external ? w : size[1]
                ox,oy=external ? (x0,y0) : (0,0)
                draw_region!(renderer,nodes,x0,y0,w,h,destination,stride,ox,oy,cancellation,reference)
                if external
                    committed=Base.checked_add(renderer.provider.committed_output_bytes,4*w*h)
                    end_provider_execution!(renderer.provider)
                    check_cancel(cancellation)
                    surface.valid[]=false
                    commit_provider!(image.data,renderer.provider.output,size[1],Int(x0),Int(y0),Int(w),Int(h))
                    renderer.provider.committed_output_bytes=committed
                end
                surface.valid[]=true
                surface
            finally
                p=renderer.provider
                (p.execution!==nothing || !isempty(p.bindings)) && end_provider_execution!(p)
            end
          end
        finally
            p.running=false
        end
    end
end

"""
    commit_provider!(destination, output, stride, x0, y0, w, h)

Copy a packed `w` by `h` rectangle of four-byte pixels into `destination`
at the zero-based pixel offset `(x0, y0)`. The destination `stride` is
measured in pixels. The synchronous commit returns `nothing`.

The caller validates the input length and destination bounds and ensures the
buffers are disjoint. This private method uses unchecked indexing.
"""
function commit_provider!(destination,output,stride,x0,y0,w,h)
    row_bytes=4*w
    @inbounds for row in 0:h-1
        copyto!(destination,4*((y0+row)*stride+x0)+1,output,row*row_bytes+1,row_bytes)
    end
    nothing
end

function render_reference(frame::Frame;size=frame.size,kwargs...)
    renderer=Renderer(;kwargs...)
    plan=nothing
    try
        plan=Vetra.prepare(renderer,frame)
        surface=Vetra.make_surface(renderer,size)
        Vetra.execute!(renderer,surface,plan;reference=true)
    finally
        try
            plan===nothing || close(plan)
        finally
            close(renderer)
        end
    end
end

end
