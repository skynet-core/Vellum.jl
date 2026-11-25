using LazyArtifacts: @artifact_str
import JSON
import Wasmtime_jll

"""Owned byte vector returned by the Wasmtime C API."""
struct _WasmBytes
    size::Csize_t
    data::Ptr{UInt8}
end

"""Locate the bundled Wasmtime library, or the configured system build on FreeBSD ARM."""
_wasmtime_library() = get(() -> Wasmtime_jll.libwasmtime, ENV, "LIBWASMTIME_LOCATION")

"""Assemble WebAssembly text in process and copy the resulting module into Julia-owned memory."""
function _wat2wasm(source::String)
    Libdl.dlopen(_wasmtime_library()) do lib
        bytes = Ref(_WasmBytes(0,C_NULL))
        failure = ccall(Libdl.dlsym(lib,:wasmtime_wat2wasm),Ptr{Cvoid},
                        (Ptr{UInt8},Csize_t,Ref{_WasmBytes}),source,ncodeunits(source),bytes)
        try
            if failure != C_NULL
                ccall(Libdl.dlsym(lib,:wasmtime_error_message),Cvoid,
                      (Ptr{Cvoid},Ref{_WasmBytes}),failure,bytes)
                throw(ArgumentError(unsafe_string(bytes[].data,bytes[].size)))
            end
            return copy(unsafe_wrap(Vector{UInt8},bytes[].data,bytes[].size))
        finally
            ccall(Libdl.dlsym(lib,:wasm_byte_vec_delete),Cvoid,(Ref{_WasmBytes},),bytes)
            if failure != C_NULL
                ccall(Libdl.dlsym(lib,:wasmtime_error_delete),Cvoid,(Ptr{Cvoid},),failure)
            end
        end
    end
end

include("browser_bindings.jl")
include("browser_viewer.jl")

_browser_matrix(m) = (m[1,1], m[1,2], m[2,1], m[2,2], m[3,1], m[3,2])
function _browser_path(path,matrix,winding)
    data = _svgPathD(path)
    return (;path=data,matrix=_browser_matrix(matrix),evenodd=winding === EvenOdd,compound=count(c -> c in ('M','m'),data)>1)
end
_browser_point(p) = (x=p.x, y=p.y)

function _browser_op(op::FillOp)
    path = _browser_path(op.path, op.tform, op.windingRule)
    paint = op.paint
    if paint.kind === SolidPaint
        return (; kind="fill", path..., style=(color=_svgHex(paint.color), alpha=_svgSolidOpacity(paint)))
    end
    # Express the canvas-space gradient as a scalar projection in path coordinates.
    a, b = paint.gradientHandlePositions
    direction = (b - a) / lengthSq(b - a)
    m = op.tform
    gradient = Vec2(m[1,1]*direction.x + m[1,2]*direction.y,
                    m[2,1]*direction.x + m[2,2]*direction.y)
    start = inverse(m) * a
    stop = start + gradient / lengthSq(gradient)
    stops = [(offset=s.position, color=_svgHex(s.color)*string(s.color.a;base=16,pad=2)) for s in paint.gradientStops]
    options = (; type="linear", start=_browser_point(start), :end=>_browser_point(stop),
               textureSpace="global", colorStops=stops)
    return (; kind="gradient", path..., options, alpha=paint.opacity)
end

function _browser_op(op::StrokeOp)
    style = (color=_svgHex(op.paint.color), alpha=_svgSolidOpacity(op.paint), width=op.width,
             cap=op.cap === RoundCap ? "round" : op.cap === SquareCap ? "square" : "butt",
             join=op.join === RoundJoin ? "round" : op.join === BevelJoin ? "bevel" : "miter",
             miterLimit=op.miterLimit)
    return (; kind="stroke", _browser_path(op.path, op.tform, NonZero)..., style)
end

_browser_op(op::GroupStart) = (kind="push", alpha=op.opacity)
_browser_op(op::GroupEnd) = (kind="pop", clips=[_browser_path(c.path,c.transform,c.windingRule) for c in op.clips])

"""Encode a crop once in the straight-alpha format accepted by browser ImageData."""
function _browser_pixels(image)
    # ImageData takes straight RGBA. The source image owns premultiplied bytes.
    bytes = Vector{UInt8}(undef, length(image.data))
    for (i, pixel) in enumerate(image)
        c = toStraightAlpha(pixel)
        k = 4i - 3
        bytes[k], bytes[k+1], bytes[k+2], bytes[k+3] = c.r, c.g, c.b, c.a
    end
    return base64encode(bytes)
end

