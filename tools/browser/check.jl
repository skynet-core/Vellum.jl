# Browser integration check using a disposable profile and the DevTools protocol.
using Test, Base64, Vellum
using Vellum: @browser
import JSON, HTTP
include(joinpath(@__DIR__,"..","..","test","fixtures","drawing_contract.jl"))
include(joinpath(@__DIR__,"..","..","test","fixtures","retained_panel.jl"))

function protocol(ws, method, params=(;))
    HTTP.WebSockets.send(ws, JSON.json((id=1,method=method,params=params)))
    while true
        response = JSON.parse(String(HTTP.WebSockets.receive(ws)))
        if get(response,"id",nothing) == 1
            haskey(response,"error") && error(response["error"])
            return response["result"]
        end
    end
end

function evaluate(ws, expr)
    response = protocol(ws,"Runtime.evaluate",(expression=expr,returnByValue=true))
    haskey(response,"exceptionDetails") && error(response["exceptionDetails"])
    return get(response["result"],"value",nothing)
end

"""Compare the visible output of every browser renderer with zero-based reference pixels."""
function check_scene(ws, label, probes; tolerance=0, ink_regions=())
    state = @browser Array.from(document.querySelectorAll("section"), panel -> [panel.dataset.state,
        panel.dataset.scene, panel.querySelector("output").textContent])
    last = []
    for i in 1:300
        last = evaluate(ws,state)
        any(s->s[1]=="error", last) && error("renderer failed: $last")
        length(last)==3 && all(s->s[1]=="ready" && s[2]==label,last) && break
        sleep(0.1)
    end
    @test length(last)==3 && all(s->s[1]=="ready" && s[2]==label,last)
    positions = evaluate(ws,@browser Array.from(document.querySelectorAll("canvas"), c -> begin
        @var r = c.getBoundingClientRect()
        return [Math.floor(r.left),Math.floor(r.top),r.width,r.height]
    end))
    sleep(0.1)
    @test length(positions) == 3
    for (target,(x,y,width,height)) in zip(("canvas","webgl2","webgpu"),positions)
        clip = (;x,y,width,height,scale=1)
        payload = protocol(ws,"Page.captureScreenshot",(;clip,format="png"))
        screenshot = decode_png(base64decode(payload["data"]))
        for (px,py,color) in probes
            actual = screenshot[py+1,px+1]
            differences = ntuple(i->abs(Int(getfield(actual,i))-Int(getfield(color,i))),4)
            @test (target,px,py,maximum(differences) <= tolerance) == (target,px,py,true)
        end
        for (columns,rows) in ink_regions
            @test any(screenshot[py+1,px+1].r < 96 for py in rows, px in columns)
        end
    end
end

