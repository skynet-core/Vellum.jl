# End-to-end browser check against a running playground.
pushfirst!(LOAD_PATH,@__DIR__)
push!(LOAD_PATH,normpath(joinpath(@__DIR__,"..","..")))
using Test, Vellum, Base64
import HTTP, JSON
include(joinpath(pkgdir(Vellum),"docs","lessons.jl"))

"""Call a Chrome DevTools method and wait for its response."""
function cdp(ws,method,params=(;))
    HTTP.WebSockets.send(ws,JSON.json((;id=1,method,params)))
    while true
        response = JSON.parse(String(HTTP.WebSockets.receive(ws)))
        get(response,"id",0)==1 || continue
        haskey(response,"error") && error(response["error"])
        return response["result"]
    end
end

"""Evaluate a browser test expression by value."""
function evaluate(ws,expression)
    result = cdp(ws,"Runtime.evaluate",(;expression,returnByValue=true))
    haskey(result,"exceptionDetails") && error(result["exceptionDetails"])
    get(result["result"],"value",nothing)
end

"""Check Julia execution, actual displayed colors, renderer selection and an invalid edit."""
function check_editor(ws)
    js(expr) = evaluate(ws,expr)
    ready() = js("document.getElementById('status')?.textContent")=="Rendered"
    function wait_ready()
        status = timedwait(()->ready() || js("document.getElementById('status')?.textContent")=="Run failed",88)
        status===:ok && ready() || error("Preview failed: "*string(js("document.getElementById('errors')?.textContent")))
    end
    function run_source(source)
        js("document.getElementById('source').value="*JSON.json(source)*";document.getElementById('run').click()")
    end
    function matching_pixels(color)
        response = cdp(ws,"Page.captureScreenshot",(format="png",))
        image = decode_png(base64decode(response["data"]))
        count(==(color),image)
    end
    wait_ready()
    @test startswith(js("document.getElementById('details').textContent"),"WebGL2")
    if haskey(ENV,"VELLUM_PLAYGROUND_SCREENSHOT")
        shot = cdp(ws,"Page.captureScreenshot",(format="png",))
        write(ENV["VELLUM_PLAYGROUND_SCREENSHOT"],base64decode(shot["data"]))
    end
    red = """using Vellum
    paint(value) = Solid(value,0,1-value)
    drawing(size=(192,128)) do e
        for stripe in 0:3
            rectangle!(e,48stripe,0,48,128;fill=paint(1))
        end
    end"""
    run_source(red)
    wait_ready()
    @test matching_pixels(rgbx(255,0,0,255)) > 15_000
    js("let target=document.getElementById('backend');target.value='canvas';target.dispatchEvent(new Event('change'))")
    wait_ready()
    @test startswith(js("document.getElementById('details').textContent"),"Canvas 2D")
    @test matching_pixels(rgbx(255,0,0,255)) > 15_000
    run_source(replace(red,"fill=paint(1)"=>"fill=paint(0)"))
    wait_ready()
    @test matching_pixels(rgbx(0,0,255,255)) > 15_000
    run_source("using Vellum\nunknown_drawing_name()")
    @test timedwait(()->js("document.getElementById('status').textContent")=="Run failed",85)===:ok
    @test occursin("unknown_drawing_name",js("document.getElementById('errors').textContent"))
    @test matching_pixels(rgbx(0,0,255,255)) > 15_000
    # Exercise every discovered tutorial preset with both real contexts.
    catalog = js("Array.from(document.querySelectorAll('#lesson option'),o=>o.value).filter(Boolean)")
    @test sort(catalog)==sort(tutorial_names(pkgdir(Vellum)))
    for name in catalog, backend in ("canvas","webgl2")
        js("document.getElementById('backend').value="*JSON.json(backend))
        js("document.getElementById('lesson').value="*JSON.json(name)*";document.getElementById('lesson').dispatchEvent(new Event('change'))")
        wait_ready()
        # Confirm that the composited preview contains artwork. A valid graphics
        # context alone can also belong to a collapsed, invisible canvas.
        function ink_count()
            x,y,w,h = js("(()=>{const r=document.getElementById('preview').getBoundingClientRect();return [r.x+4,r.y+4,r.width-8,Math.min(r.height,innerHeight-r.y)-8]})()")
            shot = cdp(ws,"Page.captureScreenshot",(format="png",clip=(;x,y,width=w,height=h,scale=1)))
            img = decode_png(base64decode(shot["data"]))
            count(p->max(abs(Int(p.r)-234),abs(Int(p.g)-240),abs(Int(p.b)-237))>48,img)
        end
        @test timedwait(()->ink_count()>1000,6;pollint=0.15)==:ok
        @test js("document.getElementById('source').value")==read(joinpath(pkgdir(Vellum),"tutorials",name*".jl"),String)
        @test startswith(js("document.getElementById('details').textContent"),backend=="canvas" ? "Canvas 2D" : "WebGL2")
        if name=="liquid_glass" && backend=="webgl2" && haskey(ENV,"VELLUM_FRAMEWORK_SCREENSHOT")
            shot = cdp(ws,"Page.captureScreenshot",(format="png",))
            write(ENV["VELLUM_FRAMEWORK_SCREENSHOT"],base64decode(shot["data"]))
        end
    end
    js("document.getElementById('lesson').value='liquid_glass';document.getElementById('lesson').dispatchEvent(new Event('change'))")
    wait_ready()
    original = js("document.getElementById('source').value")
    revised = replace(original,"Listening room"=>"Listening studio")
    @test revised!=original
    run_source(revised)
    wait_ready()
    @test startswith(js("document.getElementById('details').textContent"),"WebGL2")

end

url = isempty(ARGS) ? "http://127.0.0.1:8080" : only(ARGS)
@testset "Julia editor and live canvas" begin
    @test HTTP.get(url*"/health").status == 200
    mktempdir() do profile
        browser = get(ENV,"VELLUM_BROWSER","google-chrome")
        chrome = run(pipeline(`$browser --no-first-run --disable-background-networking --user-data-dir=$profile --headless --enable-unsafe-swiftshader --force-color-profile=srgb --remote-debugging-address=127.0.0.1 --remote-debugging-port=0 --window-size=1280,860 $url`;stderr=devnull);wait=false)
        try
            portfile = joinpath(profile,"DevToolsActivePort")
            timedwait(()->isfile(portfile),20)===:ok || error("Chromium startup failed")
            port = first(readlines(portfile))
            tabs = JSON.parse(String(HTTP.get("http://127.0.0.1:$port/json/list").body))
            tab = only(filter(t->t["type"]=="page" && startswith(t["url"],url),tabs))
            HTTP.WebSockets.open(check_editor,tab["webSocketDebuggerUrl"])
        finally
            kill(chrome)
            wait(chrome)
        end
    end
end
