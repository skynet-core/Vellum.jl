struct PreparedGeometry
    contours::Tuple{Vararg{Contour}}
    winding::Symbol
    union_pieces::Bool
    paint::PaintDescriptor
    canvas_to_paint::Transform2D
    bounds::Union{Nothing,NTuple{4,Float64}}
end

function paint_mapping(paint::PaintDescriptor,transform)
    paint isa Solid && return Transform2D()
    paint isa LinearGradient || model_error(:unsupported,"unsupported geometry paint")
    all(s -> s.color.space==first(paint.stops).color.space,paint.stops) ||
        model_error(:unsupported,"mixed gradient color spaces")
    distance(paint.start,paint.stop)>0 || model_error(:invalid_input,"invalid gradient axis")
    return inverse_transform(paint.space === :local ? transform*paint.transform : paint.transform)
end

function prepared(contours,paint,transform,winding,union_pieces,padding,mapping)
    mapped_contours = Contour[]
    xmin,ymin,xmax,ymax = Inf,Inf,-Inf,-Inf
    for contour in contours
        points = Point[]
        for point in contour.points
            p = mapped(transform,point)
            push!(points,p)
            xmin,ymin = min(xmin,p[1]),min(ymin,p[2])
            xmax,ymax = max(xmax,p[1]),max(ymax,p[2])
        end
        push!(mapped_contours,Contour(Tuple(points),contour.closed))
    end
    bounds = if xmin==Inf
        nothing
    else
        a,b,c,d,_,_ = transform.coefficients
        px,py = logical((abs(a)+abs(c))*padding),logical((abs(b)+abs(d))*padding)
        (logical(xmin-px),logical(ymin-py),logical(xmax+px),logical(ymax+py))
    end
    return PreparedGeometry(Tuple(mapped_contours),winding,union_pieces,paint,mapping,bounds)
end

function lower_fill(path::PathData,paint::PaintDescriptor; transform::Transform2D=Transform2D(),
                    winding::Symbol=:nonzero,tolerance::Real=1/256,max_vertices::Integer=1_000_000)
    option(winding,(:nonzero,:evenodd))
    tol = tolerance_value(tolerance)
    mapping = paint_mapping(paint,transform)
    contours = flatten_path(path,tol,budget(max_vertices))
    return prepared(contours,paint,transform,winding,false,path.has_curves ? tol : 0.0,mapping)
end

function lower_stroke(path::PathData,paint::PaintDescriptor,style::StrokeStyle=StrokeStyle();
                      transform::Transform2D=Transform2D(),tolerance::Real=1/256,
                      max_vertices::Integer=1_000_000)
    tol = tolerance_value(tolerance)
    mapping = paint_mapping(paint,transform)
    isempty(style.dashes) || logical(sum(style.dashes)) > 0 ||
        model_error(:invalid_input,"invalid dash period")
    style.width==0 || style.width/2>0 ||
        model_error(:resource_limit,"stroke half-width below representable precision")
    work = budget(max_vertices)
    contours = flatten_path(path,tol,work)
    pieces = Contour[]
    if style.width > 0
        for contour in contours
            fragments = isempty(style.dashes) ? (contour,) : dashed(contour,style,work)
            for fragment in fragments
                expand!(pieces,fragment,style,tol,work)
            end
        end
    end
    padding = path.has_curves || style.cap===:round || style.join===:round ? tol : 0.0
    result = prepared(pieces,paint,transform,:nonzero,true,padding,mapping)
    if path.has_curves && result.bounds !== nothing
        # Control hull plus maximum cap/miter reach also bounds the unflattened stroke.
        reach = logical(style.width/2*max(1,style.miter_limit,sqrt(2)))
        a,b,c,d,_,_ = transform.coefficients
        px,py = logical((abs(a)+abs(c))*reach),logical((abs(b)+abs(d))*reach)
        xmin,ymin,xmax,ymax = result.bounds
        for command in path.commands
            for i in 2:2:length(command)-1
                p = mapped(transform,(command[i],command[i+1]))
                xmin,ymin = min(xmin,logical(p[1]-px)),min(ymin,logical(p[2]-py))
                xmax,ymax = max(xmax,logical(p[1]+px)),max(ymax,logical(p[2]+py))
            end
        end
        result = PreparedGeometry(result.contours,result.winding,true,paint,mapping,(xmin,ymin,xmax,ymax))
    end
    return result
