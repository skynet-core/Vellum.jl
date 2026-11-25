# Julia-authored host bindings for browser input and Wasm display lists.
"""Choose a backing resolution for vector edges. Limit extra samples to 8 megapixels and 8192 pixels per side, while preserving the display's native density."""
const _browser_sampling = @browser size -> begin
    @var native = Math.max(1,window.devicePixelRatio || 1)
    return Math.max(native,Math.min(2*native,8192/Math.max(size[0],size[1]),Math.sqrt(8388608/(size[0]*size[1]))))
end

"""Redraw on display density changes, including moving a window between monitors."""
const _browser_watch_density = @browser redraw -> begin
    @var density = window.devicePixelRatio
    @var changed = () -> begin
        if density !== window.devicePixelRatio
            density = window.devicePixelRatio
            redraw()
        end
    end
    @var watch = () -> begin
        @var query = window.matchMedia("(resolution: "+window.devicePixelRatio+"dppx)")
        query.addEventListener("change",() -> begin
            watch()
            changed()
        end,d(once=true))
    end
    window.addEventListener("resize",changed)
    watch()
end

"""Hit-test the drawing in logical coordinates. Mouse, pen and touch events belong to the canvas."""
const _browser_controls = @browser (stage,app,size,activate,redraw) -> begin
    @var canvas = stage.renderer.canvas
    @var offset = 0
    @var offsets = []
    @var hover = -1
    @var held = -1
    @var focus = -1
    @var key = ""
    @var pointer = -1
    @var last = app.idle
    @var update = () -> begin
        if app.feedback.length > 0
            @var action = app.idle
            if held >= 0 && (held === hover || key !== "")
                action = app.feedback[held].press
            elseif focus >= 0
                action = app.feedback[focus].focus
            elseif hover >= 0
                action = app.feedback[hover].hover
            end
            if action !== last
                last = action
                activate(action)
            end
        elseif focus !== stage.focus
            stage.focus = focus
            redraw(stage)
        end
    end
    @var locate = event -> begin
        @var bounds = canvas.getBoundingClientRect()
        @var x = (event.clientX-bounds.left)*size[0]/bounds.width
        @var y = (event.clientY-bounds.top)*size[1]/bounds.height
        @var i = app.controls.findIndex(c->begin
            @var r = c.rect
            return r[0] <= x && x < r[0]+r[2] && r[1] <= y && y < r[1]+r[3]
        end)
        return d(i=i,x=x)
    end
    @var stopAt = (c,x) -> begin
        @var f = Math.max(0,Math.min(1,(x-c.rect[0])/c.rect[2]))
        return c.kind === "segments" ? Math.min(c.steps-1,Math.floor(f*c.steps)) : Math.round(f*(c.steps-1))
    end
    @var drag = x -> begin
        if held >= 0 && app.controls[held].kind === "range"
            activate(offsets[held]+stopAt(app.controls[held],x))
        end
    end
    stage.inputs = []
    stage.focus = -1
    canvas.setAttribute("aria-label",app.title)
    canvas.addEventListener("pointermove",event -> begin
        if event.isPrimary
            @var point = locate(event)
            hover = point.i
            if pointer === event.pointerId
                if event.pointerType === "mouse" && event.buttons === 0
                    held = -1
                    pointer = -1
                else
                    drag(point.x)
                end
            end
            update()
        end
    end)
    canvas.addEventListener("pointerleave",() -> begin
        hover = -1
        update()
    end)
    canvas.addEventListener("pointerdown",event -> begin
        if event.button === 0 && event.isPrimary
            @var point = locate(event)
            focus = -1
            key = ""
            held = point.i
            hover = held
            if held >= 0
                event.preventDefault()
                pointer = event.pointerId
                canvas.setPointerCapture(pointer)
                @var c = app.controls[held]
                @var el = stage.inputs[held]
                @var target = c.kind === "segments" ? el.children[stopAt(c,point.x)] : el
                target.focus(d(preventScroll=true))
                drag(point.x)
            end
            update()
        end
    end)
    window.addEventListener("pointerup",event -> begin
        if pointer === event.pointerId
            @var point = locate(event)
            @var i = held
            pointer = -1
            held = -1
            hover = event.pointerType === "touch" ? -1 : point.i
            update()
            if point.i === i && i >= 0 && app.controls[i].kind !== "range"
                activate(offsets[i]+stopAt(app.controls[i],point.x))
            end
        end
    end)
    @var clear = () -> begin
        hover = -1
        held = -1
        focus = -1
        pointer = -1
        key = ""
        update()
    end
    canvas.addEventListener("pointercancel",clear)
    canvas.addEventListener("lostpointercapture",event -> begin
        if pointer === event.pointerId
            clear()
        end
    end)
    window.addEventListener("blur",clear)

    # Canvas fallback descendants expose semantics and keyboard actions to the
    # accessibility tree. They have no layout boxes and receive no pointer hits.
    app.controls.forEach((c,i) -> begin
        @var start = offset
        offsets.push(start)
        offset = offset + c.steps
        @var range = c.kind === "range"
        @var segments = c.kind === "segments"
        @var el = document.createElement(range ? "input" : (segments ? "div" : "button"))
        el.setAttribute("aria-label",c.label)
        if range
            el.type = "range"
            el.min = 1
            el.max = c.steps
            el.addEventListener("input",() -> activate(start+Number(el.value)-1))
        elseif segments
            el.setAttribute("role","radiogroup")
            c.labels.forEach((label,j) -> begin
                @var choice = document.createElement("button")
                choice.setAttribute("role","radio")
                choice.setAttribute("aria-label",label)
                choice.addEventListener("click",() -> activate(start+j))
                choice.addEventListener("keydown",event -> begin
                    if event.key === "ArrowRight" || event.key === "ArrowLeft"
                        event.preventDefault()
                        @var next = event.key === "ArrowRight" ? j+1 : j-1
                        next = next < 0 ? c.steps-1 : (next >= c.steps ? 0 : next)
                        el.children[next].focus()
                        activate(start+next)
                    end
                end)
                el.appendChild(choice)
            end)
        else
            if c.kind === "switch"
                el.setAttribute("role","switch")
            end
            el.addEventListener("click",() -> activate(start))
        end
        el.addEventListener("focusin",event -> begin
            if pointer < 0 && event.target.matches(":focus-visible")
                focus = i
                update()
            end
        end)
        el.addEventListener("focusout",() -> begin
            if focus === i
                focus = -1
                if key !== ""
                    held = -1
                    key = ""
                end
                update()
            end
        end)
        el.addEventListener("keydown",event -> begin
            if event.key === "Escape"
                clear()
            elseif el.tagName === "BUTTON" && (event.key === " " || event.key === "Enter")
                event.preventDefault()
                if !event.repeat
                    focus = i
                    held = i
                    key = event.key
                    update()
                end
            end
        end)
        el.addEventListener("keyup",event -> begin
            if event.key === key && held === i
                event.preventDefault()
                held = -1
                key = ""
                update()
                el.click()
            end
        end)
        stage.inputs.push(el)
        canvas.appendChild(el)
    end)