"""Check that pointer and keyboard events change both the Wasm state and the displayed tutorial pixels."""
function check_workshops(ws,dir)
    lessons = (("surface_plot","surface-plot",1,3),
               ("touch_controls","touch-controls",1,11),
               ("signal_desk","signal-desk",2,3),("glass_market","glass-market",1,1))
    for (source,name,control,nextscene) in lessons
        cd(dir) do
            lesson = Module(gensym(:Lesson))
            Core.eval(lesson,:(include(path) = Base.include($lesson,path)))
            Base.include(lesson,joinpath(pkgdir(Vellum),"tutorials",source*".jl"))
        end
        protocol(ws,"Page.navigate",(url="file://"*joinpath(dir,name*".html"),))
        scene = @browser document.querySelector("section") && document.querySelector("section").dataset.scene
        @test timedwait(() -> evaluate(ws,scene)=="1",20) == :ok
        before = protocol(ws,"Page.captureScreenshot",(format="png",))["data"]
        boxes = control_boxes(ws)
        x,y,w,h = boxes[control]
        fraction = name == "surface-plot" ? 0.25 : 0.5
        for kind in ("mousePressed","mouseReleased")
            protocol(ws,"Input.dispatchMouseEvent",(type=kind,x=x+w*fraction,y=y+h/2,
                     button="left",clickCount=1))
        end
        if name == "glass-market"
            @test timedwait(() -> evaluate(ws,scene)!="1",3;pollint=0.01) == :ok
            @test timedwait(() -> evaluate(ws,scene)=="1",15) == :ok
            evaluate(ws,@browser begin
                @var slider = document.querySelector("input")
                slider.value = "7"
                slider.dispatchEvent(@new Event("input"))
            end)
            @test timedwait(() -> evaluate(ws,scene)=="8",4) == :ok
        else
            @test timedwait(() -> evaluate(ws,scene)==string(nextscene),5) == :ok
        end
        after = protocol(ws,"Page.captureScreenshot",(format="png",))["data"]
        a,b = decode_png(base64decode(before)),decode_png(base64decode(after))
        @test count(i -> a.data[i] != b.data[i],eachindex(a.data)) > 1000
        if name == "touch-controls"
            @test evaluate(ws,@browser document.querySelector("[role=switch]").getAttribute("aria-checked")) == "true"
            evaluate(ws,@browser document.querySelector("input").focus())
            for kind in ("keyDown","keyUp")
                protocol(ws,"Input.dispatchKeyEvent",(type=kind,key="ArrowRight",code="ArrowRight",windowsVirtualKeyCode=39))
            end
            @test timedwait(() -> evaluate(ws,@browser document.querySelector("input").value)=="4",5) == :ok
            evaluate(ws,@browser document.querySelector("[aria-label=Cool]").click())
            @test timedwait(() -> evaluate(ws,@browser document.querySelector("[aria-label=Cool]").getAttribute("aria-checked"))=="true",5) == :ok
            # Remove the entire fallback subtree. The switch and range must still paint and respond.
            evaluate(ws,@browser document.activeElement.blur())
            @test evaluate(ws,@browser document.querySelector(".drawing").children.length) == 1
            @test evaluate(ws,@browser Array.from(document.querySelectorAll("canvas button,canvas input"),c->c.getClientRects().length)) == zeros(Int,4)
            tree = protocol(ws,"Accessibility.getFullAXTree")["nodes"]
            @test all((("switch","Reading light"),("slider","Brightness"),("radio","Cool"))) do (role,name)
                any(n->!n["ignored"] && get(get(n,"role",Dict()),"value","")==role &&
                    get(get(n,"name",Dict()),"value","")==name,tree)
            end
            pixels() = protocol(ws,"Page.captureScreenshot",(format="png",))["data"]
            settled = pixels()
            evaluate(ws,@browser document.querySelector("canvas").replaceChildren())
            @test pixels() == settled
            oldstate = evaluate(ws,scene)
            for kind in ("mousePressed","mouseReleased")
                protocol(ws,"Input.dispatchMouseEvent",(type=kind,x=x+w/2,y=y+h/2,button="left",clickCount=1))
            end
            @test timedwait(()->evaluate(ws,scene)!=oldstate,5) == :ok
            @test pixels() != settled
            oldstate = evaluate(ws,scene)
            sx,sy,sw,sh = boxes[2]
            protocol(ws,"Input.dispatchMouseEvent",(type="mousePressed",x=sx+sw/2,y=sy+sh/2,button="left",buttons=1,clickCount=1))
            protocol(ws,"Input.dispatchMouseEvent",(type="mouseMoved",x=sx+sw-1,y=sy+sh/2,buttons=1))
            protocol(ws,"Input.dispatchMouseEvent",(type="mouseReleased",x=sx+sw-1,y=sy+sh/2,button="left",clickCount=1))
            @test timedwait(()->evaluate(ws,scene)!=oldstate,5) == :ok
        end
    end
end

"""Project logical control rectangles into actual viewport coordinates for pointer input."""
function control_boxes(ws)
    evaluate(ws,@browser begin
        @var gallery = JSON.parse(document.getElementById("gallery").textContent)
        @var r = document.querySelector("canvas").getBoundingClientRect()
        @var s = gallery.sizes[0]
        return gallery.interaction.controls.map(c -> [r.left+c.rect[0]*r.width/s[0],r.top+c.rect[1]*r.height/s[1],
                                                      c.rect[2]*r.width/s[0],c.rect[3]*r.height/s[1]])
    end)
end

