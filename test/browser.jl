using Wasmtime
import JSON

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
    engine = Wasmtime.WasmEngine()
    store = Wasmtime.WasmtimeStore(engine)
    linker = Wasmtime.WasmtimeLinker(engine)
    hostcode = raw"""(module (global $calls (mut i32) (i32.const 0))
        (func (export "draw") (param i32 i32) (global.set $calls (i32.add (global.get $calls) (i32.const 1))))
        (func (export "count") (result i32) (global.get $calls)))"""
    host = Wasmtime.WasmtimeInstance(store,Wasmtime.WasmtimeModule(engine,Wasmtime.wat2wasm(hostcode)))
    err = Wasmtime.LibWasmtime.wasmtime_linker_define_instance(linker,store,"vellum",6,host)
    @test err == C_NULL
    exports = Wasmtime.exports(Wasmtime.WasmtimeInstance(linker,store,Wasmtime.WasmtimeModule(engine,wasm_module(app))))
    @test exports.current() == 0
    @test exports.dispatch(Int32(0)) == 1
    @test exports.dispatch(Int32(-1)) == 1
    exports.scene2()
    @test Wasmtime.exports(host).count() > 0
    @test exports.dispatch(Int32(0)) == 0
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
                engine = Wasmtime.WasmEngine()
                mod = Wasmtime.WasmtimeModule(engine, wasm)
                @test Set(e.name for e in Wasmtime.exports(mod).wasm_exports) == Set(["scene1","scene2","memory"])
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