end

"""Instantiate the gallery module and replay its scene and keyboard focus display lists on each device."""
const _browser_start = @browser () -> begin
    @var gallery = JSON.parse(document.getElementById("gallery").textContent)
    @var bytes = Uint8Array.from(atob(document.getElementById("module").textContent), c -> c.charCodeAt(0))
    @var select = document.querySelector("select")
    if select
        gallery.labels.forEach(label -> select.add(@new Option(label)))
    end
    @var decoder = @new TextDecoder()
    @var program = nothing
    @var stages = []
    @var decoded = @new Map()
    @var meshes = @new Map()
    @var emit = nothing
    @var draw = (offset, size) -> begin
        if !decoded.has(offset)
            @var cmd = @new Uint8Array(program.memory.buffer,offset,size)
            @var op = JSON.parse(decoder.decode(cmd))
            if op.mesh
                @var bytes = op.mesh
                @var key = String(bytes.address)+"/"+String(bytes.count)
                if !meshes.has(key)
                    meshes.set(key,@new(Float32Array(program.memory.buffer,bytes.address,bytes.count)))
                end
                op.mesh = meshes.get(key)
            end
            if op.kind==="image"
                op.data = @new Uint8Array(program.memory.buffer,op.data.address,op.data.count)
            end
            decoded.set(offset,op)
        end
        emit(decoded.get(offset))
    end
    @var show = stage -> begin
        @var index = gallery.interaction ? program.current() : select.selectedIndex
        @var size = gallery.sizes[index]
        if !stage.cache[index]
            # The retained plan refers to the module's immutable display list. The module
            # replays it on every presentation. Prepared device resources survive replay.
            stage.cache[index] = visit -> begin
                emit = op->visit(stage.renderer.prepare(op))
                program["scene"+(index+1)]()
            end
            stage.panel.dataset.recordings = String(Number(stage.panel.dataset.recordings || 0)+1)
        end
        stage.renderer.resize(size[0],size[1],sampling(size))
        stage.renderer.render(visit->begin
            stage.cache[index](visit)
            if stage.focus >= 0 && gallery.interaction && gallery.interaction.feedback.length === 0
                program["focus"+(stage.focus+1)]()
            end
        end)
        stage.panel.dataset.scene = gallery.labels[index]
        if gallery.interaction
            stage.inputs.forEach((el,i) -> begin
                @var value = gallery.interaction.values[index][i]
                if el.type === "range"
                    el.value = value
                elseif el.getAttribute("role") === "radiogroup"
                    Array.from(el.children).forEach((choice,j) -> begin
                        choice.setAttribute("aria-checked",String(value === j+1))
                        choice.tabIndex = value === j+1 ? 0 : -1
                    end)
                else
                    if el.getAttribute("role") === "switch"
                        el.setAttribute("aria-checked",String(value === 2))
                    end
                end
            end)
        end
        stage.panel.dataset.state = "ready"
        stage.status.textContent = ""
    end
    @var failed = (stage, error) -> begin
        stage.panel.dataset.state = "error"
        stage.status.textContent = String(error)
    end
    @var display = stage -> Promise.resolve().then(() -> show(stage)).then(undefined, error -> failed(stage,error))
    watchDensity(() -> stages.forEach(display))
    if select
        select.addEventListener("change", () -> stages.forEach(display))
    end
    @var timer = 0
    @var schedule = () -> begin
        clearTimeout(timer)
        if gallery.interaction
            @var item = gallery.interaction.timers[program.current()]
            if item[0]>0
                timer = setTimeout(()->activate(item[1]-1),item[0])
            end
        end
    end
    @var activate = action -> begin
        program.dispatch(action)
        if gallery.interaction.feedback.length > 0 && window.matchMedia("(prefers-reduced-motion: reduce)").matches
            @var seen = @new Set()
            @var settle = () -> begin
                @var state = program.current()
                @var item = gallery.interaction.timers[state]
                if item[0]>0 && !seen.has(state)
                    seen.add(state)
                    program.dispatch(item[1]-1)
                    settle()
                end
            end
            settle()
        end
        stages.forEach(display)
        schedule()
    end
    @var mount = target -> begin
        @var panel = document.getElementById(target)
        @var stage = d(panel=panel,status=panel.querySelector("output"),cache=[],focus=-1)
        openDevice(target).then(renderer -> begin
            stage.renderer = renderer
            panel.querySelector(".drawing").appendChild(renderer.canvas)
            if gallery.interaction
                document.title = gallery.interaction.title
                controls(stage,gallery.interaction,gallery.sizes[0],activate,display)
            end
            stages.push(stage)
            display(stage)
            if stages.length === 1
                schedule()
            end
        end).then(undefined, error -> failed(stage,error))
    end
    WebAssembly.instantiate(bytes, d(vellum=d(draw=draw))).then(result -> begin
        program = result.instance.exports
        gallery.targets.forEach(mount)
    end).then(undefined, error -> begin
        document.getElementById("error").textContent = String(error)
    end)
