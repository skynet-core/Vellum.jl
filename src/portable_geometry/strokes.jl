"""Open an owned polygon for native stroke expansion."""
begin_polygon!(out::Vector{Contour}) = Point[]

"""Append one point and charge the shared stroke work budget."""
polygon_vertex!(out::Vector{Contour}, piece::Vector{Point}, point, work) = emit!(piece,point,work)

"""Publish a closed contour into the native stroke pieces."""
finish_polygon!(out::Vector{Contour}, piece::Vector{Point}) = push!(out,Contour(Tuple(piece),true))

"""Build one closed polygon through the output's point sink."""
function polygon!(out, points, work)
    piece = begin_polygon!(out)
    for point in points
        polygon_vertex!(out,piece,point,work)
    end
    finish_polygon!(out,piece)
end

function disk!(out,p,r,tolerance,work)
    # Sagitta bound; quarter-circle minimum keeps cardinal extrema in the polygon.
    angle = acos(clamp(1-tolerance/r,-1,1))
    angle > 0 || model_error(:resource_limit,"round tolerance below representable precision")
    pi/angle <= work.remaining || model_error(:resource_limit,"round geometry exceeds budget")
    required = max(4,ceil(Int,pi/angle))
    required <= work.remaining || model_error(:resource_limit,"round geometry exceeds budget")
    count = Base.checked_mul(cld(required,4),4)
    piece = begin_polygon!(out)
    for i in 0:count-1
        point = add(p,mul((cospi(2i/count),sinpi(2i/count)),r))
        polygon_vertex!(out,piece,point,work)
    end
    finish_polygon!(out,piece)
end

function cap!(out,p,direction,r,cap,tolerance,work)
    if cap === :round
        disk!(out,p,r,tolerance,work)
    elseif cap === :square
        n = mul((-direction[2],direction[1]),r)
        extension = mul(direction,r)
        polygon!(out,(add(p,n),add(add(p,n),extension),
            add(sub(p,n),extension),sub(p,n)),work)
    end
end

function join!(out,p,u,v,r,style,tolerance,work)
    turn = cross(u,v)
    if style.join === :round
        dot = u[1]*v[1]+u[2]*v[2]
        turn==0 && dot>0 && return
        sweep = turn==0 ? pi : atan(turn,dot)
        side = sweep>0 ? -1 : 1
        # Separate captures from the reassigned miter offsets to avoid boxing.
        round_a = mul((-u[2],u[1]),r*side)
        round_b = mul((-v[2],v[1]),r*side)
        angle = acos(clamp(1-tolerance/r,-1,1))
        angle>0 || model_error(:resource_limit,"round tolerance below representable precision")
        steps = abs(sweep)/(2angle)
        steps<=work.remaining-2 || model_error(:resource_limit,"round join exceeds budget")
        count = max(1,ceil(Int,steps))
        start = atan(round_a[2],round_a[1])
        piece = begin_polygon!(out)
        polygon_vertex!(out,piece,p,work)
        for i in 0:count
            point = i==0 ? add(p,round_a) : i==count ? add(p,round_b) :
                add(p,mul((cos(start+sweep*i/count),sin(start+sweep*i/count)),r))
            polygon_vertex!(out,piece,point,work)
        end
        finish_polygon!(out,piece)
    elseif turn != 0
        side = -sign(turn)
        a = mul((-u[2],u[1]),r*side)
        b = mul((-v[2],v[1]),r*side)
        if style.join === :miter
            offset = mul(u,cross(sub(b,a),v)/turn)
            tip = add(a,offset)
            if distance(tip,(0.0,0.0))/r <= style.miter_limit
                polygon!(out,(p,add(p,a),add(p,tip),add(p,b)),work)
                return
            end
        end
        polygon!(out,(p,add(p,a),add(p,b)),work)
    end
end

function expand!(out, contour, style, tolerance, work)
    points = Point[]
    for p in contour.points
        isempty(points) || p != last(points) || continue
        push!(points,p)
    end
    closed = contour.closed
    closed && length(points)>1 && first(points)==last(points) && pop!(points)
    isempty(points) && return
    r = style.width/2
    if length(points)==1
        if !closed
            cap!(out,first(points),(1.0,0.0),r,style.cap,tolerance,work)
            style.cap === :square && cap!(out,first(points),(-1.0,0.0),r,style.cap,tolerance,work)
        end
        return
    end
    directions = Point[]
    count = closed ? length(points) : length(points)-1
    for i in 1:count
        a,b = points[i],points[mod1(i+1,length(points))]
        u = divide(sub(b,a),distance(a,b))
        push!(directions,u)
        n = mul((-u[2],u[1]),r)
        polygon!(out,(add(a,n),add(b,n),sub(b,n),sub(a,n)),work)
    end
    for i in (closed ? (1:length(points)) : (2:length(points)-1))
        join!(out,points[i],directions[mod1(i-1,count)],directions[mod1(i,count)],
            r,style,tolerance,work)
    end
    if !closed
        cap!(out,first(points),mul(first(directions),-1),r,style.cap,tolerance,work)
        cap!(out,last(points),last(directions),r,style.cap,tolerance,work)
    end
