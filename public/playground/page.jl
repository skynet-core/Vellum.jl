using Vellum: @browser
import JSON
include("catalog.jl")

"""Forward a completed Vellum renderer's actual context or error to the containing editor."""
const preview_monitor = @browser () -> begin
    @var report = () -> begin
        @var section = document.querySelector("section,main[data-state]")
        @var problem = document.querySelector("#error")
        if section && section.dataset.state === "ready"
            @var canvas = section.querySelector("canvas")
            @var config = document.querySelector("#gallery,#view")
            @var data = JSON.parse(config.textContent)
            @var size = data.sizes ? data.sizes[0] : data.size
            document.documentElement.style.setProperty("--vellum-width",size[0]+"px")
            @var rect = canvas.getBoundingClientRect()
            if rect.width<1 || rect.height<1
                parent.postMessage(d(kind="vellum-preview",error="The preview canvas has no visible area."),"*")
                return
            end
            @var renderer = canvas.getContext("webgl2") ? "WebGL2" : (canvas.getContext("2d") ? "Canvas 2D" : "Unknown context")
            parent.postMessage(d(kind="vellum-preview",renderer=renderer,width=canvas.width,height=canvas.height),"*")
        elseif (section && section.dataset.state === "error") || (problem && problem.textContent)
            parent.postMessage(d(kind="vellum-preview",error=section && section.dataset.state === "error" ? section.textContent : problem.textContent),"*")
        else
            setTimeout(report,100)
        end
    end
    report()
end

