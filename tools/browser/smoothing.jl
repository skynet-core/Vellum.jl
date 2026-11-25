"""Draw a black half-plane or a one-unit stroke with a subpixel intercept and known slope."""
function slope_scene(;stroke=false)
    drawing(size=(180,110)) do e
        rectangle!(e,0,0,180,110;fill=Solid(1,1,1))
        edge = ((:move,0,16.13),(:line,180,16.13+180*0.347))
        if stroke
            configure!(e;stroke=Solid(0,0,0),stroke_style=StrokeStyle(width=1))
            draw(e,PathData(edge);mode=:stroke)
        else
            configure!(e;fill=Solid(0,0,0))
            draw(e,PathData((edge...,(:line,180,110),(:line,0,110),(:close,))))
        end
    end
end

"""Capture composited display pixels and return their CSS size, backing size and actual WebGL context attributes."""
function edge_capture(ws)
    info = evaluate(ws,@browser begin
        @var c = document.querySelector("canvas")
        @var r = c.getBoundingClientRect()
        @var gl = c.getContext("webgl2")
        return [r.x,r.y,r.width,r.height,c.width,c.height,window.devicePixelRatio,
                gl.getContextAttributes().antialias,gl.getParameter(gl.SAMPLES)]
    end)
    x,y,width,height = info[1:4]
    shot = protocol(ws,"Page.captureScreenshot",(format="png",clip=(;x,y,width,height,scale=1)))
    return decode_png(base64decode(shot["data"])),info
end

"""Open a WebGL2 export and capture its initial scene or the Places-only Pelican Sound map."""
function open_edge_scene(ws,path;places=false)
    navigate(ws,"file://"*abspath(path))
    ready = @browser document.querySelector("#webgl2") && document.querySelector("#webgl2").dataset.state === "ready"
    timedwait(()->evaluate(ws,ready)===true,25)==:ok || error("Could not draw $path")
    if places
        evaluate(ws,@browser begin
            document.querySelector("[aria-label=Route]").click()
            document.querySelector("[aria-label=Places]").click()
        end)
        settled = @browser document.querySelector("[aria-label=Route]").getAttribute("aria-checked")==="false" &&
            document.querySelector("[aria-label=Places]").getAttribute("aria-checked")==="true"
        timedwait(()->evaluate(ws,settled)===true,5)==:ok || error("Map controls failed in $path")
    end
    return edge_capture(ws)
end

"""Compare only partially covered pixels with the integral of the white area above the line. Values are sRGB channel units (0–255)."""
function edge_error(img,dpr;stroke=false)
    errors = Float64[]
    levels = Set{UInt8}()
    slope = 0.347
    # The integral of clamp(t,0,1) is quadratic in the transition, then linear.
    integral(t) = t<=0 ? 0.0 : t>=1 ? t-0.5 : t*t/2
    above(t) = (integral(t+slope)-integral(t))/slope
    radius = stroke ? dpr*hypot(1,slope)/2 : 0.0
    for x in 3dpr:(177dpr-1)
        top = 16.13dpr+slope*x
        for y in floor(Int,top-radius):floor(Int,top+slope+radius)
            coverage = stroke ? 1-(above(top+radius-y)-above(top-radius-y)) : above(top-y)
            0.001 < coverage < 0.999 || continue
            value = img[y+1,x+1].r
            push!(errors,abs(value-255coverage))
            push!(levels,value)
        end
    end
    return (;mean_error=sum(errors)/length(errors),levels=length(levels),pixels=length(errors))
end

"""Save the same logical rectangle from each map as an unscaled PNG."""
function edge_crop(img,dpr,x,y,w,h)
    result = Image(w*dpr,h*dpr)
    for j in 1:result.width, i in 1:result.height
        result[i,j] = img[y*dpr+i,x*dpr+j]
    end
    return result
end

