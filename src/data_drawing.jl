"""A scalar field or arithmetic expression evaluated for each row of a data-bound drawing layer."""
struct DrawingValue
    op::Symbol
    args::Tuple
end

"""A recording-time reference to the current data row or its enclosing model."""
struct DrawingFields
    scope::Symbol
end

Base.getproperty(row::DrawingFields,name::Symbol) = DrawingValue(getfield(row,:scope),(name,))
for op in (:+,:-,:*,:/,:min,:max)
    @eval begin
        Base.$op(a::DrawingValue,b::Real) = DrawingValue($(QuoteNode(op)),(a,b))
        Base.$op(a::Real,b::DrawingValue) = DrawingValue($(QuoteNode(op)),(a,b))
        Base.$op(a::DrawingValue,b::DrawingValue) = DrawingValue($(QuoteNode(op)),(a,b))
    end
end

"""A collection of ordered drawing commands repeated for each row in a named input collection."""
struct DrawingLayer
    source::Symbol
    commands::Vector{NamedTuple}
end

"""
    drawing_layer(callback, collection)

Record a component once. The callback receives a drawing target, a row and the whole model.
Use row or model fields, numeric constants, arithmetic, min and max for geometry.
The same commands run on each native target and compile into the browser's Wasm module.
"""
function drawing_layer(callback,source::Symbol)
    layer = DrawingLayer(source,NamedTuple[])
    callback(layer,DrawingFields(:row),DrawingFields(:model))
    return layer
end

"""Record a filled rectangle in a data layer. Use a packed sRGB color or a data field for its fill."""
function rectangle!(layer::DrawingLayer,x,y,width,height;fill)
    push!(layer.commands,(kind=:rect,args=(x,y,width,height,fill)))
    return nothing
end

"""Draw a baseline-aligned label from a literal string or a row field using the view's font."""
function draw_label!(layer::DrawingLayer,text,x,y;size=14,fill=0xffffff)
    text isa AbstractString || (text isa DrawingValue && text.op in (:row,:model)) ||
        throw(ArgumentError("a label requires a string or text field"))
    push!(layer.commands,(kind=:label,args=(text,x,y,size,fill)))
    return nothing
end

"""
    DataDrawing(title, size, font, layers)

A reusable drawing of live tabular data. Each named collection supplies an ordered sequence
of rows. Numeric geometry and colors can also refer to scalar fields on the enclosing model.
Labels use the supplied font in each host. Pass a model to `drawing(view, model)` or export
the view with `savehtml` and send models to the browser host's `update` method.
"""
struct DataDrawing
    title::String
    size::NTuple{2,Int}
    font::FontData
    layers::Vector{DrawingLayer}
    function DataDrawing(title,size,font,layers)
        new(title,checked_dimensions(size...),font,collect(DrawingLayer,layers))
    end
end

"""Resolve a recorded coordinate against one data row and its model."""
function drawing_value(v,row,model)
    v isa DrawingValue || return v
    v.op === :row && return getproperty(row,only(v.args))
    v.op === :model && return getproperty(model,only(v.args))
    a,b = v.args
    return getfield(Base,v.op)(drawing_value(a,row,model),drawing_value(b,row,model))
end

"""Convert the drawing's packed 24-bit sRGB color to a native paint."""
function data_paint(value)
    n = UInt32(value)
    return Solid(((n>>16)&255)/255,((n>>8)&255)/255,(n&255)/255)
end

"""Materialize a live model as a normal immutable Vellum frame suitable for any supporting backend."""
function drawing(view::DataDrawing,model)
    drawing(;size=view.size) do edit
        font = resource!(edit,:font,view.font)
        for layer in view.layers, row in getproperty(model,layer.source), cmd in layer.commands
            args = map(v -> drawing_value(v,row,model),cmd.args)
            if cmd.kind === :rect
                x,y,w,h,color = args
                w>0 && h>0 && rectangle!(edit,x,y,w,h;fill=data_paint(color))
            else
                text,x,y,px,color = args
                isempty(text) && continue
                configure!(edit;font,font_size=px,fill=data_paint(color))
                capture_text!(edit,text,(x,y))
            end
        end
    end
end

"""Return a stable zero-based index in a module-local field or string table."""
function table_index!(table,value)
    index = findfirst(==(value),table)
    isnothing(index) || return index-1
    push!(table,value)
    return length(table)-1