"""Attach the editor to the isolated Julia execution endpoint and its sandboxed preview."""
const editor_script = @browser () -> begin
    @var code = document.getElementById("source")
    @var status = document.getElementById("status")
    @var details = document.getElementById("details")
    @var run = document.getElementById("run")
    @var target = document.getElementById("backend")
    @var mount = document.getElementById("preview")
    @var lesson = document.getElementById("lesson")
    @var drafts = @new Map()
    @var current = ""
    @var errors = document.getElementById("errors")
    @var pending = nothing
    @var candidate = nothing
    @var version = 0
    @var finish = () -> begin
        run.disabled = false
        target.disabled = false
        lesson.disabled = false
        window.clearTimeout(pending)
    end
    @var fail = message -> begin
        if candidate
            candidate.remove()
            candidate = nothing
        end
        status.textContent = "Run failed"
        errors.textContent = String(message)
        errors.hidden = false
        finish()
    end
    @var execute = useStock -> begin
        if run.disabled
            return
        end
        @var id = version+1
        version = id
        run.disabled = true
        target.disabled = true
        lesson.disabled = true
        errors.hidden = true
        status.textContent = "Running Julia…"
        pending = setTimeout(() -> begin
            if version === id
                version = version+1
                fail("The preview timed out. Run again to retry.")
            end
        end,90000)
        @var entry = lessons.find(item->item.id === current)
        @var stock = useStock === true && entry && code.value === entry.source
        @var response = stock ? fetch("/tutorial/"+current+"/"+target.value).then(res->begin
            if !res.ok
                return Promise.reject("Tutorial export unavailable. Press Run Julia to rebuild this drawing.")
            end
            return res.text().then(html->d(html=html))
        end) : fetch("/api/run/"+target.value,d(method="POST",headers=d("Content-Type"="application/julia"),body=code.value)).then(res->res.json())
        response.then(result -> begin
            if id !== version
                return
            end
            if result.error
                fail(result.error)
                return
            end
            @var frame = document.createElement("iframe")
            frame.setAttribute("sandbox","allow-scripts")
            frame.title = "Vellum drawing preview"
            frame.style.visibility = "hidden"
            frame.srcdoc = (current === "candlesticks" ? marketPrelude : prelude)+result.html+monitor
            status.textContent = "Starting renderer…"
            candidate = frame
            mount.appendChild(frame)
        end).catch(err -> begin
            if id === version
                fail(err)
            end
        end)
    end
    window.addEventListener("message",ev -> begin
        if candidate && ev.source === candidate.contentWindow && ev.data && ev.data.kind === "vellum-preview"
            if ev.data.error
                fail(ev.data.error)
            else
                @var expected = target.value === "webgl2" ? "WebGL2" : "Canvas 2D"
                if ev.data.renderer !== expected
                    fail("The requested "+expected+" context is unavailable.")
                    return
                end
                @var old = mount.firstElementChild
                if old !== candidate
                    old.remove()
                end
                candidate.style.visibility = "visible"
                candidate = nothing
                status.textContent = "Rendered"
                details.textContent = ev.data.renderer+"  ·  "+ev.data.width+" × "+ev.data.height
                finish()
            end
        end
    end)
    @var cursor = () -> begin
        @var lines = code.value.slice(0,code.selectionStart).split("\n")
        document.getElementById("cursor").textContent = "Ln "+lines.length+"  ·  Col "+(lines[lines.length-1].length+1)
    end
    lessons.forEach(item->lesson.add(@new Option(item.title,item.id)))
    @var choose = () -> begin
        drafts.set(current,code.value)
        current = lesson.value
        @var entry = lessons.find(item->item.id === current)
        code.value = drafts.has(current) ? drafts.get(current) : (entry ? entry.source : sample)
        @var notebook = document.getElementById("notebook")
        notebook.hidden = !entry
        if entry
            notebook.href = "/notebook/"+entry.id
            notebook.download = entry.id+".ipynb"
        end
        code.setSelectionRange(0,0)
        code.scrollTop = 0
        document.getElementById("filename").textContent = (entry ? entry.id : "sketch")+".jl"
        cursor()
        execute(true)
    end
    code.value = sample
    lesson.addEventListener("change",()->begin
        history.replaceState(nothing,"",lesson.value ? "#"+lesson.value : location.pathname)
        choose()
    end)
    code.addEventListener("input",cursor)
    code.addEventListener("keyup",cursor)
    code.addEventListener("click",cursor)
    code.addEventListener("keydown",ev -> begin
        if (ev.ctrlKey || ev.metaKey) && ev.key === "Enter"
            ev.preventDefault()
            execute()
        end
    end)
    run.addEventListener("click",execute)
    target.addEventListener("change",()->execute(true))
    @var requested = location.hash.slice(1)
    if lessons.some(item->item.id===requested)
        lesson.value = requested
    end
    choose()
end