"""Test display density changes and ideal edge coverage, optionally writing a matched comparison from archived exports."""
function check_smoothing(ws,dir)
    metrics(dpr;width=900) = protocol(ws,"Emulation.setDeviceMetricsOverride",(;width,height=800,deviceScaleFactor=dpr,mobile=false))
    site = savehtml(joinpath(dir,"slope.html"),slope_scene();target=:webgl2)
    stroke_page = savehtml(joinpath(dir,"stroke.html"),slope_scene(;stroke=true);target=:webgl2)
    destination = joinpath(pkgdir(Vellum),"reports","smoothing")
    mkpath(destination)
    results = []
    try
        for dpr in (1,2)
            metrics(dpr)
            for (label,env,file) in (("before","VELLUM_EDGE_BASELINE",site),("after",nothing,site),("stroke",nothing,stroke_page))
                !isnothing(env) && !haskey(ENV,env) && continue
                page = isnothing(env) ? file : ENV[env]
                img,info = open_edge_scene(ws,page)
                @test size(img) == (110dpr,180dpr)
                values = edge_error(img,dpr;stroke=label=="stroke")
                println("WebGL2 edge at ",dpr,"× · ",label," · ",values," · backing ",info[5:6]," · MSAA ",info[8:9])
                push!(results,(;density=dpr,label,backing=info[5:6],antialias=info[8],samples=info[9],values...))
                if label!="before"
                    @test info[5:6] == [360dpr,220dpr]
                    @test values.mean_error < 12
                end
            end
        end
        # CDP changes devicePixelRatio silently if the emulated viewport keeps its exact extent.
        metrics(1;width=901)
        @test timedwait(()->evaluate(ws,@browser document.querySelector("canvas").width) == 360,5)==:ok
        if haskey(ENV,"VELLUM_GLASS_BASELINE")
            metrics(2)
            for (label,path) in (("before",ENV["VELLUM_GLASS_BASELINE"]),
                                ("after",get(ENV,"VELLUM_GLASS_COMPARISON",joinpath(pkgdir(Vellum),"tutorials","output","glass-controls.html"))))
                img,info = open_edge_scene(ws,path;places=true)
                @test size(img)==(748,1280)
                savepng(joinpath(destination,label*".png"),img)
                savepng(joinpath(destination,label*"-rim.png"),edge_crop(img,2,18,278,90,66))
                savepng(joinpath(destination,label*"-coast.png"),edge_crop(img,2,284,76,136,77))
                println("Pelican Sound · ",label," · display ",info[3:4]," · backing ",info[5:6])
            end
            open(joinpath(destination,"index.html"),"w") do io
                print(io,"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'><title>Pelican Sound edge comparison</title><style>body{max-width:1320px;margin:32px auto;padding:0 18px;font:16px/1.5 system-ui;color:#172d32}section{display:grid;grid-template-columns:1fr 1fr;gap:10px}figure{margin:0}img{max-width:100%;display:block}.crop{image-rendering:pixelated}td,th{text-align:left;padding:4px 16px 4px 0}</style><h1>Pelican Sound edge comparison</h1><p>The two WebGL2 captures use the same 640 × 374 drawing and a 2× display. Route is off and Places is on. Select a map to see the original display pixels.</p>")
                for (suffix,title,zoom) in (("","Full map",0),("-coast","Coast and depth contours",544),("-rim","Toolbar rim",360))
                    print(io,"<h2>",title,"</h2><section>")
                    for name in ("before","after")
                        file = name*suffix*".png"
                        print(io,"<figure><figcaption>",titlecase(name),"</figcaption><a href='",file,"'><img alt='",name," ",title,"' src='",file,"' ",zoom>0 ? "class=crop width=$zoom" : "","></a></figure>")
                    end
                    print(io,"</section>")
                end
                print(io,"<h2>Measured diagonal edges</h2><p>Before and after use the same black half-plane on white. Stroke measures a one-unit diagonal stroke in the new renderer. Mean absolute error is measured in gray levels (0–255) over partially covered pixels. Lower is closer to geometric pixel coverage.</p><table><tr><th>Display<th>Export<th>Backing pixels<th>Mean error<th>Distinct levels")
                for r in results
                    print(io,"<tr><td>",r.density,"×<td>",r.label,"<td>",join(r.backing," × "),"<td>",round(r.mean_error;digits=2),"<td>",r.levels)
                end
                print(io,"</table>")
            end
        end
        if haskey(ENV,"VELLUM_SHADOW_BASELINE")
            metrics(2)
            out = mkpath(joinpath(pkgdir(Vellum),"reports","shadow"))
            for (label,path) in (("before",ENV["VELLUM_SHADOW_BASELINE"]),
                                 ("after",joinpath(pkgdir(Vellum),"tutorials","output","glass-controls.html")))
                img,_ = open_edge_scene(ws,path;places=true)
                savepng(joinpath(out,label*".png"),edge_crop(img,2,0,255,325,119))
            end
            write(joinpath(out,"index.html"),"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Pelican Sound toolbar shadow</title>
            <style>body{margin:32px auto;padding:0 16px;max-width:1360px;font:16px/1.5 system-ui;color:#172d32}main{display:flex;flex-wrap:wrap;gap:16px}figure{margin:0}img{display:block;width:650px;max-width:100%;height:auto}</style>
            <h1>Toolbar shadow</h1><p>WebGL2, 2× display density. Both captures use the same map, toolbar state and line smoothing.</p>
            <main><figure><figcaption>Original offset fill</figcaption><img src="before.png" alt="Toolbar with a hard lower edge"></figure>
            <figure><figcaption>Contact and ambient shadow</figcaption><img src="after.png" alt="Toolbar shadow fading over sand and water"></figure></main>""")
        end
        if haskey(ENV,"VELLUM_MIXER_BASELINE")
            metrics(2)
            out = mkpath(joinpath(pkgdir(Vellum),"reports","glass"))
            for (label,path) in (("before",ENV["VELLUM_MIXER_BASELINE"]),
                                 ("after",joinpath(pkgdir(Vellum),"tutorials","output","liquid-glass.html")))
                img,_ = open_edge_scene(ws,path)
                savepng(joinpath(out,label*".png"),img)
            end
            write(joinpath(out,"index.html"),"""<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Listening room glass material</title>
            <style>body{font:16px/1.5 system-ui;max-width:1560px;margin:32px auto;padding:0 16px}main{display:grid;grid-template-columns:1fr 1fr;gap:12px}figure{margin:0}img{width:100%;height:auto}</style>
            <h1>Listening room glass material</h1><p>Both WebGL2 captures show the initial mix. The updated wallpaper has fine contours so you can follow their blur through the panel and the controls.</p>
            <main><figure><figcaption>Previous controls</figcaption><a href="before.png"><img src="before.png" alt="Previous sound panel"></a></figure>
            <figure><figcaption>Updated glass and shadows</figcaption><a href="after.png"><img src="after.png" alt="Blurred wallpaper and shadows under the controls"></a></figure></main>""")
        end
        open(io->JSON.print(io,results,2),joinpath(destination,"metrics.json"),"w")
    finally
        metrics(1)
    end
end
