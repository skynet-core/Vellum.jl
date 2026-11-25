"""
    DesktopBackend(; device=:auto, raster_registry=nothing)

Render paths and isolated groups on the OpenGL device of the current X11
display. Each surface owns an offscreen GLX drawable and context. Device
selection and graphics library loading take place when the surface is opened.
Supply an image revision resolver to stream immutable tiled sources.
"""
struct DesktopBackend <: Vellum.Backend
    device::Union{Symbol,Tuple{UInt16,UInt16}}
    raster_registry::Union{Nothing,Vellum.ImageTiles.AbstractRasterResolver}
    function DesktopBackend(;device=:auto,raster_registry=nothing)
        device isa Symbol && device in (:auto,:amd,:intel,:nvidia) && return new(device,raster_registry)
        if device isa Tuple && length(device)==2 &&
           all(x -> x isa Integer && !(x isa Bool) && 0 < x <= typemax(UInt16), device)
            return new((UInt16(device[1]),UInt16(device[2])),raster_registry)
        end
        throw(ArgumentError("invalid OpenGL device selector $device"))
    end
end

"""Offscreen OpenGL target. Its native context and pixel storage belong to its creating thread."""
struct DesktopSurface{S} <: Vellum.Surface
    backend::DesktopBackend
    native::S
end

"""
    DesktopSubmission <: Submission

An OpenGL draw pending publication on its owning thread. The frame and its
input textures become current together when `wait` or `completed` observes the fence.
"""
mutable struct DesktopSubmission{T,P} <: Vellum.Submission
    target::T
    candidate::P
    state::Symbol
end

"""Load the first-party GLX implementation at the first native request."""
function glx_extension()
    (Sys.islinux() || Sys.isfreebsd()) || throw(ArgumentError("this desktop OpenGL provider requires GLX"))
    Vellum._require_provider(Base.PkgId(Base.UUID("d59498f3-381e-4841-a765-4609d464ae1b"),"Skia"))
    Vellum._require_provider(Base.PkgId(Base.UUID("4f6342f7-b3d2-589e-9d20-edeb45f2b2bc"),"Xorg_libX11_jll"))
    ext = Base.get_extension(Vellum,:VellumGLXExt)
    isnothing(ext) && error("Vellum's desktop OpenGL extension failed to load")
    return ext
end

"""Report the operations supported by the GLX path renderer."""
function Vellum.capabilities(backend::DesktopBackend)
    features = (:fill_path,:stroke_path,:path_precision_1_256px,:curve_paths,:clip,:group,:gradient,
                :image,:linear_sampling,:float64,:text,:text_captured_glyphs_v1)
    isnothing(backend.raster_registry) && return Vellum.Capabilities(;features)
    return Vellum.Capabilities(features=(features...,:image_provider_revision_v1,Symbol("image_storage.tiled"),:linear_srgb_image),
                               formats=RasterPages.PAGE_FORMATS,max_image_size=(RasterPages.SOURCE_SIDE,RasterPages.SOURCE_SIDE))
end

"""Pin each tiled source revision for the lifetime of a prepared desktop draw."""
function Vellum.prepare_retention(backend::DesktopBackend,frame::Vellum.Frame)
    any(r->r.payload isa Vellum.RasterReference,frame.resources) || return nothing
    isnothing(backend.raster_registry) && Vellum.model_error(:resource_unavailable,"desktop renderer has no raster resolver")
    return Vellum.ImageTiles.retain_frame(backend.raster_registry,frame)
end

"""Texture identity for one dense crop or one independently reusable source tile."""
const DesktopTextureKey = Union{Tuple{Vellum.ImageData,NTuple{4,Int}},RasterPages.TileKey}

"""Reserve a distinct source page within the whole candidate's device budget, including reused pages."""
function reserve_desktop_page!(candidate,key)
    key isa RasterPages.TileKey || return
    candidate.pages < RasterPages.STREAM_ACTIVE || Vellum.model_error(:resource_limit,"desktop frame exceeds the resident page budget")
    candidate.pages += 1
    return nothing
end

