"""
    DesktopBackend(; device=:auto)

Render paths and isolated groups on the OpenGL device of the current X11
display. Each surface owns an offscreen GLX drawable and context. Device
selection and graphics library loading take place when the surface is opened.
"""
struct DesktopBackend <: Vellum.Backend
    device::Union{Symbol,Tuple{UInt16,UInt16}}
    function DesktopBackend(;device=:auto)
        device isa Symbol && device in (:auto,:amd,:intel,:nvidia) && return new(device)
        if device isa Tuple && length(device)==2 &&
           all(x -> x isa Integer && !(x isa Bool) && 0 < x <= typemax(UInt16), device)
            return new((UInt16(device[1]),UInt16(device[2])))
        end
        throw(ArgumentError("invalid OpenGL device selector $device"))
    end
end

"""Offscreen OpenGL target. Its native context and pixel storage belong to its creating thread."""
struct DesktopSurface{S} <: Vellum.Surface
    backend::DesktopBackend
    native::S
end

"""Load the first-party GLX implementation at the first native request."""
function glx_extension()
    (Sys.islinux() || Sys.isfreebsd()) || throw(ArgumentError("this desktop OpenGL provider requires GLX"))
    Base.require(Base.PkgId(Base.UUID("d59498f3-381e-4841-a765-4609d464ae1b"),"Skia"))
    ext = Base.get_extension(Vellum,:VellumGLXExt)
    isnothing(ext) && error("Vellum's desktop OpenGL extension failed to load")
    return ext
end

"""Report the operations supported by the GLX path renderer."""
Vellum.capabilities(::DesktopBackend) = Vellum.Capabilities(features=(
    :fill_path,:stroke_path,:path_precision_1_256px,:curve_paths,:clip,:group,:gradient,:image,:linear_sampling,:float64,:text,:text_captured_glyphs_v1))

"""Allocate a private GLX drawable and validate the selected device."""
function Vellum.make_surface(backend::DesktopBackend,size)
    dimensions = Vellum.checked_dimensions(size...)
    native = Base.invokelatest(glx_extension().open_target,dimensions,backend.device)
    return DesktopSurface(backend,native)
end

"""Draw the frame on the surface's own device, leaving the completed pixels resident."""
function Vellum.execute!(backend::DesktopBackend,surface::DesktopSurface,plan::Vellum.PreparedFrame)
    surface.backend === backend && plan.backend === backend || throw(ArgumentError("foreign OpenGL plan or surface"))
    Base.invokelatest(glx_extension().draw_frame!,surface.native,plan.frame)
    return surface
end

"""Copy completed OpenGL pixels from the device into an independent top-left RGBA8 image."""
Vellum.readback(surface::DesktopSurface) = Base.invokelatest(glx_extension().capture,surface.native)

"""Return the driver's vendor, renderer and number of completed frame draws."""
statistics(surface::DesktopSurface) = (vendor=surface.native.vendor,renderer=surface.native.renderer,
                                      frames=surface.native.frames)

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

"""Resolve and crop a dense image for a device draw, including its pixel-to-frame transform."""
function image_placement(node,frame,viewport)
    op = node.operation
    matrix = Vellum._document_matrix(op.state.transform,node.id)
    placement = Vellum._document_image(op,frame,node.id,matrix,Vellum.DocumentCrops())
    isnothing(placement) && return nothing
    leaf,clip = placement
    m = leaf.imageMat
    transform = viewport*Vellum.Transform2D(m[1,1],m[1,2],m[2,1],m[2,2],m[3,1],m[3,2])
    mask = isnothing(clip) ? nothing : device_geometry(Vellum.rectangle_path(op.destination...),viewport*op.state.transform,:nonzero)
    return (;leaf.image,transform,mask)
end