end

"""Compile a geometry or paint operand to a Wasm numeric expression using a row or model field import."""
function data_expression(v,fields)
    v isa Real && isfinite(v) && return "(f64.const $(Float64(v)))"
    v isa DrawingValue || throw(ArgumentError("invalid drawing coordinate or color"))
    if v.op in (:row,:model)
        field = table_index!(fields,string(only(v.args)))
        scope = v.op===:row ? 0 : 1
        return "(call \$value (local.get \$layer) (local.get \$row) (i32.const $scope) (i32.const $field))"
    end
    names = (:+ => "add",:- => "sub",:* => "mul",:/ => "div",:min => "min",:max => "max")
    op = last(only(p for p in names if first(p)===v.op))
    return "(f64.$op $(data_expression(v.args[1],fields)) $(data_expression(v.args[2],fields)))"
end

"""Compile the complete data-driven draw loop with named imports for inputs, filled rectangles and labels."""
function data_program(view::DataDrawing)
    fields,strings = String[],String[]
    io = IOBuffer()
    print(io,raw"""(module
      (import "vellum" "count" (func $count (param i32) (result i32)))
      (import "vellum" "value" (func $value (param i32 i32 i32 i32) (result f64)))
      (import "vellum" "rect" (func $rect (param f64 f64 f64 f64 f64)))
      (import "vellum" "label" (func $label (param i32 i32 i32 i32 f64 f64 f64 f64)))
      (func (export "render") (local $layer i32) (local $row i32) (local $n i32)
    """)
    for (i,layer) in pairs(view.layers)
        print(io,"(local.set \$layer (i32.const ",i-1,"))",raw"""
            (local.set $row (i32.const 0)) (local.set $n (call $count (local.get $layer)))
            (block $done (loop $next (br_if $done (i32.ge_u (local.get $row) (local.get $n)))
        """)
        for cmd in layer.commands
            args = cmd.args
            if cmd.kind===:rect
                print(io,"(call \$rect ")
            else
                t = first(args)
                scope = t isa AbstractString ? 2 : t.op===:row ? 0 : 1
                field = t isa AbstractString ? table_index!(strings,String(t)) : table_index!(fields,string(only(t.args)))
                print(io,"(call \$label (local.get \$layer) (local.get \$row) (i32.const $scope) (i32.const $field) ")
                args = Base.tail(args)
            end
            println(io,join((data_expression(v,fields) for v in args)," "),")")
        end
        println(io,raw"(local.set $row (i32.add (local.get $row) (i32.const 1))) (br $next)))")
    end
    print(io,"))")
    bytes = _wat2wasm(String(take!(io)))
    return (;bytes,fields,strings,layers=string.([layer.source for layer in view.layers]))
end