"""Verify live Binance updates and hover data against the current rightmost candle in Chromium."""
function check_live_market(ws,dir)
    lesson = Module(gensym(:Market))
    Core.eval(lesson,:(include(path) = Base.include($lesson,path)))
    cd(dir) do
        Base.include(lesson,joinpath(pkgdir(Vellum),"tutorials","candlesticks.jl"))
    end
    protocol(ws,"Page.navigate",(url="file://"*joinpath(dir,"candlesticks.html"),))
    ready = @browser document.querySelector("canvas") && Number(document.querySelector("canvas").dataset.count)===48
    timedwait(()->evaluate(ws,ready)===true,40) == :ok ||
        error("Binance chart unavailable: "*string(evaluate(ws,@browser document.querySelector("main").textContent)))
    x,y = evaluate(ws,@browser begin
        @var r = document.querySelector("canvas").getBoundingClientRect()
        return [r.left+r.width*618/704,r.top+r.height*215/420]
    end)
    protocol(ws,"Input.dispatchMouseEvent",(type="mouseMoved",x,y))
    info = @browser [document.querySelector("canvas").dataset.openTime,document.querySelector("canvas").dataset.trades,
        document.querySelector("canvas").getAttribute("aria-description"),document.querySelector("canvas").dataset.hover]
    @test timedwait(()->occursin("Vol",evaluate(ws,info)[3]),5)==:ok
    first = evaluate(ws,info)
    @test first[1]==first[4] && all(s->occursin(s,first[3]),("UTC","O   ","H   ","L   ","C   ","Vol"))
    @test timedwait(()->evaluate(ws,info)[1:2] != first[1:2],35) == :ok
    evaluate(ws,@browser document.querySelector("[aria-label='+']").click())
    @test evaluate(ws,@browser Number(document.querySelector("canvas").dataset.count)) == 36
    protocol(ws,"Input.dispatchMouseEvent",(type="mouseMoved",x=x-250,y))
    protocol(ws,"Input.dispatchMouseEvent",(type="mousePressed",x=x-250,y,button="left",buttons=1,clickCount=1))
    protocol(ws,"Input.dispatchMouseEvent",(type="mouseMoved",x=x-120,y,button="left",buttons=1))
    @test timedwait(()->evaluate(ws,@browser document.querySelector("canvas").dataset.follow)=="false",5)==:ok
    protocol(ws,"Input.dispatchMouseEvent",(type="mouseReleased",x=x-120,y,button="left",clickCount=1))
    evaluate(ws,@browser document.querySelector("[aria-label='Latest']").click())
    @test evaluate(ws,@browser document.querySelector("canvas").dataset.follow)=="true"
    evaluate(ws,@browser document.querySelector("[aria-label='5m']").click())
    @test timedwait(()->evaluate(ws,@browser Number(document.querySelector("canvas").dataset.count))==36,30)==:ok
    @test evaluate(ws,@browser Number(document.querySelector("canvas").dataset.openTime)) % 300_000 == 0
end

function check_reports(ws)
    root = dirname(dirname(@__DIR__))
    for (file, heading) in (("reports/coverage.html","Vellum unit test coverage"),
                            ("profiles/cpu.html","Vellum CPU profile"),
                            ("profiles/gpu.html","Vellum GPU profile"))
        protocol(ws,"Page.navigate",(url="file://" * joinpath(root,file),))
        title = @browser document.title
        @test timedwait(() -> evaluate(ws,title)==heading,10) == :ok
        if startswith(file,"reports/")
            @test evaluate(ws,@browser begin
                @var section = document.querySelector("details")
                section.querySelector("summary").click()
                return section.open && section.querySelector(".line").getBoundingClientRect().height > 0
            end)
        else
            @test evaluate(ws,@browser document.querySelectorAll("tr meter").length) > 0
        end
    end
    profile = JSON.parsefile(joinpath(root,"profiles","cpu.cpuprofile"))
    ids = Set(n["id"] for n in profile["nodes"])
    @test !isempty(profile["samples"])
    @test all(in(ids), profile["samples"])
    @test sum(profile["timeDeltas"]) == profile["endTime"] - profile["startTime"]
    paths = joinpath(root,"profiles")
    cpu = split.(readlines(joinpath(paths,"cpu.tsv"))[2:end],'\t')
    gpu = split.(readlines(joinpath(paths,"gpu.tsv"))[4:end],'\t')
    methods = Set(Tuple(row[1:3]) for row in cpu)
    @test all(row -> !startswith(row[6],"src/") || Tuple(row[5:7]) in methods,gpu)
end

include("tutorials.jl")
include("smoothing.jl")