"""Build the complete editor document from the bundled editable Julia example."""
function editor_page()
    # The opaque preview may execute its own inline Wasm and drawing runtime.
    # Network requests, plugins, forms and nested frames are disallowed inside it.
    prelude = """<!doctype html><meta charset=utf-8><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval' blob:; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; worker-src blob:; connect-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'"><style>
    :root{color-scheme:light}html,body{margin:0!important;height:100%;background:transparent!important;padding:0!important}body{display:flex;align-items:center;justify-content:center}body>label,h2,body>output:empty{display:none}body>main{width:min(100%,var(--vellum-width,100%));min-width:0;max-width:100%!important;margin:0!important}section{border:0!important;border-radius:0!important}canvas{display:block;max-width:100%!important;height:auto!important}output{font:15px system-ui;color:#25404d}</style>"""
    monitor = "<script>"*preview_monitor*"();</script>"
    market_prelude = replace(prelude,"connect-src 'none'"=>"connect-src https://data-api.binance.vision wss://data-stream.binance.vision")
    lessons = playground_lessons()
    sample = read(joinpath(@__DIR__,"sketch.jl"),String)
    return """<!doctype html><html lang="en"><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Vellum Playground</title>
    <style>
    *{box-sizing:border-box}body{margin:0;background:#f4f6f5;color:#132f34;font:16px/1.5 "Instrument Sans",system-ui,sans-serif}
    main{max-width:1500px;margin:auto;padding:clamp(16px,3vw,46px)}header,.bar,footer{display:flex;align-items:center;justify-content:space-between;gap:12px}
    header{margin-bottom:26px}h1,h2,p{margin:0}h1{font-size:clamp(23px,3vw,36px);letter-spacing:-.045em;font-weight:650}h1 span{color:#5e7476;font-weight:400}h2{font-size:1rem}
    .lesson{display:flex;align-items:center;gap:10px;margin-bottom:16px}.lesson select{max-width:100%}.panels{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:14px}section{min-width:0;border:1px solid #cdd7d6;border-radius:14px;overflow:hidden;background:#fff;display:flex;flex-direction:column}
    .bar,footer{padding:13px 18px;min-height:49px}.bar{border-bottom:1px solid #d9e1df}.file,.meta,footer{font-size:.84rem;color:#496166}
    .source .bar,.source footer{background:#14272f;color:#d2e0de;border-color:#2e4147}.source .file{color:#9fb3b6}.file a{color:#b2eade;margin-right:8px}
    textarea{width:100%;flex:1;min-height:530px;background:#102129;color:#dce8e3;border:none;outline-offset:-3px;padding:20px;resize:vertical;tab-size:4;font:14px/1.65 "IBM Plex Mono",ui-monospace,monospace;white-space:pre}
    button,select{font:inherit;border-radius:8px;padding:8px 14px}button{background:#116559;color:#fff;border:1px solid #116559;font-weight:600;cursor:pointer}button:hover{background:#0c5148}button:disabled,select:disabled{opacity:.6}select{border:1px solid #bdceca;background:white;color:#193638;font-size:.9rem}
    #preview{flex:1;min-height:380px;position:relative;display:grid;place-items:center;background-color:#eaf0ed;background-image:radial-gradient(#c6d0cb 1px,transparent 1px);background-size:12px 12px}
    iframe{width:100%;height:100%;min-height:380px;position:absolute;inset:0;border:0}footer{border-top:1px solid #d9e1df}#errors{white-space:pre-wrap;overflow-wrap:anywhere;color:#833c28;background:#fff1ea;margin:0;padding:12px 16px;max-height:14rem;overflow:auto;font:14px/1.45 ui-monospace,monospace}
    @media(max-width:820px){.panels{grid-template-columns:1fr}textarea{min-height:340px}.bar,footer{padding:10px 14px}header{margin-bottom:14px}}
    </style><main><header><h1>Vellum <span>Playground</span></h1><button id=run type=button>Run Julia</button></header>
    <label class=lesson>Lesson <select id=lesson><option value="">Custom sketch</option></select></label>
    <div class=panels><section class=source aria-labelledby=editor-label><div class=bar><h2 id=editor-label>Julia editor</h2><span class=file><a id=notebook hidden>Notebook</a> <span id=filename>sketch.jl</span></span></div>
    <textarea id=source aria-labelledby=editor-label spellcheck=false autocapitalize=off></textarea><footer><span id=cursor></span><span>Ctrl / ⌘ + Enter</span></footer></section>
    <section aria-labelledby=preview-label><div class=bar><h2 id=preview-label>Preview</h2><select id=backend aria-label="Preview renderer"><option value=webgl2>WebGL2</option><option value=canvas>Canvas 2D</option></select></div>
    <div id=preview></div><pre id=errors role=alert hidden></pre><footer><span id=status aria-live=polite>Ready</span><span id=details></span></footer></section></div></main>
    <script>const lessons=$(script_data(lessons)),marketPrelude=$(script_data(market_prelude)),sample=$(script_data(sample)),prelude=$(script_data(prelude)),monitor=$(script_data(monitor));$editor_script();</script></html>"""
end

"""Encode a string for an inline script, including literal HTML closing tags."""
script_data(value) = replace(JSON.json(value),"<"=>"\\u003c")
