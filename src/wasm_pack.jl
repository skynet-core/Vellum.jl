"""
    savehtml(path, source; target=:canvas, julia=Base.julia_cmd().exec[1])::String

Build an offline browser page from a Julia author file, a `.vtrw` Wire
snapshot, a [`Frame`](@ref), a [`Canvas`](@ref), or a named tuple of
1–8 frames or canvases. Named tuple keys are ordered scene labels, each
nonempty, without control characters and at most 80 UTF-8 bytes. The
gallery embeds one compiled viewer and independent snapshots. Choosing a
label opens its already authored scene. Each canvas is snapshotted once.
Return the supplied output path as a `String`.

Use a trusted `.jl` file whose final expression returns a frame or canvas.
The builder executes that file on the host. The browser runs the
Julia-compiled scene reader and supported rendering kernels.

The reference Linux builder requires Julia 1.13.4, Node.js with WasmGC,
Python 3, and the pinned compiler environment. By default, use the
caller's Julia executable. Pass the Julia 1.13.4 path as `julia` when
calling from another version.

Targets are `:canvas` (strict Canvas 2D, the default), `:webgl2`,
`:webgpu`, and `:compare` (the comparison viewer). Strict targets do
not fall back to another renderer. Unsupported scenes, missing build
assets or tools, compiler failures, and filesystem errors are reported;
the existing output is preserved on authoring, validation, or compilation
failure. The input and output must not identify the same file.
"""
function savehtml(path::AbstractString, source::Union{AbstractString,Frame,Canvas,NamedTuple};
                  target=:canvas, julia=Base.julia_cmd().exec[1])
    target in (:canvas, :webgl2, :webgpu, :compare) ||
        throw(ArgumentError("Unsupported target $(repr(target)); choose canvas, webgl2, webgpu, or compare"))
    julia isa AbstractString && !isempty(julia) ||
        throw(ArgumentError("julia must be a nonempty executable path"))
    isempty(path) && throw(ArgumentError("Output must be an HTML file path"))
    output = abspath(path)
    isdir(output) && throw(ArgumentError("Output must be an HTML file path"))
    if source isa NamedTuple
        1 <= length(source) <= 8 || throw(ArgumentError("A gallery must contain 1–8 scenes"))
        for (label, scene) in pairs(source)
            name = String(label)
            isvalid(name) && !isempty(name) && ncodeunits(name) <= 80 && all(!iscntrl, name) ||
                throw(ArgumentError("Scene labels must be nonempty, contain no control characters, and fit in 80 UTF-8 bytes"))
            scene isa Union{Frame,Canvas} || throw(ArgumentError("Gallery scenes must be frames or canvases"))
        end
    elseif source isa AbstractString
        (endswith(source, ".jl") || endswith(source, ".vtrw")) ||
            throw(ArgumentError("Input must be a .jl author file or .vtrw snapshot"))
        input = abspath(source)
        (input == output || (isfile(input) && isfile(output) && Base.samefile(input, output))) &&
            throw(ArgumentError("Input and output must be different files"))
        isfile(input) || throw(ArgumentError("Input file does not exist: $source"))
    end
    root = dirname(@__DIR__)
    builder = joinpath(root, "examples", "wasm-scene-viewer", "build.sh")
    compiler = joinpath(root, "examples", "wasm-bundle-viewer", "wasm", "prepare.sh")
    all(isfile, (builder, compiler, joinpath(root, "examples", "wasm-scene-viewer", "author.jl"),
                 joinpath(root, "examples", "wasm-scene-viewer", "pack.py"))) ||
        throw(ArgumentError("Vetra browser build assets are missing from $root; use a complete source distribution"))

    if source isa AbstractString
        _build_html(builder, input, output, target, julia)
    elseif source isa NamedTuple
        mktempdir() do dir
            for (index, (label, scene)) in enumerate(pairs(source))
                write(joinpath(dir, "$index.label"), String(label))
                frame = scene isa Canvas ? snapshot(scene) : scene
                write(joinpath(dir, "$index.vtrw"), Wire.encode_snapshot(frame))
            end
            _build_html(builder, dir, output, target, julia)
        end
    else
        frame = source isa Canvas ? snapshot(source) : source
        mktempdir() do dir
            input = joinpath(dir, splitext(basename(output))[1] * ".vtrw")
            write(input, Wire.encode_snapshot(frame))
            _build_html(builder, input, output, target, julia)
        end
    end
    return String(path)
end

"""
    _build_html(builder, input, output, target, julia) -> Nothing

Run the bundled builder with separate arguments and the chosen Julia
executable. Wait for publication and propagate command failures.
"""
function _build_html(builder, input, output, target, julia)
    run(addenv(`sh $builder --target $(string(target)) $input $output`, "JULIA" => String(julia)))
    return nothing
end
