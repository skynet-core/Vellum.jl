import Libdl, Wasmtime_jll
import JSON

"""Validate a module with Wasmtime and read its named exports through the standard Wasm C API."""
function wasm_export_names(bytes)
    Libdl.dlopen(Vellum._wasmtime_library()) do lib
        engine = ccall(Libdl.dlsym(lib,:wasm_engine_new),Ptr{Cvoid},())
        mod = Ref{Ptr{Cvoid}}(C_NULL)
        exports = Ref(Vellum._WasmBytes(0,C_NULL))
        try
            # Read Wasmtime's export-type vector before releasing the compiled module.
            err = ccall(Libdl.dlsym(lib,:wasmtime_module_new),Ptr{Cvoid},
                        (Ptr{Cvoid},Ptr{UInt8},Csize_t,Ref{Ptr{Cvoid}}),engine,bytes,length(bytes),mod)
            if err != C_NULL
                ccall(Libdl.dlsym(lib,:wasmtime_error_delete),Cvoid,(Ptr{Cvoid},),err)
                error("Wasmtime rejected the emitted module")
            end
            ccall(Libdl.dlsym(lib,:wasmtime_module_exports),Cvoid,(Ptr{Cvoid},Ref{Vellum._WasmBytes}),mod[],exports)
            types = unsafe_wrap(Vector{Ptr{Cvoid}},Ptr{Ptr{Cvoid}}(exports[].data),exports[].size)
            return Set(map(types) do type
                ptr = ccall(Libdl.dlsym(lib,:wasm_exporttype_name),Ptr{Vellum._WasmBytes},(Ptr{Cvoid},),type)
                name = unsafe_load(ptr)
                unsafe_string(name.data,name.size)
            end)
        finally
            ccall(Libdl.dlsym(lib,:wasm_exporttype_vec_delete),Cvoid,(Ref{Vellum._WasmBytes},),exports)
            mod[] == C_NULL || ccall(Libdl.dlsym(lib,:wasmtime_module_delete),Cvoid,(Ptr{Cvoid},),mod[])
            ccall(Libdl.dlsym(lib,:wasm_engine_delete),Cvoid,(Ptr{Cvoid},),engine)
        end
    end
end

"""Exercise a scene module in Wasmtime with a test host that counts drawing commands."""
function test_wasm_controls()
    frames = [drawing(size=(8,8)) do e
        rectangle!(e,0,0,8,8;fill=Solid(value,0,0))
    end for value in (0,1)]
    controls = [(kind=:switch,label="Power",steps=1,rect=(0,0,8,8))]
    destinations = reshape([2,1],2,1)
    values = reshape([1,2],2,1)
    @test_throws ArgumentError InteractiveDrawing("Light",frames,controls,fill(3,2,1),values)
    @test_throws DimensionMismatch InteractiveDrawing("Light",frames,controls,destinations,zeros(Int,1,1))
    @test_throws ArgumentError InteractiveDrawing("Light",frames,controls,destinations,fill(3,2,1))
    app = InteractiveDrawing("Light",frames,controls,destinations,values)
    mktempdir() do dir
        html = joinpath(dir,"controls.html")
        wasm = joinpath(dir,"controls.wasm")
        savehtml(html,app;module_path=wasm)
        embedded = match(r"<script id=module type=application/wasm>([^<]+)</script>",read(html,String))
        @test read(wasm) == base64decode(only(embedded.captures))
        @test_throws ArgumentError savehtml(html,app;module_path=html)
        @test_throws ArgumentError savehtml(html,app;target=:unsupported)
    end
    @test_throws ArgumentError Vellum._wat2wasm("(module invalid)")
    binary = join(string(Char(0x5c),string(b;base=16,pad=2)) for b in wasm_module(app))
    spec = raw"""(module $host (global $calls (mut i32) (i32.const 0))
        (func (export "draw") (param i32 i32) (global.set $calls (i32.add (global.get $calls) (i32.const 1))))
        (func (export "drawn") (result i32) (i32.gt_u (global.get $calls) (i32.const 0))))
    (register "vellum" $host)
    """ * "(module \$app binary \"" * binary * "\")\n" * raw"""
    (assert_return (invoke $app "current") (i32.const 0))
    (assert_return (invoke $app "dispatch" (i32.const 0)) (i32.const 1))
    (assert_return (invoke $app "dispatch" (i32.const -1)) (i32.const 1))
    (invoke $app "scene2")
    (assert_return (invoke $host "drawn") (i32.const 1))
    (assert_return (invoke $app "dispatch" (i32.const 0)) (i32.const 0))
    """
    mktempdir() do dir
        path = joinpath(dir,"controls.wast")
        write(path,spec)
        runtime = get(() -> Wasmtime_jll.wasmtime(), ENV, "VELLUM_WASMTIME_CLI")
        cmd = addenv(`$runtime wast $path`,"XDG_CACHE_HOME"=>dir)
        @test success(run(ignorestatus(cmd)))
    end