end

lower_geometry(op::FillPath; kwargs...) = lower_fill(op.path,op.state.fill;
    transform=op.state.transform,winding=op.winding,kwargs...)
lower_geometry(op::StrokePath; kwargs...) = lower_stroke(op.path,op.state.stroke,
    op.state.stroke_style;transform=op.state.transform,kwargs...)
geometry_bounds(geometry::PreparedGeometry) = geometry.bounds

const ORIENTATION_WORDS=67 # 4288 two's-complement bits; |determinant| < 2^4199.
# Includes conservative scalar/call-state storage; see the liveness table in the geometry reference.
const ORIENTATION_STATE_BYTES=1024
const ORIENTATION_BYTES=ORIENTATION_WORDS*sizeof(UInt64)+ORIENTATION_STATE_BYTES
const ORIENTATION_PRIMITIVE_BOUND=32768
orientation_workspace()=zeros(UInt64,ORIENTATION_WORDS)
struct RenderCancelled <: Exception end
orientation_cancel(token)=token!==nothing && token.requested[] ? throw(RenderCancelled()) : nothing

@inline function orientation_parts(x::Float64)
    bits=reinterpret(UInt64,x)
    exponent=Int((bits>>52)&0x7ff)
    fraction=bits&0x000fffffffffffff
    (exponent==0 ? fraction : fraction|0x0010000000000000,
     exponent==0 ? 0 : exponent-1,bits>>63!=0)
end

function orientation_product!(words,a,b,subtract)
    am,ae,an=orientation_parts(a)
    bm,be,bn=orientation_parts(b)
    product=UInt128(am)*bm
    product==0 && return nothing
    word,offset=divrem(ae+be,64)
    lo,hi=UInt64(product&typemax(UInt64)),UInt64(product>>64)
    p0=lo<<offset
    p1=offset==0 ? hi : (hi<<offset)|(lo>>(64-offset))
    p2=offset==0 ? UInt64(0) : hi>>(64-offset)
    negative=xor(xor(an,bn),subtract)
    carry=UInt64(0)
    for i in word+1:ORIENTATION_WORDS
        part=i==word+1 ? p0 : i==word+2 ? p1 : i==word+3 ? p2 : UInt64(0)
        current=UInt128(words[i])
        if negative
            amount=UInt128(part)+carry
            words[i]=UInt64((current-amount)&typemax(UInt64))
            carry=UInt64(current<amount)
        else
            total=current+part+carry
            words[i]=UInt64(total&typemax(UInt64))
            carry=UInt64(total>>64)
        end
        i>=word+3 && carry==0 && break
    end
    nothing
end

function orientation_exact(a,b,p,words=orientation_workspace())
    length(words)==ORIENTATION_WORDS || model_error(:invalid_state,"invalid orientation workspace")
    fill!(words,0)
    # Expanded determinant cancels ax*ay; every remaining product has <=106 bits.
    orientation_product!(words,b[1],p[2],false)
    orientation_product!(words,b[1],a[2],true)
    orientation_product!(words,a[1],p[2],true)
    orientation_product!(words,b[2],p[1],true)
    orientation_product!(words,b[2],a[1],false)
    orientation_product!(words,a[2],p[1],false)
    words[end]>>63!=0 && return -1
    any(!iszero,words) ? 1 : 0
end

# `nothing` means the floating-point sign is uncertified, never "on the edge".
@inline function orientation_filter(a,b,p)
    Base.JLOptions().fast_math==1 && return nothing
    if a[1]==b[1]
        return -((b[2]>a[2])-(b[2]<a[2]))*((p[1]>a[1])-(p[1]<a[1]))
    elseif a[2]==b[2]
        return ((b[1]>a[1])-(b[1]<a[1]))*((p[2]>a[2])-(p[2]<a[2]))
    end
    dx,dy=b[1]-a[1],b[2]-a[2]
    px,py=p[1]-a[1],p[2]-a[2]
    # Guard normal products, error bound and all intermediates against range loss.
    all(v->v==0 || 0x1p-450<=abs(v)<=0x1p450,(dx,dy,px,py)) || return nothing
    left,right=dx*py,dy*px
    determinant=left-right
    # Each product has three roundings; 32u dominates their propagated error
    # and the final subtraction (u=2^-53), with normal, non-overflowing arithmetic.
    bound=0x1p-48*(abs(left)+abs(right))
    abs(determinant)>bound ? (determinant>0 ? 1 : -1) : nothing