end

"""Embed Vellum notices and only the first-party device bindings needed by this export."""
function _write_browser_devices(io,targets)
    for name in ("NOTICE","LICENSE")
        print(io,"<script type=text/plain id=vellum-",lowercase(name),">")
        write(io,read(joinpath(pkgdir(Vellum),name)))
        println(io,"</script>")
    end
    print(io,"<script>const surface=",_browser_surface,",openDevice=",_browser_open_device)
    :canvas in targets && print(io,",canvasDevice=",_browser_canvas_device)
    :webgl2 in targets && print(io,",glDevice=",_browser_gl_device)
    :webgpu in targets && print(io,",gpuDevice=",_browser_gpu_device)
    println(io,";</script>")
end

function _write_browser_html(io, labels, sizes, targets, wasm;interaction=nothing)
    config = JSON.json((; labels, sizes, targets, interaction))
    println(io, "<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Vellum viewer</title>")
    if isnothing(interaction)
        println(io,"<label>Scene <select></select></label>")
    else
        println(io,"<style>body{margin:0;padding:clamp(8px,3vw,24px);background:#edf2ee;font:1rem system-ui;color:#172d32}",
            "main{display:grid;gap:1rem;max-width:",first(sizes)[1]+2,"px;margin:auto}section{min-width:0;border:1px solid #d7dfd7;border-radius:16px;overflow:hidden}.drawing{position:relative;width:min(100%,",
            first(sizes)[1],"px)}.drawing canvas{width:100%!important;height:auto!important;display:block;touch-action:none}</style>")
    end
    println(io,"<main>")
    for target in targets
        heading = isnothing(interaction) || length(targets)>1 ? "<h2>$target</h2>" : ""
        println(io, "<section id=\"", target, "\" data-state=\"loading\">",heading,
                "<output aria-live=\"polite\">Loading…</output><div class=drawing></div></section>")
    end
    println(io, "</main><output id=error></output><script id=gallery type=application/json>",
            replace(config, "<"=>"\\u003c"), "</script>")
    println(io, "<script id=module type=application/wasm>", base64encode(wasm), "</script>")
    _write_browser_devices(io,targets)
    println(io, "<script>const sampling=",_browser_sampling,",watchDensity=",_browser_watch_density,
            ",controls=",_browser_controls,";", _browser_start, "();</script>")
end
