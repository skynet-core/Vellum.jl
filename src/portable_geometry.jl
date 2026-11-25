"""Renderer-independent, bounded preparation of the portable semantic model."""
module PortableGeometry
using ..Vetra: PathData, Transform2D, StrokeStyle, PaintDescriptor, Solid,
    LinearGradient, Color, FillPath, StrokePath, logical, option, model_error

export flatten, lower_fill, lower_stroke, lower_geometry, contains, paint_color,
    geometry_bounds, rebase, inverse_transform, PreparedGeometry, Contour

const Point = NTuple{2,Float64}
add(a,b) = (logical(a[1]+b[1]),logical(a[2]+b[2]))
sub(a,b) = (logical(a[1]-b[1]),logical(a[2]-b[2]))
mul(a,s) = (logical(a[1]*s),logical(a[2]*s))
divide(a,s) = (logical(a[1]/s),logical(a[2]/s))
cross(a,b) = logical(a[1]*b[2]-a[2]*b[1])
distance(a,b) = logical(hypot(sub(a,b)...))
mid(a,b) = (a[1]/2+b[1]/2,a[2]/2+b[2]/2)

struct Contour
    points::Tuple{Vararg{Point}}
    closed::Bool
end

mutable struct Budget
    remaining::Int
end
function budget(limit::Integer)
    0 < limit <= typemax(Int) || model_error(:invalid_input,"invalid vertex budget")
    return Budget(Int(limit))
end
function emit!(points, p, work)
    work.remaining > 0 || model_error(:resource_limit,"geometry vertex budget exhausted")
    work.remaining -= 1
    push!(points,p)
end
function tolerance_value(value::Real)
    result = logical(value)
    result > 0 || model_error(:invalid_input,"tolerance must be positive")
    return result
end
function mapped(t::Transform2D,p)
    a,b,c,d,e,f = t.coefficients
    return (logical(a*p[1]+c*p[2]+e),logical(b*p[1]+d*p[2]+f))
end
function inverse_transform(t::Transform2D)
    a,b,c,d,e,f = t.coefficients
    det = logical(a*d-b*c)
    det != 0 || model_error(:invalid_input,"singular inverse")
    return Transform2D(d/det,-b/det,-c/det,a/det,
        (c*f-d*e)/det,(b*e-a*f)/det)
end

include("portable_geometry/paths.jl")
include("portable_geometry/strokes.jl")
include("portable_geometry/preparation.jl")
end
