function chord_distance(p,a,b)
    length = distance(a,b)
    length == 0 && return distance(p,a)
    direction = divide(sub(b,a),length)
    delta = sub(p,a)
    projection = logical(delta[1]*direction[1]+delta[2]*direction[2])
    return distance(p,add(a,mul(direction,clamp(projection,0,length))))
end

function curve!(out, controls, tolerance, work, depth=0)
    a,b = first(controls),last(controls)
    if all(p -> chord_distance(p,a,b) <= tolerance,controls)
        emit!(out,b,work)
        return
    end
    depth < 64 || model_error(:resource_limit,"curve subdivision precision exhausted")
    if length(controls)==3
        ab,bc = mid(controls[1],controls[2]),mid(controls[2],controls[3])
        center = mid(ab,bc)
        left,right = (a,ab,center),(center,bc,b)
    else
        ab,bc,cd = mid(controls[1],controls[2]),mid(controls[2],controls[3]),mid(controls[3],controls[4])
        abc,bcd = mid(ab,bc),mid(bc,cd)
        center = mid(abc,bcd)
        left,right = (a,ab,abc,center),(center,bcd,cd,b)
    end
    curve!(out,left,tolerance,work,depth+1)
    curve!(out,right,tolerance,work,depth+1)
end

"""
    PathCommand

Internal fixed-width command used by portable geometry sources. Opcode values
1 through 5 mean move, line, quadratic, cubic and close. The final active
point is the destination. The command source validates opcode and coordinates.
"""
struct PathCommand
    opcode::Int32
    a::Point
    b::Point
    c::Point
end

"""Decode a validated PathData command. Inactive coordinates use zero pairs."""
function path_command(command::Tuple)::PathCommand
    tag = first(command)
    zero_point = (0.0, 0.0)
    tag === :close && return PathCommand(5, zero_point, zero_point, zero_point)
    a = (command[2], command[3])
    if tag === :move || tag === :line
        return PathCommand(tag === :move ? 1 : 2, a, zero_point, zero_point)
    end
    b = (command[4], command[5])
    tag === :quad && return PathCommand(3, a, b, zero_point)
    return PathCommand(4, a, b, (command[6], command[7]))
end

"""Use a previously validated fixed-width command directly."""
path_command(command::PathCommand) = command

"""Expose the command sequence without copying or specializing on its length."""
path_commands(path::PathData) = path.commands
"""Use a typed command vector directly for compilation to a bounded target."""
path_commands(commands::Vector{PathCommand}) = commands

"""
    finish_contour!(contours, points, first_point, closed) -> Int

Publish the current nonempty contour as an immutable native value and reuse its
scratch vector. The native collector always starts its next contour at one.
An alternate collector can retain the contiguous points and return the next
unused vertex index.
"""
function finish_contour!(contours::Vector{Contour}, points::Vector{Point},
                         first_point::Int, closed::Bool)::Int
    push!(contours, Contour(Tuple(points), closed))
    empty!(points)
    return 1
end

"""
    walk_path!(contours, points, source, tolerance, work) -> contours

Traverse a validated command source and append contours by calling
`finish_contour!`. The caller supplies empty scratch points and a positive
tolerance. Vertex and subdivision limits raise `ModelError`. An error can
leave partial output in the caller-owned scratch buffers.
"""
function walk_path!(contours, points::Vector{Point}, source, tolerance::Float64, work::Budget)
    current = (0.0, 0.0)
    start = current
    first_point = 1
    for input in path_commands(source)
        command = path_command(input)::PathCommand
        opcode = command.opcode
        if opcode == 1 || opcode == 5
            if first_point <= length(points)
                first_point = finish_contour!(contours, points, first_point, opcode == 5)
            end
            if opcode == 1
                start = command.a
                emit!(points, start, work)
            end
            current = start
        else
            first_point > length(points) && emit!(points, current, work)
            if opcode == 2
                current = command.a
                emit!(points, current, work)
            elseif opcode == 3
                curve!(points, (current, command.a, command.b), tolerance, work)
                current = command.b
            else
                curve!(points, (current, command.a, command.b, command.c), tolerance, work)
                current = command.c
            end
        end
    end
    first_point <= length(points) && finish_contour!(contours, points, first_point, false)
    return contours
end

"""
    flatten_path(path, tolerance, work) -> Vector{Contour}

Flatten the validated native path and return immutable contours in traversal
order. Subdivision and vertex-budget failures propagate as `ModelError`.
"""
function flatten_path(path::PathData, tolerance::Float64, work::Budget)
    return walk_path!(Contour[], Point[], path, tolerance, work)
end

"""
    flatten(path::PathData; tolerance=1/256, max_vertices=1_000_000) -> Tuple

Flatten curves with a control-hull/chord distance bound in object units.
Return immutable contours in path order. Invalid tolerances or budgets and
subdivision failures raise `ModelError`.
"""
function flatten(path::PathData; tolerance::Real=1/256, max_vertices::Integer=1_000_000)
    return Tuple(flatten_path(path,tolerance_value(tolerance),budget(max_vertices)))
end
