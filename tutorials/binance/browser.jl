"""Connect market and input events to the chart model. Vellum owns every drawing operation."""
const start_chart = @browser host -> begin
    @var cfg = host.config
    @var canvas = host.canvas
    @var plot = cfg.plot
    @var book = @new Map()
    @var active = true
    @var fetching = false
    @var generation = 0
    @var interval = "1m"
    @var socket = nothing
    @var timer = 0
    @var reconnect = 0
    @var retry = 1000
    @var restDelay = 3000
    @var lastEvent = 0
    @var polls = 0
    @var visible = 48
    @var anchor = nothing
    @var cursorX = -1
    @var cursorY = 0
    @var drag = nothing
    @var toolbarPress = -1
    @var toolbarFocus = -1
    @var allBars = []
    @var rows = []
    @var firstIndex = 0
    @var status = "Connecting to Binance…"
    @var price = n->n.toLocaleString("en-US",d(minimumFractionDigits=2,maximumFractionDigits=2))
    @var stamp = t->(@new Date(t)).toISOString().slice(0,16).replace("T"," ")
    @var say = message->begin
        if status!==message
            status = message
            draw()
        end
    end
    @var merge = bar->begin
        if bar.slice(0,7).every(Number.isFinite) && bar[0]>0 && bar[3]>0 && bar[3]<=Math.min(bar[1],bar[4]) && Math.max(bar[1],bar[4])<=bar[2] && bar[5]>=0 && bar[6]>=0
            @var old = book.get(bar[0])
            if !old || (old[6]<=bar[6] && (!old[7] || bar[7]))
                book.set(bar[0],bar)
            end
        end
    end
    @var draw = ()->begin
        allBars = Array.from(book.values()).sort((a,b)->a[0]-b[0])
        allBars.slice(0,Math.max(0,allBars.length-240)).forEach(b->book.delete(b[0]))
        allBars = allBars.slice(-240)
        @var right = allBars.length
        if anchor !== nothing
            @var next = allBars.findIndex(b->b[0]>anchor)
            if next>=0
                right = Math.min(allBars.length,Math.max(visible,next))
            end
        end
        firstIndex = Math.max(0,right-visible)
        rows = allBars.slice(firstIndex,right)
        @var n = rows.length
        @var low = rows.reduce((v,b)->Math.min(v,b[3]),Infinity)
        @var high = rows.reduce((v,b)->Math.max(v,b[2]),0)
        @var pad = Math.max(0.00000001,(high-low)*0.08,high*0.000002)
        @var bars = rows.map((b,i)->d(index=i,open=b[1],high=b[2],low=b[3],price=b[4],volume=b[5],
            color=b[4]>=b[1] ? 0x26a69a : 0xef5350,volume_color=b[4]>=b[1] ? 0x246963 : 0x854143))
        @var newest = allBars[allBars.length-1]
        @var lastColor = newest && newest[4]>=newest[1] ? 0x47c4b0 : 0xff827a
        @var header = d(pair=cfg.symbol+"  /  Spot",price=newest ? price(newest[4]) : "—",color=lastColor,status=status)
        @var buttons = cfg.controls.map((b,i)->Object.assign(d(color=i===toolbarFocus ? 0x526c88 : (b.label===interval ? 0x40546c : 0x242c39)),b))
        @var span = high-low+2*pad
        @var ticks = n ? [0,0.25,0.5,0.75,1].map(v->d(fraction=v,label=price(high+pad-v*span))) : []
        @var times = n ? Array.from(@new Set([0,Math.floor((n-1)/2),n-1])).map(i->d(index=i,label=stamp(rows[i][0]).slice(11))) : []
        @var cursor = []
        @var i = Math.floor((cursorX-plot.left)*n/(plot.right-plot.left))
        if i>=0 && i<n && cursorY>=plot.top && cursorY<=plot.volume_bottom
            @var b = rows[i]
            cursor.push(d(index=i,y=cursorY,stamp=stamp(b[0])+" UTC",ohl="O   "+price(b[1])+"    H   "+price(b[2]),
                lcl="L   "+price(b[3])+"    C   "+price(b[4]),vol="Vol   "+b[5]+"   ·   "+(b[7] ? "Closed" : "Open")))
        end
        host.update(d(header=[header],buttons=buttons,ticks=ticks,bars=bars,times=times,cursor=cursor,count=n,
            low=low-pad,span=span,maxvolume=rows.reduce((v,b)->Math.max(v,b[5]),0.00000001),
            last_price=newest && anchor===nothing ? [d(value=newest[4],label=header.price,color=lastColor)] : []))
        canvas.dataset.count = n
        canvas.dataset.follow = String(anchor===nothing)
        canvas.dataset.interval = interval
        canvas.dataset.openTime = newest ? newest[0] : ""
        canvas.dataset.trades = newest ? newest[6] : ""
        canvas.dataset.hover = cursor.length ? rows[i][0] : ""
        canvas.setAttribute("aria-description",cursor.length ? Object.values(cursor[0]).slice(2).join(" ") : status)
    end
    @var pan = stop->begin
        @var idx = Math.max(Math.min(visible,allBars.length),Math.min(allBars.length,stop))
        anchor = idx===allBars.length || !idx ? nothing : allBars[idx-1][0]
        draw()
    end
    @var zoom = (factor,fraction)->begin
        @var pivot = firstIndex+fraction*rows.length
        visible = Math.max(12,Math.min(96,Math.round(visible*factor)))
        pan(Math.round(pivot+(1-fraction)*visible))
    end
    @var point = ev->begin
        @var r = canvas.getBoundingClientRect()
        return [(ev.clientX-r.left)*plot.width/r.width,(ev.clientY-r.top)*plot.height/r.height]
    end
    @var buttonAt = p->cfg.controls.findIndex(b->b.x<=p[0] && p[0]<b.x+b.w && b.y<=p[1] && p[1]<b.y+b.h)
    canvas.addEventListener("wheel",ev->begin
        ev.preventDefault()
        zoom(ev.deltaY<0 ? 0.75 : 1.5,Math.max(0,Math.min(1,(point(ev)[0]-plot.left)/(plot.right-plot.left))))
    end,d(passive=false))
    canvas.addEventListener("pointerdown",ev->begin
        if ev.button===0 && ev.isPrimary
            @var p = point(ev)
            toolbarPress = buttonAt(p)
            toolbarFocus = -1
            if toolbarPress >= 0
                canvas.children[toolbarPress].focus(d(preventScroll=true))
            else
                canvas.focus(d(preventScroll=true))
                drag = [p[0],firstIndex+rows.length]
            end
            canvas.setPointerCapture(ev.pointerId)
        end
    end)
    canvas.addEventListener("pointerup",ev->begin
        @var i = toolbarPress
        toolbarPress = -1
        if ev.isPrimary && i>=0 && i===buttonAt(point(ev))
            choose(cfg.controls[i].label)
        end
    end)
    canvas.addEventListener("pointermove",ev->begin
        @var p = point(ev)
        cursorX = p[0]
        cursorY = p[1]
        if drag
            pan(drag[1]+Math.round((drag[0]-cursorX)*visible/(plot.right-plot.left)))
        else
            draw()
        end
    end)
    canvas.addEventListener("lostpointercapture",()->begin
        drag = nothing
        toolbarPress = -1
    end)
    canvas.addEventListener("pointerleave",()->begin
        cursorX = -1
        draw()
    end)
    canvas.addEventListener("keydown",ev->begin
        if ev.key==="ArrowLeft" || ev.key==="ArrowRight" || ev.key==="Escape"
            ev.preventDefault()
            @var n = rows.length
            @var i = Math.floor((cursorX-plot.left)*n/(plot.right-plot.left))
            i = i<0 ? n-1 : Math.max(0,Math.min(n-1,i+(ev.key==="ArrowLeft" ? -1 : 1)))
            cursorX = ev.key==="Escape" || !n ? -1 : plot.left+(plot.right-plot.left)*(i+0.5)/n
            cursorY = (plot.top+plot.bottom)/2
            draw()
        end
    end)
    @var poll = () -> begin
        if !active || fetching
            return
        end
        fetching = true
        @var version = generation
        @var historyUrl = @new URL(cfg.history)
        historyUrl.searchParams.set("interval",interval)
        historyUrl.searchParams.set("limit","240")
        fetch(historyUrl,d(cache="no-store",signal=AbortSignal.timeout(9000))).then(response->begin
            if !response.ok
                restDelay = Math.max(restDelay,1000*(Number(response.headers.get("Retry-After")) || 0))
                return Promise.reject("HTTP "+response.status)
            end
            return response.json()
        end).then(data->begin
            if version !== generation
                return
            end
            if !Array.isArray(data) || !data.length
                return Promise.reject("empty history")
            end
            data.forEach(r->merge([Number(r[0]),Number(r[1]),Number(r[2]),Number(r[3]),Number(r[4]),
                    Number(r[5]),Number(r[8]),Number(r[6])<Date.now()]))
            restDelay = 3000
            polls = polls+1
            draw()
            if Date.now()-lastEvent>10000
                say("Updating via REST")
            end
        end).catch(err->begin
            if version !== generation
                return
            end
            if Date.now()-lastEvent>10000
                say("Binance history unavailable · "+String(err)+" · retrying")
            end
            restDelay = Math.max(Math.min(60000,restDelay*2),restDelay)
        end).finally(()->begin
            if version !== generation
                return
            end
            fetching = false
            if active
                timer = setTimeout(check,restDelay)
            end
        end)
    end
    @var check = () -> begin
        if Date.now()-lastEvent>10000 || polls===0
            poll()
        else
            timer = setTimeout(check,3000)
        end
    end
    @var connect = () -> begin
        if !active
            return
        end
        @var version = generation
        socket = @new WebSocket(cfg.stream.replace("@kline_1m","@kline_"+interval))
        socket.onmessage = ev -> begin
            @var message = JSON.parse(ev.data)
            @var k = message.k
            if version===generation && k && k.s===cfg.symbol && k.i===interval
                merge([Number(k.t),Number(k.o),Number(k.h),Number(k.l),Number(k.c),Number(k.v),Number(k.n),k.x===true])
                lastEvent = Date.now()
                retry = 1000
                say("Live · Binance WebSocket")
                draw()
            end
        end
        socket.onclose = () -> begin
            if version !== generation
                return
            end
            lastEvent = 0
            if active
                say("Stream disconnected · refreshing history")
                reconnect = setTimeout(connect,retry)
                retry = Math.min(30000,2*retry)
            end
        end
        socket.onopen = () -> begin
            if version === generation && polls>0
                clearTimeout(timer)
                poll()
            end
        end
    end
    @var choose = name->begin
        if name==="+"
            zoom(0.75,1)
        elseif name==="−"
            zoom(1.5,1)
        elseif name==="Latest"
            pan(allBars.length)
        elseif interval!==name
            generation = generation+1
            interval = name
            clearTimeout(timer)
            clearTimeout(reconnect)
            if socket
                socket.close()
            end
            book.clear()
            fetching = false
            polls = 0
            lastEvent = 0
            restDelay = 3000
            retry = 1000
            anchor = nothing
            cursorX = -1
            say("Loading "+interval+" candles…")
            poll()
            connect()
        end
    end
    cfg.controls.forEach((b,i)->begin
        @var el = document.createElement("button")
        el.setAttribute("aria-label",b.label)
        el.onfocus = ()->begin
            toolbarFocus = el.matches(":focus-visible") && toolbarPress<0 ? i : -1
            draw()
        end
        el.onblur = ()->begin
            toolbarFocus = -1
            draw()
        end
        el.onclick = ()->choose(b.label)
        canvas.appendChild(el)
    end)
    window.addEventListener("pagehide",()->begin
        active = false
        generation = generation+1
        clearTimeout(reconnect)
        clearTimeout(timer)
        if socket
            socket.close()
        end
    end)
    draw()
    poll()
    connect()
end
