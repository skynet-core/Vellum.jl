# Bounds use (xmin,ymin,xmax,ymax), not the public (x,y,width,height) rectangles.
const SceneBounds = NTuple{4,Float64}
const ALL_BOUNDS = (-Inf,-Inf,Inf,Inf)

function union_bounds(a, b)
    a === nothing && return b
    b === nothing && return a
    return (min(a[1],b[1]),min(a[2],b[2]),max(a[3],b[3]),max(a[4],b[4]))
end
function expand_bounds(box, x, y=x)
    box === nothing && return nothing
    return (box[1]-x,box[2]-y,box[3]+x,box[4]+y)
end
function intersects_bounds(a, b)
    return a !== nothing && b !== nothing &&
        a[1] <= b[3] && b[1] <= a[3] && a[2] <= b[4] && b[2] <= a[4]
end

function path_bounds(path::PathData, transform::Transform2D)
    box = nothing
    for command in path.commands
        for i in 2:2:length(command)-1
            x,y = map_point(transform,(command[i],command[i+1]))
            isfinite(x) && isfinite(y) || model_error(:size_overflow,"transformed bounds overflow")
            box = union_bounds(box,(x,y,x,y))
        end
    end
    return box
end

function operation_bounds(operation::SemanticOperation)
    if operation isa CompositeGroup
        box = nothing
        if operation.nodes isa SceneNodes
            box = tree_bounds(operation.nodes.root)
        else
            for child in operation.nodes
                box = union_bounds(box,operation_bounds(child.operation))
            end
        end
        effect = operation.effect
        return effect === nothing ? box : expand_bounds(box,effect.radius_x,effect.radius_y)
    elseif operation isa Union{FillPath,StrokePath}
        box = path_bounds(operation.path,operation.state.transform)
        if operation isa StrokePath
            style = operation.state.stroke_style
            reach = logical(style.width/2*max(1,sqrt(2),style.miter_limit))
            a,b,c,d,_,_ = operation.state.transform.coefficients
            box = expand_bounds(box,logical((abs(a)+abs(c))*reach),logical((abs(b)+abs(d))*reach))
        end
        return box
    elseif operation isa Union{ImageRegion,SurfaceRegion,ClearRegion}
        rect = operation isa ClearRegion ? operation.rectangle : operation.destination
        return path_bounds(rectangle_path(rect...),operation.state.transform)
    end
    # Text and extension operations need provider bounds before they can narrow damage.
    return ALL_BOUNDS
end

function support_depth(operation::SemanticOperation)
    operation isa CompositeGroup || return 1
    depth = operation.nodes isa SceneNodes ? tree_support(operation.nodes.root) :
        maximum((support_depth(n.operation) for n in operation.nodes);init=0)
    return depth + (operation.effect === nothing ? 0 : 1)
end

function physical_padding(scale)
    x,y = map(logical,scale)
    x > 0 && y > 0 || model_error(:invalid_input,"pixel scale must be positive")
    return (logical(1/x),logical(1/y))
end
function raster_bounds(node::SemanticNode, scale=(1,1))
    x,y = physical_padding(scale)
    depth = support_depth(node.operation)
    return expand_bounds(operation_bounds(node.operation),x*depth,y*depth)
end