function _browser_scene(scene::Union{Frame,Canvas},crops=DocumentCrops(),images=IdDict{Image,String}())
    frame = scene isa Canvas ? snapshot(scene) : scene
    picture, _ = _document_picture(frame, RenderPolicy(),crops)
    _svgPreScan(picture)
    operations = map(picture.ops) do op
        op isa DocumentImageOp || return _browser_op(op)
        pixels = get!(() -> _browser_pixels(op.image),images,op.image)
        (;kind="image",width=op.image.width,height=op.image.height,data=pixels,
          sampling=op.sampling,matrix=_browser_matrix(op.imageMat))
    end
    return (;size=Int.(frame.size),operations)
end

function _browser_scene(path::AbstractString, julia::AbstractString)
    if endswith(path, ".jl")
        return mktempdir() do dir
            wire = joinpath(dir, "scene.vtrw")
            author = """
                using Vellum
                scene = Base.include(Main, ARGS[1])
                frame = scene isa Canvas ? snapshot(scene) : scene
                frame isa Frame || throw(ArgumentError("author file must return a Canvas or Frame"))
                write(ARGS[2], Wire.encode_snapshot(frame))
                """
            project = something(Base.active_project(), Base.pkgdir(@__MODULE__))
            run(`$julia --startup-file=no --project=$project -e $author -- $path $wire`)
            _browser_scene(wire, julia)
        end
    end
    state = Wire.decode_snapshot(read(path))
    try
        return _browser_scene(state.frame)
    finally
        close(state)
    end
end

"""Compile the gallery's scene command streams to a single WebAssembly module in process.
Each scene references immutable length-prefixed drawing commands shared in linear memory.
The host import consumes one draw command at a time in paint order."""
function _browser_wasm(scenes, transitions=nothing)
    data = IOBuffer()
    entries = IOBuffer()
    if transitions !== nothing
        states,actions = size(transitions)
        for s in 1:states, a in 1:actions
            write(data,htol(UInt32(transitions[s,a]-1)))
        end
        print(entries, "(global \$state (mut i32) (i32.const 0))",
            "(func (export \"current\") (result i32) (global.get \$state))",
            "(func (export \"dispatch\") (param \$action i32) (result i32)",
            "(if (i32.lt_u (local.get \$action) (i32.const $actions)) (then ",
            "(global.set \$state (i32.load (i32.mul (i32.const 4) (i32.add (local.get \$action) ",
            "(i32.mul (global.get \$state) (i32.const $actions)))))))) (global.get \$state))")
    end
    records = Dict{Any,UInt32}()
    for (index, scene) in enumerate(scenes)
        offsets = map(scene.operations) do op
            get!(records,op) do
                offset = UInt32(position(data))
                bytes = codeunits(JSON.json(op))
                write(data,htol(UInt32(length(bytes))),bytes)
                offset
            end
        end
        offset = position(data)
        foreach(p -> write(data,htol(p)),offsets)
        position(data) <= typemax(Int32) || throw(ArgumentError("browser scene exceeds 2 GiB"))
        println(entries, "(func (export \"scene$index\") i32.const $offset i32.const ",
                length(scene.operations), " call \$render)")
    end
    bytes = take!(data)
    wat = IOBuffer()
    println(wat, "(module (import \"vellum\" \"draw\" (func \$draw (param i32 i32)))")
    println(wat, "(memory (export \"memory\") ", cld(length(bytes), 65536), ")")
    print(wat, "(data (i32.const 0) \"")
    for byte in bytes
        # WAT byte strings accept printable ASCII other than quote and backslash.
        if 0x20 <= byte <= 0x7e && !(byte in (0x22, 0x5c))
            write(wat, byte)
        else
            print(wat, '\\', string(byte, base=16, pad=2))
        end
    end
    println(wat, "\")")
    print(wat, raw"""
        (func $render (param $p i32) (param $n i32) (local $record i32)
          (block $done (loop $next
            (br_if $done (i32.eqz (local.get $n)))
            (local.set $record (i32.load align=1 (local.get $p)))
            (local.set $p (i32.add (local.get $p) (i32.const 4)))
            (call $draw (i32.add (local.get $record) (i32.const 4)) (i32.load align=1 (local.get $record)))
            (local.set $n (i32.sub (local.get $n) (i32.const 1)))
            (br $next))))
        """)
    write(wat, take!(entries), ")")
    return _wat2wasm(String(take!(wat)))
end

"""
    feedback_action(controls, control, phase) -> Int

Return the one-based action column for a visual interaction. Use
`(0, :idle)` when the pointer and keyboard leave the controls, or
`(index, :hover | :press | :focus)` for an active control. The last
column, `(0, :tick)`, advances a timed animation. These columns follow
the controls' regular activation actions.
"""
function feedback_action(controls,control::Integer,phase::Symbol)
    base = sum(c.steps for c in controls)
    control == 0 && phase === :idle && return base+1
    control == 0 && phase === :tick && return base+2+3length(controls)
    control in eachindex(controls) || throw(ArgumentError("unknown feedback control"))
    index = findfirst(==(phase),(:hover,:press,:focus))
    isnothing(index) && throw(ArgumentError("unknown feedback phase"))
    return base+1+3(control-1)+index
