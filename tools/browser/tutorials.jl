include(joinpath(@__DIR__,"..","..","docs","lessons.jl"))

"""Execute one real Literate tutorial in an isolated module and directory."""
function run_tutorial(name,dir)
    sandbox = Module(gensym(:Tutorial))
    Core.eval(sandbox,:(include(path) = Base.include($sandbox,path)))
    cd(dir) do
        withenv("VELLUM_TUTORIAL_HOST"=>"browser","VELLUM_TUTORIAL_RENDERER"=>"webgl2","VELLUM_TUTORIAL_OUTPUT"=>dir) do
            Base.include(sandbox,joinpath(pkgdir(Vellum),"tutorials",name*".jl"))
        end
    end
    return sandbox
end

"""Capture the WebGL2 canvas at logical scale and read the actual GL driver identity."""
function capture_tutorial(ws,url,ready)
    protocol(ws,"Page.navigate",(url="file://"*url,))
    timedwait(()->evaluate(ws,ready)===true,30)==:ok || error("renderer failed to display $url")
    return capture_webgl(ws)
end

"""Read the current WebGL2 scene after the browser has composited its canvas."""
function capture_webgl(ws)
    info = evaluate(ws,@browser begin
        @var canvas = document.querySelector("canvas")
        @var gl = canvas.getContext("webgl2")
        @var ext = gl.getExtension("WEBGL_debug_renderer_info")
        @var r = canvas.getBoundingClientRect()
        return [gl.getParameter(gl.VERSION),gl.getParameter(ext ? ext.UNMASKED_RENDERER_WEBGL : gl.RENDERER),
                r.x,r.y,r.width,r.height]
    end)
    startswith(info[1],"WebGL 2") || error("expected a WebGL2 context")
    x,y,w,h = info[3:6]
    data = protocol(ws,"Page.captureScreenshot",(format="png",clip=(;x,y,width=w,height=h,scale=1)))
    return decode_png(base64decode(data["data"])),join(info[1:2]," / ")
end

"""Exercise the glass tutorial through real browser input and capture settled visual states."""
function glass_gestures(ws,app)
    scene = @browser document.querySelector("section").dataset.scene
    observed() = parse(Int,evaluate(ws,scene))
    function expect(state,action)
        destination = app.transitions[state,action]
        while app.timers[destination][1] > 0
            destination = app.transitions[destination,app.timers[destination][2]]
        end
        if timedwait(()->observed()==destination,5;pollint=0.02)!==:ok
            @error "Glass interaction settled in a different scene" state action destination actual=observed()
        end
        @test observed()==destination
        return destination
    end
    snapshots = []
    x,y,w,h = first(control_boxes(ws))
    mouse(kind;px=x+w/2,py=y+h/2,down=false) = protocol(ws,"Input.dispatchMouseEvent",
        (type=kind,x=px,y=py,button=kind=="mouseMoved" ? "none" : "left",buttons=down ? 1 : 0,clickCount=1))
    function key(kind,name,code,keycode)
        protocol(ws,"Input.dispatchKeyEvent",(type=kind,key=name,code,windowsVirtualKeyCode=keycode))
    end
    feedback(i,phase) = Vellum.feedback_action(app.controls,i,phase)
    mouse("mouseMoved";px=1,py=1)
    state = expect(1,feedback(0,:idle))
    mouse("mouseMoved")
    state = expect(state,feedback(1,:hover))
    push!(snapshots,("hover",state,capture_webgl(ws)))
    mouse("mousePressed";down=true)
    state = expect(state,feedback(1,:press))
    push!(snapshots,("pressed",state,capture_webgl(ws)))
    mouse("mouseMoved";px=1,py=1,down=true)
    state = expect(state,feedback(0,:idle))
    mouse("mouseReleased";px=1,py=1)
    @test evaluate(ws,@browser document.querySelector("[aria-label=Route]").getAttribute("aria-checked")) == "true"
    mouse("mouseMoved")
    state = expect(state,feedback(1,:hover))
    mouse("mousePressed";down=true)
    state = expect(state,feedback(1,:press))
    mouse("mouseReleased")
    state = expect(app.transitions[state,feedback(1,:hover)],1)
    @test evaluate(ws,@browser document.querySelector("[aria-label=Route]").getAttribute("aria-checked")) == "false"
    push!(snapshots,("toggled",state,capture_webgl(ws)))
    key("keyDown","Tab","Tab",9)
    key("keyUp","Tab","Tab",9)
    state = expect(state,feedback(2,:focus))
    push!(snapshots,("focus",state,capture_webgl(ws)))
    key("keyDown"," ","Space",32)
    state = expect(state,feedback(2,:press))
    key("keyUp"," ","Space",32)
    state = expect(app.transitions[state,feedback(2,:focus)],2)
    @test evaluate(ws,@browser document.querySelector("[aria-label=Places]").getAttribute("aria-checked")) == "true"
    protocol(ws,"Emulation.setEmulatedMedia",(features=[(name="prefers-reduced-motion",value="reduce")],))
    try
        key("keyDown","Enter","Enter",13)
        @test app.timers[observed()][1] == 0
        key("keyUp","Enter","Enter",13)
        @test app.timers[observed()][1] == 0
        @test evaluate(ws,@browser document.querySelector("[aria-label=Places]").getAttribute("aria-checked")) == "false"
        protocol(ws,"Emulation.setTouchEmulationEnabled",(enabled=true,))
        protocol(ws,"Input.dispatchTouchEvent",(type="touchStart",touchPoints=[(x=x+w/2,y=y+h/2)],))
        protocol(ws,"Input.dispatchTouchEvent",(type="touchCancel",touchPoints=[],))
        @test evaluate(ws,@browser document.querySelector("[aria-label=Route]").getAttribute("aria-checked")) == "false"
        protocol(ws,"Input.dispatchTouchEvent",(type="touchStart",touchPoints=[(x=x+w/2,y=y+h/2)],))
        protocol(ws,"Input.dispatchTouchEvent",(type="touchEnd",touchPoints=[],))
        @test timedwait(()->evaluate(ws,@browser document.querySelector("[aria-label=Route]").getAttribute("aria-checked"))=="true",3)==:ok
    finally
        protocol(ws,"Emulation.setTouchEmulationEnabled",(enabled=false,))
        protocol(ws,"Emulation.setEmulatedMedia",(features=[],))
    end
    return snapshots