end

"""An owned painted run of a dashed path, with its original closure when applicable."""
struct DashRun
    points::Vector{Point}
    closed::Bool
end

"""
    dash_runs(points, closed, dashes, offset, work) -> Vector{DashRun}

Split one flattened centerline into painted intervals in object-space arc
length. Odd patterns run twice before repeating. Zero on lengths may
produce one-point cap runs. The pattern phase continues through vertices
and painted runs meeting at a closed seam are joined. Input arrays are read
only; returned fragments own their vertices. Invalid periods, insufficient
floating-point progress or exhausted work raise ModelError.
"""
@noinline function dash_runs(points::Vector{Point}, closed::Bool, dashes::Vector{Float64},
                   offset::Float64, work::Budget)::Vector{DashRun}
    pattern = Float64[]
    passes = isodd(length(dashes)) ? 2 : 1
    for _ in 1:passes
        for dash in dashes
            push!(pattern,dash)
        end
    end
    total = logical(sum(pattern))
    total > 0 || model_error(:invalid_input,"invalid dash period")
    phase = mod(offset,total)
    index = 1
    for _ in eachindex(pattern)
        phase > 0 && phase >= pattern[index] || break
        phase -= pattern[index]
        index = mod1(index+1,length(pattern))
    end
    (phase == 0 || phase < pattern[index]) ||
        model_error(:resource_limit,"dash phase precision exhausted")
    remaining = pattern[index]-phase
    fragments = DashRun[]
    isempty(points) && return fragments
    all_same = true
    for point in points
        all_same &= point == first(points)
    end
    if all_same
        if isodd(index)
            original = Point[]
            for point in points
                push!(original,point)
            end
            push!(fragments,DashRun(original,closed))
        end
        return fragments
    end
    run = Point[]
    edge_count = closed ? length(points) : length(points)-1
    for i in 1:edge_count
        a,b = points[i],points[mod1(i+1,length(points))]
        segment_length = distance(a,b)
        segment_length == 0 && continue
        direction = divide(sub(b,a),segment_length)
        used = 0.0
        while used < segment_length
            while remaining == 0
                if isodd(index) && isempty(run)
                    dot = Point[]
                    emit!(dot,add(a,mul(direction,used)),work)
                    push!(fragments,DashRun(dot,false))
                end
                index = mod1(index+1,length(pattern))
                remaining = pattern[index]
            end
            if iseven(index) && !isempty(run)
                push!(fragments,DashRun(run,false))
                run = Point[]
            end
            step = min(remaining,segment_length-used)
            next = logical(used+step)
            next > used || model_error(:resource_limit,"dash precision exhausted")
            if isodd(index)
                isempty(run) && emit!(run,add(a,mul(direction,used)),work)
                emit!(run,next==segment_length ? b : add(a,mul(direction,next)),work)
            end
            used = next
            remaining -= step
            if remaining == 0
                index = mod1(index+1,Base.length(pattern))
                remaining = pattern[index]
            end
        end
    end
    if !isempty(points) && isempty(run) && isodd(index) && remaining==pattern[index]
        dot = Point[]
        emit!(dot,closed ? first(points) : last(points),work)
        push!(fragments,DashRun(dot,false))
    end
    isempty(run) || push!(fragments,DashRun(run,false))
    if closed && length(fragments)>1 &&
        first(first(fragments).points)==last(last(fragments).points)
        head = fragments[1].points
        tail = last(fragments).points
        resize!(fragments,length(fragments)-1)
        for i in 2:length(head)
            push!(tail,head[i])
        end
        fragments[1] = DashRun(tail,false)
    end
    if closed && length(fragments)==1 && length(first(fragments).points)>1 &&
        first(first(fragments).points)==last(first(fragments).points)
        fragments[1] = DashRun(first(fragments).points,true)
    end
    return fragments
end

"""Adapt native tuple-backed contours and styles to the shared dash traversal."""
function dashed(contour,style,work)
    return dash_runs(Point[contour.points...],contour.closed,Float64[style.dashes...],
                     style.dash_offset,work)
end
