# Julia expressions for DOM, WebAssembly and PixiJS bindings.
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

"""Fill compound contours in one native Path2D operation to preserve glyph counters and winding rules."""
const _browser_compound = @browser (op,shape,size,ratio) -> begin
    @var bounds = shape.getBounds()
    @var left = Math.max(0,Math.floor(bounds.minX)-1)
    @var top = Math.max(0,Math.floor(bounds.minY)-1)
    @var width = Math.min(size[0],Math.ceil(bounds.maxX)+1)-left
    @var height = Math.min(size[1],Math.ceil(bounds.maxY)+1)-top
    if width <= 0 || height <= 0
        return @new PIXI.Container()
    end
    @var buffer = document.createElement("canvas")
    buffer.width = Math.ceil(width*ratio)
    buffer.height = Math.ceil(height*ratio)
    @var ctx = buffer.getContext("2d")
    @var m = op.matrix
    ctx.setTransform(ratio*m[0],ratio*m[1],ratio*m[2],ratio*m[3],ratio*(m[4]-left),ratio*(m[5]-top))
    if op.kind === "gradient"
        @var a = op.options.start
        @var b = op.options.end
        @var gradient = ctx.createLinearGradient(a.x,a.y,b.x,b.y)
        op.options.colorStops.forEach(s -> gradient.addColorStop(s.offset,s.color))
        ctx.fillStyle = gradient
        ctx.globalAlpha = op.alpha
    else
        ctx.fillStyle = op.style ? op.style.color : "white"
        ctx.globalAlpha = op.style ? op.style.alpha : 1
    end
    ctx.fill(@new(Path2D(op.path)),op.evenodd ? "evenodd" : "nonzero")
    @var sprite = @new PIXI.Sprite(PIXI.Texture.from(buffer))
    sprite.position.set(left,top)
    sprite.scale.set(1/ratio)
    return sprite
end

const _browser_graphic = @browser (op,size,ratio) -> begin
    @var shape = @new PIXI.Graphics()
    @var path = @new PIXI.GraphicsPath(op.path, op.evenodd)
    shape.path(path)
    @var m = op.matrix
    shape.setFromMatrix(@new PIXI.Matrix(m[0],m[1],m[2],m[3],m[4],m[5]))
    if op.kind === "stroke"
        shape.stroke(op.style)
    else
        if op.kind === "gradient"
            # Build the ramp in increasing texture coordinates. Pixi 8.18's clamp
            # path mirrors one axis when a diagonal gradient has mixed signs.
            @var a = op.options.start
            @var b = op.options.end
            @var dx = b.x-a.x
            @var dy = b.y-a.y
            @var span = Math.hypot(dx,dy)
            @var options = Object.assign(d(),op.options)
            options.start = d(x=0,y=0)
            options.end = d(x=1,y=0)
            @var ramp = @new PIXI.FillGradient(options)
            ramp.buildGradient()
            @var width = ramp.texture.source.pixelWidth
            ramp.transform.set(dx/width,dy/width,(0-dy)/span,dx/span,a.x,a.y)
            shape.fill(ramp)
            shape.alpha = op.alpha
        else
            shape.fill(op.style || 16777215)
        end
    end
    if op.compound && op.kind !== "stroke"
        @var sprite = compound(op,shape,size,ratio)
        shape.destroy()
        return sprite
    end
    return shape
end

const _browser_sprite = @browser op -> begin
    @var canvas = document.createElement("canvas")
    canvas.width = op.width
    canvas.height = op.height
    @var bytes = Uint8ClampedArray.from(atob(op.data), ch -> ch.charCodeAt(0))
    canvas.getContext("2d").putImageData(@new(ImageData(bytes,op.width,op.height)),0,0)
    @var texture = PIXI.Texture.from(canvas)
    texture.source.scaleMode = op.sampling
    @var image = @new PIXI.Sprite(texture)
    @var m = op.matrix
    image.setFromMatrix(@new PIXI.Matrix(m[0],m[1],m[2],m[3],m[4],m[5]))
    return image
end

const _browser_end_group = @browser (stack,op,size,ratio) -> begin
    @var node = stack.pop()
    if node.alpha < 1
        node.cacheAsTexture(d(resolution=ratio,antialias=true))
    end
    op.clips.forEach(c -> begin
        @var mask = graphic(c,size,ratio)
        @var wrapper = @new PIXI.Container()
        wrapper.addChild(node, mask)
        node.mask = mask
        node = wrapper
    end)
    stack[stack.length-1].addChild(node)
end