end

"""
    InteractiveDrawing(title, frames, controls, transitions, values; timers, feedback=false)

Describe a finite interactive drawing shared by browser and native hosts.
Each frame has the same logical size. Each control supplies a label, kind
(`:button`, `:switch`, `:range` or `:segments`), logical rectangle `(x,y,w,h)` and number
of actions (`steps`). Buttons and switches each send one action. A range
sends one action per stop, ordered left to right. Segments also provide a
`labels` collection with an accessible name for each choice. Row one is the initial state.
`transitions[state, action]` gives the next one-based frame index.
`values[state, control]` gives the visible one-based range stop or switch
value (1 off, 2 on). Use 1 for ordinary buttons. Optional `timers` entries
give a delay in milliseconds and a one-based action for each state. The pair
`(0,0)` holds a state until the next user input. Set `feedback=true` to
receive hover, press, keyboard focus and idle actions. Use `feedback_action`
to address their columns and the shared animation tick.
"""
struct InteractiveDrawing
    title::String
    frames::Vector{Frame}
    controls::Vector{NamedTuple}
    transitions::Matrix{Int}
    values::Matrix{Int}
    timers::Vector{Tuple{Int,Int}}
    feedback::Bool
    function InteractiveDrawing(title,frames,controls,transitions,values;timers=fill((0,0),length(frames)),feedback::Bool=false)
        frames = collect(Frame,frames)
        controls = collect(NamedTuple,controls)
        !isempty(frames) && !isempty(controls) || throw(ArgumentError("expected frames and controls"))
        width,height = first(frames).size
        all(f -> f.size == (width,height),frames) || throw(ArgumentError("frame extents must agree"))
        size(values) == (length(frames),length(controls)) || throw(DimensionMismatch("control values"))
        for (i,c) in pairs(controls)
            c.kind in (:button,:switch,:range,:segments) && c.label isa AbstractString && !isempty(c.label) ||
                throw(ArgumentError("invalid control kind or label"))
            c.steps isa Integer && (c.kind in (:range,:segments) ? c.steps >= 2 : c.steps == 1) ||
                throw(ArgumentError("invalid control steps"))
            if c.kind === :segments
                hasproperty(c,:labels) && length(c.labels) == c.steps &&
                    all(s -> s isa AbstractString && !isempty(s),c.labels) ||
                    throw(ArgumentError("expected a label for each segment"))
            end
            x,y,w,h = c.rect
            0 <= x < x+w <= width && 0 <= y < y+h <= height || throw(ArgumentError("invalid control extent"))
            maxvalue = c.kind === :switch ? 2 : c.steps
            all(v -> v isa Integer && 1 <= v <= maxvalue,view(values,:,i)) || throw(ArgumentError("invalid value"))
        end
        actions = feedback ? feedback_action(controls,0,:tick) : sum(c.steps for c in controls)
        size(transitions) == (length(frames),actions) || throw(DimensionMismatch("transitions"))
        all(i -> i isa Integer && i in eachindex(frames),transitions) || throw(ArgumentError("invalid destination"))
        length(timers) == length(frames) || throw(DimensionMismatch("state timers"))
        all(t -> t isa Tuple{Integer,Integer} && (t == (0,0) ||
            (1 <= t[1] <= typemax(Int32) && 1 <= t[2] <= size(transitions,2))),timers) ||
            throw(ArgumentError("expected a delay in milliseconds and a valid action"))
        new(title,frames,controls,transitions,values,timers,feedback)
    end
end

"""
    wasm_module(drawing::InteractiveDrawing) -> Vector{UInt8}

Compile a portable module with linear memory, `current()`, `dispatch(action)`
and a drawing entry point `sceneN()` per frame. The integer state and action
ABI is zero-based. Scene export names begin at 1. Supply the host import
`vellum.draw(offset, byte_count)` to consume each UTF-8 drawing command.
"""
function wasm_module(drawing::InteractiveDrawing)
    # Input states can share the very same immutable frame while awaiting different events.
    cache = IdDict{Frame,NamedTuple}()
    crops = DocumentCrops()
    images = IdDict{Image,String}()
    scenes = map(drawing.frames) do frame
        get!(() -> _browser_scene(frame,crops,images),cache,frame)
    end
    return _browser_wasm(scenes,drawing.transitions)
end