"""Count and bound the page grid of a half-open texel crop before requesting device storage."""
function desktop_page_grid(crop)
    l,t,r,b = crop
    side = RasterPages.SIDE
    xs,ys = (l÷side):((r-1)÷side),(t÷side):((b-1)÷side)
    length(xs)*Int128(length(ys)) <= RasterPages.STREAM_ACTIVE ||
        Vellum.model_error(:resource_limit,"desktop crop exceeds the resident page budget")
    return xs,ys
end

"""
    visit_desktop_pages(draw, retention, placement)

Visit the nonempty 64-pixel pages intersecting a source crop. Pass their exact
identity, crop-relative origin and a lazy pixel reader. Cached pages do no pixel IO.
The exact revision stays pinned through every upload. A failing reader releases its lease.
"""
function visit_desktop_pages(draw,retention,placement)
    tiles = Vellum.ImageTiles
    side = RasterPages.SIDE
    l,t,_,_ = placement.crop
    xs,ys = placement.pages
    source = RasterPages.PageSource(placement.source)
    lease = tiles.acquire_revision(retention,placement.source)
    try
        shared = lease isa tiles.RevisionLease ? tiles.shared_tile_sources(lease,side) : nothing
        authority = isnothing(shared) ? nothing : get(shared,placement.source,nothing)
        for y in ys, x in xs
            key = if isnothing(authority)
                RasterPages.TileKey(source,x,y)
            else
                tiles.with_shared_tiles(index->RasterPages.page_key(source,x,y,index),authority)
            end
            isnothing(key) && continue
            read_page = () -> isnothing(authority) ? RasterPages.stage_page(lease,key,()->false) :
                              RasterPages.shared_upload_bytes(authority,key,()->false)
            draw(key,(x*side-l,y*side-t),read_page)
        end
    finally
        close(lease)
    end
end

"""Allocate a private GLX drawable and validate the selected device."""
function Vellum.make_surface(backend::DesktopBackend,size)
    dimensions = Vellum.checked_dimensions(size...)
    native = Base.invokelatest(glx_extension().open_target,dimensions,backend.device)
    return DesktopSurface(backend,native)
end

"""
    submit!(backend::DesktopBackend, surface::DesktopSurface, plan::PreparedFrame)

Queue a draw and return its GPU fence token. Readback continues to expose
the last completed frame until the token publishes. Each surface admits one pending draw.
"""
function Vellum.submit!(backend::DesktopBackend,surface::DesktopSurface,plan::Vellum.PreparedFrame)
    surface.backend === backend && plan.backend === backend || throw(ArgumentError("foreign OpenGL plan or surface"))
    return Base.invokelatest(glx_extension().submit_frame!,surface.native,plan)
end

"""Poll the OpenGL fence on its owning thread and publish the draw when it has finished."""
Vellum.completed(item::DesktopSubmission) = Base.invokelatest(glx_extension().advance!,item,UInt64(0))

"""Wait up to one second for an OpenGL draw. A timeout leaves its token available for retry."""
function Base.wait(item::DesktopSubmission)
    item.state in (:pending,:complete) || throw(ArgumentError("OpenGL submission is $(item.state)"))
    Base.invokelatest(glx_extension().advance!,item,WAIT_NS) || error("OpenGL fence timed out")
    return item
end

"""Discard a pending OpenGL draw and retain the last completed pixels and textures."""
Vellum.cancel!(item::DesktopSubmission) = Base.invokelatest(glx_extension().cancel_draw!,item)

"""Draw the frame synchronously on the surface's device and retain its completed pixels."""
function Vellum.execute!(backend::DesktopBackend,surface::DesktopSurface,plan::Vellum.PreparedFrame)
    item = Vellum.submit!(backend,surface,plan)
    try
        Base.invokelatest(glx_extension().advance!,item,typemax(UInt64)) || error("OpenGL draw did not complete")
    finally
        item.state === :pending && Vellum.cancel!(item)
    end
    return surface
end