@testset "Browser gallery selection and rendered pixels" begin
    browser = get(ENV,"VELLUM_BROWSER","google-chrome")
    mktempdir() do dir
        function square(fill)
            drawing(size=(16,16)) do e
                rectangle!(e,0,0,16,16;fill)
            end
        end
        layered = drawing(size=(16,16)) do edit
            white = Image(2,2)
            fill!(white,rgba(255,255,255,255))
            draw_image!(edit,resource!(edit,white),(0,0,16,16))
            with_group(edit;opacity=0.5) do group
                clip(group,rectangle_path(0,0,8,8))
                red = Solid(1,0,0)
                rectangle!(group,0,0,16,16;fill=red)
                rectangle!(group,0,0,16,16;fill=red)
            end
        end
        counters = drawing(size=(116,44)) do e
            rectangle!(e,0,0,116,44;fill=Solid(1,1,1))
            font = resource!(e,:font,FontData("Liberation Sans",read(joinpath(pkgdir(Vellum),"test","fixtures","LiberationSans-Regular.ttf"))))
            configure!(e;font,font_size=32,fill=Solid(0,0,0))
            Vellum.capture_text!(e,"B8OD0",(3,35))
        end
        revisions = retained_panel()
        scenes = (red=square(Solid(1,0,0)),blue=square(Solid(0,0,1)),layered=layered,
                  contract=drawing_contract_frame(),counters=counters,
                  gradient=revisions[1],edited=revisions[2],removed=revisions[3])
        page = savehtml(joinpath(dir,"gallery.html"),scenes;target=:compare)
        profile = joinpath(dir,"chrome")
        # Chrome chooses an unused loopback port and publishes it in this private profile.
        chrome_mode = "--headed" in ARGS ? String[] : ["--headless"]
        flags = filter(arg -> !(arg in ("--headed","--reports","--workshops","--live-binance","--tutorial-proof","--smoothing")),ARGS)
        # Compare screenshots in the same sRGB space as the reference pixels.
        chrome = run(pipeline(`$browser $chrome_mode --no-first-run --no-default-browser-check --disable-background-networking --force-color-profile=srgb --remote-debugging-address=127.0.0.1 --remote-debugging-port=0 --user-data-dir=$profile --window-size=900,800 --enable-unsafe-webgpu $flags $page`;stderr=stderr);wait=false)
        try
            portfile = joinpath(profile,"DevToolsActivePort")
            timedwait(() -> isfile(portfile) || !process_running(chrome), 15) === :ok && isfile(portfile) ||
                error("browser did not start")
            port = parse(Int,first(readlines(portfile)))
            tabs = JSON.parse(String(HTTP.get("http://127.0.0.1:$port/json/list").body))
            tab = only(filter(t -> t["type"]=="page" && endswith(t["url"],"/gallery.html"), tabs))
            HTTP.WebSockets.open(tab["webSocketDebuggerUrl"]) do ws
                protocol(ws, "Emulation.setDeviceMetricsOverride",(width=900,height=800,deviceScaleFactor=1,mobile=false))
                check_scene(ws,"red",[(4,4,rgbx(255,0,0,255))])
                evaluate(ws,@browser begin
                    @var select = document.querySelector("select")
                    select.selectedIndex = 1
                    select.dispatchEvent(@new Event("change"))
                end)
                check_scene(ws,"blue",[(4,4,rgbx(0,0,255,255))])
                evaluate(ws,@browser begin
                    @var select = document.querySelector("select")
                    select.selectedIndex = 2
                    select.dispatchEvent(@new Event("change"))
                end)
                check_scene(ws,"layered",[(4,4,rgbx(255,128,128,255)),
                                          (12,12,rgbx(255,255,255,255))];tolerance=1)
                evaluate(ws,@browser begin
                    @var select = document.querySelector("select")
                    select.selectedIndex = 3
                    select.dispatchEvent(@new Event("change"))
                end)
                check_scene(ws,"contract",drawing_contract_probes();tolerance=2,
                            ink_regions=((66:76,11:22),(78:87,11:22)))
                evaluate(ws,@browser begin
                    @var select = document.querySelector("select")
                    select.selectedIndex = 4
                    select.dispatchEvent(@new Event("change"))
                end)
                probes = [(x,y,rgbx(255,255,255,255)) for (x,y) in
                           ((14,18),(14,28),(32,18),(32,28),(55,24),(77,24),(99,24))]
                push!(probes,(6,24,rgbx(0,0,0,255)))
                check_scene(ws,"counters",probes;tolerance=2)
                records = @browser document.getElementById("webgl2").dataset.recordings
                visited = Set{Int}()
                for (index,name,pixel) in ((5,"gradient",rgbx(232,23,0,255)),(6,"edited",rgbx(0,0,255,255)),
                                          (7,"removed",rgbx(30,36,56,255)),(6,"edited",rgbx(0,0,255,255)))
                    prior = evaluate(ws,records)
                    evaluate(ws,"document.querySelector('select').selectedIndex = $index")
                    evaluate(ws,@browser document.querySelector("select").dispatchEvent(@new Event("change")))
                    check_scene(ws,name,[(11,15,pixel),(169,89,rgbx(30,36,56,255))];tolerance=3)
                    @test parse(Int,evaluate(ws,records)) == parse(Int,prior) + (index in visited ? 0 : 1)
                    push!(visited,index)
                end
                renderer = evaluate(ws,@browser begin
                    @var gl = document.querySelector("#webgl2 canvas").getContext("webgl2")
                    @var ext = gl.getExtension("WEBGL_debug_renderer_info")
                    return [gl.getParameter(gl.VERSION),gl.getParameter(ext ? ext.UNMASKED_RENDERER_WEBGL : gl.RENDERER)]
                end)
                @test startswith(renderer[1],"WebGL 2")
                println("Retained browser revisions: ",join(renderer," / "))
                "--reports" in ARGS && check_reports(ws)
                "--workshops" in ARGS && check_workshops(ws,dir)
                "--live-binance" in ARGS && check_live_market(ws,dir)
                "--tutorial-proof" in ARGS && tutorial_proof(ws,dir)
                "--smoothing" in ARGS && check_smoothing(ws,dir)
            end
        finally
            kill(chrome)
            wait(chrome)
        end
    end
end