const _browser_execute = @browser (stack,op,size,ratio) -> begin
    @var parent = stack[stack.length-1]
    @var node = nothing
    if op.kind === "push"
        node = @new PIXI.Container()
        node.alpha = op.alpha
        stack.push(node)
    else
        if op.kind === "pop"
            endGroup(stack,op,size,ratio)
        else
            parent.addChild(op.kind === "image" ? sprite(op) : graphic(op,size,ratio))
        end
    end
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

const _browser_start = @browser () -> begin
    @var gallery = JSON.parse(document.getElementById("gallery").textContent)
    @var bytes = Uint8Array.from(atob(document.getElementById("module").textContent), c -> c.charCodeAt(0))
    @var select = document.querySelector("select")
    if select
        gallery.labels.forEach(label -> select.add(@new Option(label)))
    end
    @var decoder = @new TextDecoder()
    @var program = nothing
    @var stack = []
    @var stages = []
    @var drawingSize = nothing
    @var decoded = @new Map()
    @var ratio = 1
    @var draw = (offset, size) -> begin
        if !decoded.has(offset)
            @var cmd = @new Uint8Array(program.memory.buffer, offset, size)
            decoded.set(offset,JSON.parse(decoder.decode(cmd)))
        end
        execute(stack,decoded.get(offset),drawingSize,ratio)
    end
    @var show = stage -> begin
        @var index = gallery.interaction ? program.current() : select.selectedIndex
        @var size = gallery.sizes[index]
        ratio = sampling(size)
        @var root = stage.cache[index]
        if !root || root.vellumDensity !== ratio
            if root
                root.destroy(d(children=true,texture=true,textureSource=true))
            end
            root = @new PIXI.Container()
            root.vellumDensity = ratio
            stack = [root]
            drawingSize = size
            program["scene"+(index+1)]()
            stage.cache[index] = root
            stage.panel.dataset.recordings = String(Number(stage.panel.dataset.recordings || 0)+1)
        end
        if stage.renderer.screen.width !== size[0] || stage.renderer.screen.height !== size[1] || stage.renderer.resolution !== ratio
            stage.renderer.resize(size[0],size[1],ratio)
        end
        stage.presentation.removeChildren()
        stage.presentation.addChild(root)
        if stage.focus >= 0 && gallery.interaction && gallery.interaction.focus_marks.length > 0
            @var mark = stage.marks[stage.focus]
            if !mark || mark.vellumDensity !== ratio
                if mark
                    mark.destroy(d(children=true))
                end
                mark = @new PIXI.Container()
                mark.vellumDensity = ratio
                @var group = [mark]
                gallery.interaction.focus_marks[stage.focus].forEach(op -> execute(group,op,size,ratio))
                stage.marks[stage.focus] = mark
            end
            stage.presentation.addChild(mark)
        end
        stage.renderer.render(stage.presentation)
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
        @var stage = d(panel=panel, status=panel.querySelector("output"), cache=[],focus=-1,marks=[],presentation=@new(PIXI.Container()))
        @var preference = target === "webgl2" ? "webgl" : target
        @var options = d(preference=[preference], preferWebGLVersion=2, antialias=true, backgroundAlpha=0,
                         width=gallery.sizes[0][0],height=gallery.sizes[0][1],resolution=sampling(gallery.sizes[0]),
                         autoDensity=true,bezierSmoothness=0.98)
        PIXI.autoDetectRenderer(options).then(renderer -> begin
            stage.renderer = renderer
            if target === "webgl2" && renderer.context.webGLVersion !== 2
                renderer.destroy()
                Promise.reject("WebGL 2 is unavailable")
            else
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

"""Embed the pinned Pixi runtime and its license for offline use in any Vellum browser host."""
function _write_pixi_runtime(io)
    package = joinpath(artifact"pixi", "package")
    runtime = read(joinpath(package, "dist", "pixi.min.js"), String)
    runtime = replace(runtime, "//# sourceMappingURL=pixi.min.js.map"=>"", r"(?i)</script"=>s"<\\/script")
    license = read(joinpath(package,"LICENSE"),String)
    println(io, "<script>/*", replace(license,"*/"=>"* /"), "*/\n", runtime, "</script>")
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
    _write_pixi_runtime(io)
    println(io, "<script>const sampling=",_browser_sampling,",watchDensity=",_browser_watch_density,
            ",compound=",_browser_compound,",graphic=", _browser_graphic, ",sprite=", _browser_sprite,
            ",endGroup=", _browser_end_group, ",execute=", _browser_execute,
            ",controls=",_browser_controls,";", _browser_start, "();</script>")
end
