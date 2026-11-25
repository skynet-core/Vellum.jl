"""Fetch one bounded Spot snapshot. Fields are UTC open time, OHLC, volume, trade count and closed flag."""
function history(url)
    buffer = IOBuffer()
    response = Downloads.request(url;output=buffer,timeout=8,headers=["Cache-Control"=>"no-cache"])
    response.status == 200 || error("Binance returned HTTP $(response.status)")
    payload = JSON.parse(String(take!(buffer)))
    rows = [(time=Int(r[1]),open=parse(Float64,r[2]),high=parse(Float64,r[3]),low=parse(Float64,r[4]),
             price=parse(Float64,r[5]),volume=parse(Float64,r[6]),trades=Int(r[9]),closed=r[7]<1000time())
            for r in payload]
    !isempty(rows) && length(rows)<=240 && issorted([b.time for b in rows]) || error("invalid Binance history")
    all(b -> 0<b.low<=min(b.open,b.price)<=max(b.open,b.price)<=b.high && isfinite(b.high) &&
             isfinite(b.volume) && b.volume>=0,rows) || error("invalid Binance candle")
    rows
end

"""Prepare market values and formatted strings for the shared view. Coordinates are defined in chart_view."""
function chart_model(symbol,rows,status;interval="1m",latest=isempty(rows) ? nothing : last(rows),index=-1,y=0,following=true)
    price(p) = string(round(p;digits=2))
    stamp(t) = Dates.format(unix2datetime(t/1000),"yyyy-mm-dd HH:MM")
    count = length(rows)
    lo = isempty(rows) ? 0.0 : minimum(b.low for b in rows)
    hi = isempty(rows) ? 1.0 : maximum(b.high for b in rows)
    pad = max(1e-8,(hi-lo)*0.08,hi*0.000002)
    low,span = lo-pad,hi-lo+2pad
    color = latest!==nothing && latest.price>=latest.open ? 0x47c4b0 : 0xff827a
    text = isnothing(latest) ? "—" : price(latest.price)
    header = [(pair=symbol*"  /  Spot",price=text,color=color,status=status)]
    buttons = [merge(b,(color=b.label==interval ? 0x40546c : 0x242c39,)) for b in controls]
    bars = [merge(b,(index=i-1,color=b.price>=b.open ? 0x26a69a : 0xef5350,
            volume_color=b.price>=b.open ? 0x246963 : 0x854143)) for (i,b) in enumerate(rows)]
    ticks = [(fraction=f,label=price(hi+pad-f*span)) for f in (0,0.25,0.5,0.75,1) if count>0]
    times = [(index=i-1,label=last(stamp(rows[i].time),5)) for i in unique([1,cld(count,2),count]) if count>0]
    last_price = following && latest!==nothing ? [(value=latest.price,label=text,color=color)] : []
    cursor = if 0<=index<count
        b=rows[index+1]
        [(;index,y,stamp=stamp(b.time)*" UTC",ohl="O   $(price(b.open))    H   $(price(b.high))",
          lcl="L   $(price(b.low))    C   $(price(b.price))",vol="Vol   $(b.volume)   ·   "*(b.closed ? "Closed" : "Open"))]
    else
        []
    end
    return (;header,buttons,bars,ticks,times,last_price,cursor,count,low,span,maxvolume=maximum((b.volume for b in rows);init=1e-8))
end

"""Connect the native window's market and input events to Vellum's frame presenter."""
function native_window(symbol,view,platform;renderer=:cpu,before_swap=(w,b)->nothing)
    H = Vellum.GLHost
    H.with_frame_window(plot.width,plot.height,symbol*" · Spot";platform,target=renderer) do window,present
        bars = NamedTuple[]
        interval,request_interval = "1m",""
        visible,anchor,previous_mouse,drag = 48,nothing,false,nothing
        status = "Connecting to Binance…"
        request,next_poll,delay,refreshed,previous = nothing,0.0,3,0,nothing
        while !H.should_close(window)
            H.poll_events(window)
            H.key_state(window,256)!=0 && break
            if isnothing(request) && time()>=next_poll
                request_interval = interval
                url = endpoints(symbol;interval,limit=240).history
                request = @async try
                    history(url)
                catch err
                    sprint(showerror,err)
                end
            end
            if request !== nothing && istaskdone(request)
                value = fetch(request)
                request = nothing
                if request_interval==interval
                    if value isa AbstractString
                        status = first("Binance unavailable · "*value,76)
                        delay = min(60,delay*2)
                    else
                        bars = value
                        delay = 3
                        status = "Updating via REST · "*Dates.format(now(UTC),"HH:MM:SS")*" UTC"
                    end
                    refreshed += 1
                    next_poll = time()+delay
                end
            end
            extent = H.framebuffer_size(window)
            ww,wh = H.window_size(window)
            if min(ww,wh,extent...)>0
                cx,cy = H.cursor_position(window)
                x,y = cx*plot.width/ww,cy*plot.height/wh
                lastindex = isnothing(anchor) ? length(bars) : count(b->b.time<=anchor,bars)
                mouse = H.mouse_button_state(window,0)!=0
                if mouse && !previous_mouse
                    button = findfirst(b->b.x<=x<b.x+b.w && b.y<=y<b.y+b.h,controls)
                    if button !== nothing
                        if button<=4 && interval!=intervals[button]
                            interval = intervals[button]
                            empty!(bars)
                            anchor,next_poll,status = nothing,0.0,"Loading "*interval*" candles…"
                            refreshed += 1
                        elseif button==5
                            visible = min(96,round(Int,1.5visible))
                        elseif button==6
                            visible = max(12,round(Int,0.75visible))
                        elseif button==7
                            anchor = nothing
                        end
                    elseif plot.left<=x<plot.right && plot.top<=y<=plot.volume_bottom
                        drag = (x,lastindex)
                    end
                elseif mouse && drag!==nothing && !isempty(bars)
                    idx = clamp(drag[2]+round(Int,(drag[1]-x)*visible/(plot.right-plot.left)),min(visible,length(bars)),length(bars))
                    anchor = idx==length(bars) ? nothing : bars[idx].time
                elseif !mouse
                    drag = nothing
                end
                previous_mouse = mouse
                stop = isnothing(anchor) ? length(bars) : clamp(count(b->b.time<=anchor,bars),min(visible,length(bars)),length(bars))
                shown = @view bars[max(1,stop-visible+1):stop]
                index = plot.top<=y<=plot.volume_bottom && plot.left<=x<plot.right ? floor(Int,(x-plot.left)*length(shown)/(plot.right-plot.left)) : -1
                key = (refreshed,interval,visible,anchor,index,index>=0 ? round(Int,y) : 0,extent)
                if key != previous
                    latest = isempty(bars) ? nothing : last(bars)
                    model = chart_model(symbol,shown,status;interval,latest,index,y,following=isnothing(anchor))
                    present(drawing(view,model);before_swap=image->before_swap(window,shown))
                    previous = key
                end
            end
            H.wait_events(window,0.04)
            sleep(0.001)
        end
    end
end