"""Build the browser view from the same geometry program as the native drawing and retain display objects across updates."""
const data_viewer = @browser () -> begin
    @var cfg = JSON.parse(document.getElementById("view").textContent)
    @var status = document.querySelector("output")
    @var stage = document.querySelector("main")
    @var root = @new PIXI.Container()
    @var model = nothing
    @var pos = 0
    @var cache = []
    @var renderer = nothing
    @var wasm = nothing
    @var ratio = sampling(cfg.size)
    @var node = kind->begin
        @var entry = cache[pos]
        if !entry || entry.kind !== kind
            if entry
                root.removeChild(entry.shape)
                entry.shape.destroy()
            end
            @var shape = kind==="rect" ? (@new PIXI.Graphics()).rect(0,0,1,1).fill(16777215) :
                @new PIXI.Text(d(text="",style=d(fontFamily="VellumView",fontSize=14,fill=16777215),resolution=ratio))
            root.addChildAt(shape,pos)
            entry = d(kind=kind,shape=shape)
            cache[pos] = entry
        end
        pos = pos+1
        entry.shape.visible = true
        return entry.shape
    end
    @var value = (l,r,scope,f)->(scope===0 ? model[cfg.layers[l]][r] : model)[cfg.fields[f]]
    @var imports = d(count=l->model[cfg.layers[l]].length,value=value,
        rect=(x,y,w,h,color)->begin
            if w>0 && h>0
                @var shape = node("rect")
                shape.position.set(x,y)
                shape.scale.set(w,h)
                shape.tint = color
            end
        end,
        label=(l,r,scope,f,x,y,size,color)->begin
            @var text = scope===2 ? cfg.strings[f] : value(l,r,scope,f)
            if text.length
                @var label = node("label")
                label.text = text
                label.style.fontSize = size
                label.tint = color
                @var metrics = PIXI.CanvasTextMetrics.measureFont(String(size)+"px VellumView")
                label.position.set(x,y-metrics.ascent)
            end
        end)
    @var update = next->begin
        model = next
        pos = 0
        wasm.render()
        cache.slice(pos).forEach(entry->begin
            entry.shape.visible = false
        end)
        renderer.render(root)
        stage.dataset.state = "ready"
    end
    @var font = @new FontFace("VellumView","url(data:font/ttf;base64,"+cfg.font+")")
    @var preference = cfg.target==="webgl2" ? "webgl" : cfg.target
    @var bytes = Uint8Array.from(atob(document.getElementById("module").textContent),c->c.charCodeAt(0))
    Promise.all([font.load(),PIXI.autoDetectRenderer(d(preference=[preference],preferWebGLVersion=2,
        width=cfg.size[0],height=cfg.size[1],resolution=ratio,autoDensity=true,antialias=true)),
        WebAssembly.instantiate(bytes,d(vellum=imports))]).then(results->begin
        document.fonts.add(results[0])
        renderer = results[1]
        if cfg.target==="webgl2" && renderer.context.webGLVersion!==2
            renderer.destroy()
            return Promise.reject("WebGL2 unavailable")
        end
        wasm = results[2].instance.exports
        stage.prepend(renderer.canvas)
        renderer.canvas.tabIndex = 0
        renderer.canvas.setAttribute("aria-label",cfg.title)
        status.textContent = ""
        watchDensity(() -> begin
            ratio = sampling(cfg.size)
            renderer.resize(cfg.size[0],cfg.size[1],ratio)
            cache.forEach(entry -> begin
                if entry.kind === "label"
                    entry.shape.resolution = ratio
                end
            end)
            if model
                update(model)
            end
        end)
        driver(d(canvas=renderer.canvas,stage=stage,update=update,config=cfg.config,size=cfg.size))
    end).catch(err->begin
        stage.dataset.state = "error"
        status.textContent = String(err)
    end)
end

"""
    savehtml(path, view::DataDrawing; driver, config=(;), target=:webgl2, module_path=nothing)

Export a standalone live view. Supply a trusted Julia-authored browser binding as the driver.
Its host has `canvas`, `stage`, `size`, `config` and `update(model)`. A call to update
runs the compiled drawing on fresh data. The only network access is chosen by the driver.
"""
function savehtml(path::AbstractString,view::DataDrawing;driver,config=(;),target=:webgl2,module_path=nothing)
    target in (:webgl2,:webgpu,:canvas) || throw(ArgumentError("unsupported live browser target"))
    module_path!==nothing && abspath(path)==abspath(module_path) && throw(ArgumentError("expected distinct HTML and Wasm paths"))
    program = data_program(view)
    payload = (;view.size,view.title,target,program.fields,program.strings,program.layers,config,
               font=base64encode(codeunits(view.font.data.bytes)))
    mktemp(dirname(abspath(path))) do temp,io
        print(io,"<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><style>",
              "body{margin:0;padding:clamp(4px,2vw,20px);background:#10141d;color:#dae4ef;font:14px system-ui}main{position:relative;max-width:",
              view.size[1],"px;margin:auto}canvas{display:block;width:100%!important;height:auto!important;touch-action:none;cursor:crosshair}</style><main><output aria-live=polite>Loading…</output></main>",
              "<script type=application/json id=view>",replace(JSON.json(payload),"<"=>"\\u003c"),"</script><script type=application/wasm id=module>",
              base64encode(program.bytes),"</script>")
        _write_pixi_runtime(io)
        print(io,"<script>document.title=JSON.parse(document.getElementById('view').textContent).title;const sampling=",_browser_sampling,
              ",watchDensity=",_browser_watch_density,",driver=",driver,";",data_viewer,"();</script></html>")
        close(io)
        Base.Filesystem.rename(temp,abspath(path))
    end
    isnothing(module_path) || write(module_path,program.bytes)
    return String(path)
end