"""Record a keyboard focus indicator for a control without custom feedback graphics."""
function _control_focus(size,control)
    x,y,w,h = control.rect
    drawing(;size) do e
        inset = min(2,w/4,h/4)
        path = rectangle_path(x+inset,y+inset,w-2inset,h-2inset)
        for (color,width) in ((Solid(1,1,1),3),(Solid(0.15,0.36,0.45),1.5))
            configure!(e;stroke=color,stroke_style=StrokeStyle(;width,join=:round))
            draw(e,path;mode=:stroke)
        end
    end
end

"""Write a standalone browser application with keyboard and pointer controls. Set `module_path` to also save its exact Wasm binary."""
function savehtml(path::AbstractString, app::InteractiveDrawing; target=:canvas,module_path=nothing)
    target in (:canvas,:webgl2,:webgpu,:compare) || throw(ArgumentError("unsupported browser target"))
    output = abspath(path)
    !isempty(path) && !isdir(output) || throw(ArgumentError("expected an HTML file path"))
    if !isnothing(module_path)
        abspath(module_path) != output && !isdir(module_path) || throw(ArgumentError("expected a distinct Wasm file path"))
    end
    targets = target === :compare ? [:canvas,:webgl2,:webgpu] : [target]
    sizes = [Int.(frame.size) for frame in app.frames]
    inputs = app.feedback ? [(hover=feedback_action(app.controls,i,:hover)-1,
        press=feedback_action(app.controls,i,:press)-1,focus=feedback_action(app.controls,i,:focus)-1) for i in eachindex(app.controls)] : []
    focus_marks = app.feedback ? [] : [_browser_scene(_control_focus(first(sizes),c)).operations for c in app.controls]
    config = (;title=app.title,controls=app.controls,values=[collect(row) for row in eachrow(app.values)],app.timers,focus_marks,
              feedback=inputs,idle=app.feedback ? feedback_action(app.controls,0,:idle)-1 : -1)
    wasm = wasm_module(app)
    mktemp(dirname(output)) do tmp,io
        _write_browser_html(io,string.(eachindex(sizes)),sizes,targets,wasm;interaction=config)
        close(io)
        Base.Filesystem.rename(tmp,output)
    end
    isnothing(module_path) || write(module_path,wasm)
    return String(path)
end

"""
    savehtml(path, source; target=:canvas, julia=Base.julia_cmd().exec[1])

Write a standalone interactive HTML viewer with an embedded WebAssembly scene module.
Accept a Frame, Canvas, named gallery of 1–8 scenes, Wire snapshot, or trusted Julia
author file returning a Frame or Canvas. Only author files launch a Julia subprocess.
Targets are `:canvas`, `:webgl2`, `:webgpu` and `:compare`. Each requests its
own browser renderer. Unsupported scene operations raise before publication.
"""
function savehtml(path::AbstractString, source::Union{AbstractString,Frame,Canvas,NamedTuple};
                  target=:canvas, julia=Base.julia_cmd().exec[1])
    target in (:canvas, :webgl2, :webgpu, :compare) || throw(ArgumentError("unsupported browser target $target"))
    julia isa AbstractString && !isempty(julia) || throw(ArgumentError("expected a Julia executable path"))
    output = abspath(path)
    !isempty(path) && !isdir(output) || throw(ArgumentError("expected an HTML file path"))
    if source isa NamedTuple
        1 <= length(source) <= 8 || throw(ArgumentError("a gallery must contain 1–8 scenes"))
        labels = collect(string.(keys(source)))
        all(l -> isvalid(l) && 0 < ncodeunits(l) <= 80 && all(!iscntrl,l),labels) ||
            throw(ArgumentError("invalid gallery label"))
        all(s -> s isa Union{Frame,Canvas}, source) || throw(ArgumentError("expected frames or canvases"))
        scenes = map(_browser_scene, values(source))
    elseif source isa AbstractString
        (endswith(source, ".jl") || endswith(source, ".vtrw")) && isfile(source) ||
            throw(ArgumentError("expected an existing .jl author file or .vtrw snapshot"))
        isfile(output) && Base.samefile(source, output) && throw(ArgumentError("input and output coincide"))
        labels, scenes = [splitext(basename(source))[1]], [_browser_scene(abspath(source), julia)]
    else
        labels, scenes = ["Scene"], [_browser_scene(source)]
    end
    wasm = _browser_wasm(scenes)
    targets = target === :compare ? [:canvas,:webgl2,:webgpu] : [target]
    mktemp(dirname(output)) do tmp, io
        _write_browser_html(io, labels, map(s -> s.size, scenes), targets, wasm)
        close(io)
        Base.Filesystem.rename(tmp, output)
    end
    return String(path)
end