end

function test_browser()
    @test Vellum.@browser(-distance) == "(-distance)"
    @testset "Standalone interactive WebAssembly" begin
        test_wasm_controls()
    end
    @testset "Offline WebAssembly galleries" begin
        mktempdir() do dir
            output = joinpath(dir,"viewer.html")
            line = LinearGradient((0,0),(16,0),(GradientStop(0,Color(0,0,0)),GradientStop(1,Color(1,1,1))))
            first = drawing(size=(16,12)) do edit
                rectangle!(edit,0,0,16,12;fill=line)
                with_group(edit;opacity=0.5) do child
                    clip(child,rectangle_path(4,4,3,3))
                    rectangle!(child,0,0,12,12;fill=Solid(1,0,0))
                end
            end
            second = Canvas(size=(9,7))
            glaze = drawing(size=(16,12)) do edit
                tint = LinearGradient((0,0),(16,0),(GradientStop(0,Color(1,0,0,0)),GradientStop(1,Color(0,0,1,0.5))))
                rectangle!(edit,0,0,16,12;fill=tint)
            end
            exported = only(Vellum._browser_scene(glaze).operations)
            @test [stop.color for stop in exported.options.colorStops] == ["#ff000000","#0000ff80"]
            scenes = NamedTuple{(Symbol("</script>"),:second)}((first,second))
            for target in (:canvas,:webgl2,:webgpu,:compare)
                @test savehtml(output,scenes;target) == output
                html = read(output,String)
                config = JSON.parse(match(r"<script id=gallery type=application/json>(.*?)</script>",html).captures[1])
                @test config["labels"] == ["</script>","second"]
                @test config["sizes"] == [[16,12],[9,7]]
                @test config["targets"] == (target === :compare ? ["canvas","webgl2","webgpu"] : [String(target)])
                wasm = base64decode(match(r"<script id=module type=application/wasm>(.*?)</script>",html).captures[1])
                @test wasm[1:8] == [0,97,115,109,1,0,0,0]
                @test wasm_export_names(wasm) == Set(["scene1","scene2","memory"])
            end
            write(output,"previous")
            for input in (NamedTuple(), (;invalid=4), dir, joinpath(dir,"missing.vtrw"))
                @test_throws ArgumentError savehtml(output,input)
                @test read(output,String) == "previous"
            end
            @test_throws ArgumentError savehtml(output,second;target=:unknown)
            @test_throws ArgumentError savehtml(output,second;julia="")
            snapshot_path = joinpath(dir,"input.vtrw")
            write(snapshot_path,Wire.encode_snapshot(first))
            @test_throws ArgumentError savehtml(snapshot_path,snapshot_path)
            @test savehtml(output,snapshot_path) == output
            author = joinpath(dir,"author file.jl")
            write(author, "using Vellum\nCanvas(size=(7,5))\n")
            @test savehtml(output,author) == output
            write(author, "error(\"author failed\")")
            write(output, "previous")
            redirect_stderr(devnull) do
                @test_throws ProcessFailedException savehtml(output,author)
            end
            @test read(output,String) == "previous"
        end
    end
end