end

@inline function orientation_sign(a,b,p,workspace=nothing,token=nothing)
    orientation_cancel(token)
    result=orientation_filter(a,b,p)
    result===nothing || return result
    orientation_cancel(token)
    workspace===nothing && (workspace=orientation_workspace())
    result=orientation_exact(a,b,p,workspace)
    orientation_cancel(token)
    result
end

function winding_workspace(contour,point,workspace,token)
    orientation_cancel(token)
    result = 0
    points = contour.points
    for i in eachindex(points)
        (i-1)%256==0 && orientation_cancel(token)
        a,b = points[i],points[mod1(i+1,length(points))]
        direction=a[2]<=point[2]<b[2] ? 1 : b[2]<=point[2]<a[2] ? -1 : 0
        direction==0 && continue
        side=orientation_filter(a,b,point)
        if side===nothing
            orientation_cancel(token)
            workspace===nothing && (workspace=orientation_workspace())
            side=orientation_exact(a,b,point,workspace)
            orientation_cancel(token)
        end
        side*direction>0 && (result+=direction)
    end
    return result,workspace
end
winding_at(contour,point)=first(winding_workspace(contour,point,nothing,nothing))

function contains(geometry::PreparedGeometry,point::Tuple{Real,Real},workspace=nothing,token=nothing)
    p = map(logical,point)
    winding=0
    orientation_cancel(token)
    for contour in geometry.contours
        orientation_cancel(token)
        contribution,workspace=winding_workspace(contour,p,workspace,token)
        geometry.union_pieces && contribution!=0 && return true
        winding+=contribution
    end
    geometry.union_pieces && return false
    return geometry.winding === :nonzero ? winding!=0 : isodd(winding)
end

premultiplied(color) = (color.channels[1]*color.channels[4],
    color.channels[2]*color.channels[4],color.channels[3]*color.channels[4],color.channels[4])

function paint_color(geometry::PreparedGeometry,point::Tuple{Real,Real})
    p = map(logical,point)
    paint = geometry.paint
    paint isa Solid && return premultiplied(paint.color)
    q = mapped(geometry.canvas_to_paint,p)
    axis = sub(paint.stop,paint.start)
    length = logical(hypot(axis...))
    length > 0 || model_error(:invalid_input,"invalid gradient axis")
    unit = divide(axis,length)
    delta = sub(q,paint.start)
    t = clamp(logical((delta[1]*unit[1]+delta[2]*unit[2])/length),0,1)
    stops = paint.stops
    right = findfirst(s -> s.position>t,stops)
    right === nothing && return premultiplied(last(stops).color)
    right == 1 && return premultiplied(first(stops).color)
    left = stops[right-1]
    next = stops[right]
    weight = (t-left.position)/(next.position-left.position)
    a,b = premultiplied(left.color),premultiplied(next.color)
    return ntuple(i -> a[i]*(1-weight)+b[i]*weight,4)
end

"""Rebase before narrowing; reject unrepresentable output rather than emit infinities."""
function rebase(geometry::PreparedGeometry,origin::Tuple{Real,Real};max_error::Real=1/256)
    offset = map(logical,origin)
    limit = tolerance_value(max_error)
    contours = Tuple[]
    for contour in geometry.contours
        points = NTuple{2,Float32}[]
        for p in contour.points
            rebased = sub(p,offset)
            values = map(Float32,rebased)
            all(isfinite,values) || model_error(:invalid_input,"rebased coordinates exceed Float32")
            all(i -> abs(Float64(values[i])-rebased[i])<=limit,1:2) ||
                model_error(:unsupported,"Float32 rebasing exceeds precision policy")
            push!(points,values)
        end
        push!(contours,Tuple(points))
    end
    return Tuple(contours)
end
