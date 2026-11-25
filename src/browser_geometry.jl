"""An oriented nonhorizontal edge used to split a vector fill into nonoverlapping trapezoids."""
struct _BrowserEdge
    low::Vec2
    high::Vec2
    slope::Float64
    winding::Int
    shape::Int
end

"""Intersect a path edge with a horizontal line in local drawing coordinates."""
_edge_x(edge::_BrowserEdge,y) = edge.low.x + (y-edge.low.y)*edge.slope

"""Emit six Float32 values per trapezoid. Multiple input paths describe the intersection of clip regions."""
function _browser_traps(shapes,rules)
    edges = _BrowserEdge[]
    levels = Float64[]
    for (shape,contours) in enumerate(shapes), points in contours
        isempty(points) && continue
        a = last(points)
        for b in points
            if a.y != b.y
                low,high = a.y<b.y ? (a,b) : (b,a)
                slope = (Float64(high.x)-low.x)/(Float64(high.y)-low.y)
                push!(edges,_BrowserEdge(low,high,slope,a.y<b.y ? 1 : -1,shape))
                push!(levels,low.y,high.y)
            end
            a = b
        end
    end
    # The ordering of two edges can also change within a band at a self-intersection.
    sort!(edges;by=e->e.low.y)
    for i in eachindex(edges)
        a = edges[i]
        for j in i+1:length(edges)
            b = edges[j]
            lo,hi = Float64(b.low.y),Float64(min(a.high.y,b.high.y))
            lo >= a.high.y && break
            den = a.slope-b.slope
            den == 0 && continue
            y = lo + (_edge_x(b,lo)-_edge_x(a,lo))/den
            lo < y < hi && push!(levels,y)
        end
    end
    sort!(unique!(levels))
    mesh = Float32[]
    active = _BrowserEdge[]
    winding = zeros(Int,length(rules))
    next = 1
    for i in 2:length(levels)
        lo,hi = levels[i-1],levels[i]
        mid = (lo+hi)/2
        filter!(e->e.high.y>mid,active)
        while next<=length(edges) && edges[next].low.y<=mid
            edges[next].high.y>mid && push!(active,edges[next])
            next += 1
        end
        sort!(active;by=e->_edge_x(e,mid))
        fill!(winding,0)
        left = nothing
        for edge in active
            winding[edge.shape] += edge.winding
            inside = all(k->rules[k]===EvenOdd ? isodd(winding[k]) : !iszero(winding[k]),eachindex(rules))
            if inside && isnothing(left)
                left = edge
            elseif !inside && !isnothing(left)
                if _edge_x(edge,mid)>_edge_x(left,mid)
                    append!(mesh,(_edge_x(left,lo),_edge_x(edge,lo),_edge_x(left,hi),_edge_x(edge,hi),lo,hi))
                end
                left = nothing
            end
        end
    end
    return mesh
end

"""Partition horizontally disjoint contours before sweeping. Separate glyphs cannot change each other's winding."""
function _browser_fill_mesh(contours,rule)
    ranges = [(extrema(p->p.x,points)...,points) for points in contours if !isempty(points)]
    sort!(ranges;by=first)
    mesh = Float32[]
    group = Vector{Vec2}[]
    xmax = -Inf32
    for (lo,hi,points) in ranges
        if !isempty(group) && lo>xmax
            append!(mesh,_browser_traps((group,),(rule,)))
            empty!(group)
            xmax = -Inf32
        end
        push!(group,points)
        xmax = max(xmax,hi)
    end
    isempty(group) || append!(mesh,_browser_traps((group,),(rule,)))
    return mesh
end

"""Flatten retained curves and expand strokes in path coordinates at subpixel tolerance."""
function _browser_mesh(op::Union{FillOp,StrokeOp},cache)
    scale = max(1f0,8f0*pixelScale(op.tform))
    key = op isa StrokeOp ? (op.path.commands,scale,op.width,op.cap,op.join,op.miterLimit,op.dashes) :
                            (op.path.commands,scale,op.windingRule)
    return get!(cache,key) do
        if op isa StrokeOp
            shapes = strokeShapes(commandsToShapes(op.path,false,scale),op.width,op.cap,op.join,op.miterLimit,op.dashes,scale)
            return _browser_fill_mesh(shapes,NonZero)
        end
        return _browser_fill_mesh(commandsToShapes(op.path,true,scale),op.windingRule)
    end
end

"""Produce one world-space mesh covering the intersection of a group's clipping paths."""
function _browser_clip_mesh(clips)
    shapes = map(clips) do clip
        contours = commandsToShapes(clip.path,true,max(1f0,8f0*pixelScale(clip.transform)))
        [[clip.transform*p for p in contour] for contour in contours]
    end
    return _browser_traps(shapes,[c.windingRule for c in clips])
end