"""Copy completed OpenGL pixels from the device into an independent top-left RGBA8 image."""
Vellum.readback(surface::DesktopSurface) = Base.invokelatest(glx_extension().capture,surface.native)

"""
    statistics(surface::DesktopSurface)

Return the OpenGL driver identity, completed draws, pending state and resident source count.
`uploaded_bytes` includes transfers from abandoned candidates. `committed_upload_bytes`
counts the source transfers of frames that reached publication.
"""
function statistics(surface::DesktopSurface)
    target = surface.native
    return (;target.vendor,target.renderer,target.frames,target.uploaded_bytes,target.committed_upload_bytes,
            resident_images=length(target.images),pending=target.pending !== nothing)
end

"""Release the private drawable, context and X11 connection on their creating thread."""
Base.close(surface::DesktopSurface) = Base.invokelatest(glx_extension().release!,surface.native)

"""Flatten and transform geometry with a tolerance measured in physical pixels."""
function device_geometry(path,transform,winding,stroke=nothing)
    a,b,c,d,_,_ = transform.coefficients
    tolerance = 1/(256*max(hypot(a,b)+hypot(c,d),1.0))
    neutral = Vellum.Solid(0,0,0)
    return isnothing(stroke) ? Vellum.PortableGeometry.lower_fill(path,neutral;transform,winding,tolerance) :
           Vellum.PortableGeometry.lower_stroke(path,neutral,stroke;transform,tolerance)
end

"""Return physical contours with consistent orientation for overlapping stroke pieces."""
function device_contours(geom)
    contours = Vellum.PortableGeometry.rebase(geom,(0,0))
    geom.union_pieces || return contours
    return map(contours) do points
        area = sum(eachindex(points);init=0.0) do i
            x,y = points[i]
            nx,ny = points[mod1(i+1,length(points))]
            Float64(x)*ny-Float64(y)*nx
        end
        area < 0 ? reverse(points) : points
    end
end

"""Lower captured glyphs, filled paths and strokes to physical device geometry."""
function node_geometry(node,frame,viewport)
    op = node.operation
    transform = viewport*op.state.transform
    if op isa Vellum.TextRun
        path = Vellum._portable_text_path(op,frame,node.id;max_commands=Vellum.DOCUMENT_TEXT_COMMANDS)
        return device_geometry(path,transform,:nonzero)
    elseif op isa Vellum.StrokePath
        return device_geometry(op.path,transform,:nonzero,op.state.stroke_style)
    end
    return device_geometry(op.path,transform,op.winding)
end

"""Project a gradient's constant-color lines into physical pixels, including skew and unequal axis scales."""
function gradient_axis(brush,state,viewport)
    mapping = Vellum.PortableGeometry.paint_mapping(brush,state.transform)*Vellum.PortableGeometry.inverse_transform(viewport)
    a,b,c,d,_,_ = mapping.coefficients
    dx,dy = brush.stop .- brush.start
    span = hypot(dx,dy)
    nx,ny = (a*dx+b*dy)/span,(c*dx+d*dy)/span
    dist = span/hypot(nx,ny)^2
    origin = Vellum.map_point(Vellum.PortableGeometry.inverse_transform(mapping),brush.start)
    return origin, origin .+ (dist*nx,dist*ny)
end

"""
    image_placement(node, frame, viewport)

Resolve a sampled image's half-open texel bounds, physical transform and optional destination mask.
The provider can reuse the cropped texture before requesting any pixel bytes.
"""
function image_placement(node,frame,viewport)
    op = node.operation
    source = Vellum.resource(frame,op.image)
    meta = Vellum.image_metadata(source)
    placement = Vellum._image_crop_layout(op,node.id,meta.width,meta.height)
    isnothing(placement) && return nothing
    mask = placement.fractional ? device_geometry(Vellum.rectangle_path(op.destination...),viewport*op.state.transform,:nonzero) : nothing
    l,t,r,b = placement.crop
    pages = source isa Vellum.RasterReference ? desktop_page_grid(placement.crop) : nothing
    return (;source,placement.crop,size=(r-l,b-t),transform=viewport*placement.transform,mask,pages)
end
