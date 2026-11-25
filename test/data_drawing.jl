"""Check data-driven drawing arithmetic, row order, labels, colors and the shared module interface."""
function test_data_drawing()
    font = FontData("Liberation Sans",read(fontfile))
    layer = drawing_layer(:items) do e,row,model
        x = max(1,row.pos*2+model.offset)
        rectangle!(e,x,2,min(6,row.width),4;fill=row.fill)
        draw_label!(e,row.label,x,23;size=14,fill=0xffffff)
    end
    view = DataDrawing("Test",(48,26),font,[layer])
    model = (offset=1,items=[(pos=0,width=6,fill=0xff0000,label="B8"),
                             (pos=4,width=9,fill=0x00ff00,label="")])
    image = rasterize(drawing(view,model))
    @test image[4,4] == rgbx(255,0,0,255)
    @test image[4,12] == rgbx(0,255,0,255)
    @test image[4,18].a == 0
    @test any(image[y,x].a>128 for x in 1:22,y in 10:24)
    @test isempty(drawing(view,(offset=1,items=[])).nodes)
    @test_throws ArgumentError draw_label!(layer,1,0,0)
    @test_throws ArgumentError savehtml("unused",view;target=:invalid,driver="")
    prog = Vellum.data_program(view)
    @test prog.layers == ["items"]
    @test "pos" in prog.fields && "label" in prog.fields
    @test Set(e.name for e in Wasmtime.exports(Wasmtime.WasmtimeModule(Wasmtime.WasmEngine(),prog.bytes)).wasm_exports)==Set(["render"])
    frames = [drawing(view,model)]
    controls = [(label="Next",kind=:button,rect=(0,0,8,8),steps=1)]
    @test_throws ArgumentError InteractiveDrawing("timed",frames,controls,ones(Int,1,1),ones(Int,1,1);timers=[(-1,1)])
    actions = feedback_action(controls,0,:tick)
    @test_throws DimensionMismatch InteractiveDrawing("feedback",frames,controls,ones(Int,1,1),ones(Int,1,1);feedback=true)
    @test_throws ArgumentError feedback_action(controls,2,:hover)
    @test_throws ArgumentError feedback_action(controls,1,:unknown)
    app = InteractiveDrawing("feedback",frames,controls,ones(Int,1,actions),ones(Int,1,1);feedback=true)
    input = Vellum.GLHost.InputState()
    emptykeys = Set{Int}()
    input_at(x,held,keys=emptykeys;focused=true) = Vellum.GLHost.input_actions!(input,app,1,x,4,held,keys;focused)
    column(phase) = feedback_action(controls,1,phase)
    @test input_at(4,false) == [column(:hover)]
    @test input_at(4,true) == [column(:press)]
    @test isempty(input_at(4,true))
    @test input_at(16,true) == [feedback_action(controls,0,:idle)]
    @test isempty(input_at(16,false))
    @test input_at(4,true) == [column(:press)]
    @test input_at(4,false) == [column(:hover),1]
    @test input_at(16,false,Set([258])) == [column(:focus)]
    @test input_at(16,false,Set([32])) == [column(:press)]
    @test input_at(16,false) == [column(:focus),1]
    @test input_at(16,false;focused=false) == [feedback_action(controls,0,:idle)]
end