end

"""Verify real backdrop filtering on high-contrast stripes with identical glass tint and magnification."""
function check_frost(ws,api,dir)
    stripes = drawing(size=(128,48)) do e
        rectangle!(e,0,0,128,48;fill=Solid(1,1,1))
        for x in 0:8:120
            rectangle!(e,x,0,4,48;fill=Solid(0,0,0))
        end
    end
    source = rasterize(stripes)
    frame = drawing(size=(128,48)) do e
        draw_image!(e,resource!(e,source),(0,0,128,48))
        for (x,blur) in ((6,0),(70,9))
            surface = Base.invokelatest(api.prepare_glass!,e,source,(x,6,50,36),8;blur_radius=blur)
            Base.invokelatest(api.paint_glass!,e,surface;zoom=1,light=0,dark=0)
        end
    end
    path = savehtml(joinpath(dir,"material-proof.html"),frame;target=:webgl2)
    ready = @browser document.querySelector("[data-state=ready]")!==nothing
    browser,_ = capture_tutorial(ws,path,ready)
    for (name,img) in ((:cpu,rasterize(frame)),(:opengl,rasterize(frame;target=:opengl)),
                       (:vulkan,rasterize(frame;target=:vulkan)),(:webgl2,browser))
        contrast(cols) = maximum(Int(img[24,x].r) for x in cols)-minimum(Int(img[24,x].r) for x in cols)
        clear,frosted = contrast(17:46),contrast(81:110)
        println("Backdrop stripe contrast ",name," · clear ",clear," · frosted ",frosted)
        @test clear>240 && frosted<15
        savepng(joinpath(pkgdir(Vellum),"reports","tutorials","material-$name.png"),img)
    end
end

"""Exercise the switch, range and reset control with real canvas pointer input."""
function mixer_gestures(ws,app)
    boxes = control_boxes(ws)
    function click_at(i,fraction)
        x,y,w,h = boxes[i]
        for kind in ("mousePressed","mouseReleased")
            protocol(ws,"Input.dispatchMouseEvent",(type=kind,x=x+w*fraction,y=y+h/2,button="left",
                     buttons=kind=="mousePressed" ? 1 : 0,clickCount=1))
        end
    end
    values() = evaluate(ws,@browser [document.querySelector("[aria-label='Spatial audio']").getAttribute("aria-checked"),
                                     document.querySelector("[aria-label=Volume]").value])
    @test values()==["true","3"]
    click_at(1,0.5)
    click_at(2,0.99)
    @test timedwait(()->values()==["false","4"],5)==:ok
    protocol(ws,"Input.dispatchMouseEvent",(type="mouseMoved",x=1,y=1))
    state() = parse(Int,evaluate(ws,@browser document.querySelector("section").dataset.scene))
    @test timedwait(()->app.timers[state()][1]==0,4)==:ok
    snapshot = ("changed",state(),capture_webgl(ws))
    click_at(3,0.5)
    @test timedwait(()->values()==["true","3"],5)==:ok
    return snapshot
end

"""Write a visual comparison for each tutorial using its real scene and the four required backends."""
function tutorial_proof(ws,dir)
    root = pkgdir(Vellum)
    destination = joinpath(root,"reports","tutorials")
    mkpath(destination)
    io = IOBuffer()
    print(io,"<!doctype html><meta charset=utf-8><title>Vellum tutorial rendering checks</title><style>body{font:16px system-ui;max-width:1200px;margin:30px auto;padding:0 18px}section{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px}figure{margin:0}img{width:100%;background:#fff}figcaption{padding:8px 0 20px;overflow-wrap:anywhere}</style>",
          "<h1>Tutorial rendering checks</h1><p>Each row of images uses the same Julia source and input. The comparison uses opaque CPU pixels. Error is the mean absolute RGB channel difference on a 0–255 scale. Open an image for its full resolution.</p>")
    manifest = []
    catalog = (("route",:frame),("touch_controls",:panel),("surface_plot",:plot_app),
               ("signal_desk",:panel),("glass_market",:preview),("candlesticks",:view),("glass_controls",:atlas),("liquid_glass",:mixer))
    @test sort(first.(collect(catalog))) == tutorial_names(root)
    for (name,entry) in catalog
        lesson = run_tutorial(name,dir)
        app = Base.invokelatest(getproperty,lesson,entry)
        page = joinpath(dir,name*"-proof.html")
        if app isa Frame
            frame = app
            savehtml(page,frame;target=:webgl2)
        elseif app isa InteractiveDrawing
            frame = first(app.frames)
            page = joinpath(dir,replace(name,"_"=>"-")*".html")
            isfile(page) || error("tutorial did not export $page")
        else
            # Pin a three-bar dataset so every target gets identical prices, volume and tooltip data.
            rows = [(time=1_700_000_000_000+60_000i,open=101.0+i,high=111.0+i,low=96.0+i,
                     price=103.0+(-1)^i*4,volume=12.0+i,trades=4,closed=true) for i in 1:3]
            model = Base.invokelatest(()->lesson.BinanceChart.chart_model("BTCUSDT",rows,"Pinned test candles";index=1,y=185))
            frame = drawing(app,model)
            savehtml(page,app;target=:webgl2,config=model,driver=@browser(host->host.update(host.config)))
        end
        ready = @browser document.querySelector("[data-state=ready]")!==nothing
        web = capture_tutorial(ws,page,ready)
        cases = [(name,frame,web)]
        map_pixels = nothing
        if name == "glass_controls"
            map_pixels = Base.invokelatest(()->rasterize(drawing(lesson.paint_map!;size=lesson.extent)))
            for (label,state,capture) in glass_gestures(ws,app)
                push!(cases,(name*"-"*label,app.frames[state],capture))
            end
        end
        if name=="liquid_glass"
            label,state,capture = mixer_gestures(ws,app)
            push!(cases,(name*"-"*label,app.frames[state],capture))
            check_frost(ws,lesson.GlassUI.GlassMaterial,dir)
        end
        for (label,expected,web_result) in cases
            print(io,"<h2>",replace(label,"_"=>" "),"</h2>")
            name=="surface_plot" && print(io,"<p>CPU depth-tested mesh. Devices render the final vector and image composition.</p>")
            print(io,"<section>")
            reference = rasterize(expected)
            mask = findall(==(0xff),reference.data[4:4:end])
            @assert length(mask)>=length(reference)÷2
            for (target,provider) in (("cpu",nothing),("vulkan",Vellum.VulkanBackend),("opengl",Vellum.OpenGLBackend),("webgl2",nothing))
                if target=="cpu"
                    result,driver = reference,"Vellum CPU"
                elseif target=="webgl2"
                    result,driver = web_result
                else
                    surface = render(expected;backend=provider.DesktopBackend())
                    try
                        result,driver = readback(surface),provider.statistics(surface).renderer
                    finally
                        close(surface)
                    end
                end
                @assert size(result)==size(reference)
                error = sum(abs(Int(result.data[4i+j])-Int(reference.data[4i+j])) for i in mask for j in -3:-1)/(3length(mask))
                filename = "$label-$target.png"
                savepng(joinpath(destination,filename),result)
                passed = error < 6
                if label=="glass_controls"
                    # Shadow depth over sand and water, measured against the same unobstructed map.
                    for x in (115,252)
                        depth = map((353,358,364,371)) do y
                            sum(Int(getfield(map_pixels[y+1,k],c))-Int(getfield(result[y+1,k],c))
                                for k in x:x+4 for c in (:r,:g,:b))/15
                        end
                        println("Toolbar shadow ",target," x=",x," · RGB darkening at y=353,358,364,371: ",round.(depth;digits=1))
                        @test depth[1]>depth[2]>depth[3]>depth[4]-0.5
                        @test depth[1]>12 && depth[2]>4 && abs(depth[4])<2
                    end
                end
                println("Tutorial pixels ",label," / ",target," mean RGB error ",round(error;digits=3)," · ",driver)
                @test passed
                push!(manifest,(;tutorial=name,scene=label,target,driver,mean_rgb_error=error,passed,pixels=length(mask),image=filename))
                print(io,"<figure><a href='",filename,"'><img src='",filename,"' alt='",label," on ",target,"'></a><figcaption><strong>",target,
                      "</strong> · ",replace(driver,"&"=>"&amp;","<"=>"&lt;")," · ",passed ? "Pass" : "Fail"," · error ",round(error;digits=3),"</figcaption></figure>")
            end
            print(io,"</section>")
        end
    end
    write(joinpath(destination,"measurements.json"),JSON.json(manifest,2))
    write(joinpath(destination,"index.html"),take!(io))
end
