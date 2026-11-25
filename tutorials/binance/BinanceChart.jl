"""A live Spot chart with one Vellum drawing definition for web and native hosts."""
module BinanceChart
using Vellum, Base64, Dates, Downloads
using Vellum: @browser
import JSON
include("../Workshop.jl")
using .Workshop

"""Number of candles initially shown in the price and volume panes."""
const capacity = 48
"""Supported Binance Spot kline intervals."""
const intervals = ("1m","5m","15m","1h")
"""Labeled hit targets, in the same logical units as the drawing."""
const controls = [(label=name,x=14+64(i-1),y=62,w=60,h=28) for (i,name) in pairs((intervals...,"−","+","Latest"))]
"""Logical chart dimensions and price/volume plot bounds."""
const plot = (width=704,height=420,left=12,right=624,top=112,bottom=307,volume_top=320,volume_bottom=360)

"""Return the public REST and WebSocket endpoints for the requested Spot instrument and interval."""
function endpoints(symbol;interval="1m",limit=capacity)
    occursin(r"^[A-Z0-9]{2,20}$",symbol) || throw(ArgumentError("invalid Binance symbol"))
    interval in intervals || throw(ArgumentError("invalid interval"))
    1 <= limit <= 240 || throw(ArgumentError("expected 1 to 240 candles"))
    return (history="https://data-api.binance.vision/api/v3/klines?symbol=$symbol&interval=$interval&limit=$limit",
            stream="wss://data-stream.binance.vision/ws/"*lowercase(symbol)*"@kline_"*interval)
end

"""
    chart_view() -> DataDrawing

Build the chart from Vellum rectangles and font labels. Each layer names a collection
of model rows. Every coordinate below runs unchanged on all supported renderers.
"""
function chart_view()
    background = drawing_layer(:header) do e,h,m
        rectangle!(e,0,0,plot.width,plot.height;fill=0x131922)
        draw_label!(e,h.pair,16,36;size=28,fill=0xe6edf4)
        draw_label!(e,"Binance Spot   ·   UTC",17,55;size=14,fill=0xa9b6c8)
        draw_label!(e,h.price,538,36;size=24,fill=h.color)
        draw_label!(e,h.status,15,406;size=13,fill=0xb6c3d4)
        draw_label!(e,"VOL",633,348;size=12,fill=0xb9c3d2)
    end
    toolbar = drawing_layer(:buttons) do e,b,m
        rectangle!(e,b.x,b.y,b.w,b.h;fill=b.color)
        draw_label!(e,b.label,b.x+10,b.y+19;size=14,fill=0xe3ebf5)
    end
    grid = drawing_layer(:ticks) do e,t,m
        y = plot.top+t.fraction*(plot.bottom-plot.top)
        rectangle!(e,plot.left,y,plot.right-plot.left,0.8;fill=0x29313f)
        draw_label!(e,t.label,630,y+4;size=11,fill=0xb9c3d2)
    end
    candles = drawing_layer(:bars) do e,b,m
        step = (plot.right-plot.left)/m.count
        center = plot.left+(b.index+0.5)*step
        width = min(18,0.64step)
        price_y(p) = plot.bottom-(plot.bottom-plot.top)*(p-m.low)/m.span
        rectangle!(e,center-0.7,price_y(b.high),1.4,max(1,price_y(b.low)-price_y(b.high));fill=b.color)
        top,bottom = price_y(max(b.open,b.price)),price_y(min(b.open,b.price))
        rectangle!(e,center-width/2,top,width,max(1.5,bottom-top);fill=b.color)
        height = (plot.volume_bottom-plot.volume_top)*b.volume/m.maxvolume
        rectangle!(e,center-width/2,plot.volume_bottom-height,width,height;fill=b.volume_color)
    end
    times = drawing_layer(:times) do e,t,m
        x = plot.left+(t.index+0.5)*(plot.right-plot.left)/m.count
        draw_label!(e,t.label,max(3,x-16),381;size=12,fill=0xa9b4c6)
    end
    marker = drawing_layer(:last_price) do e,q,m
        y = plot.bottom-(plot.bottom-plot.top)*(q.value-m.low)/m.span
        rectangle!(e,plot.left,y,plot.right-plot.left,0.7;fill=q.color)
        rectangle!(e,625,y-9,79,18;fill=q.color)
        draw_label!(e,q.label,628,y+4;size=12,fill=0x131922)
    end
    cursor = drawing_layer(:cursor) do e,c,m
        center = plot.left+(c.index+0.5)*(plot.right-plot.left)/m.count
        rectangle!(e,center,plot.top,0.8,plot.volume_bottom-plot.top;fill=0x8b99ad)
        rectangle!(e,plot.left,c.y,plot.right-plot.left,0.8;fill=0x8b99ad)
        x = max(14,min(center+12,plot.right-230))
        rectangle!(e,x,119,225,105;fill=0x263140)
        draw_label!(e,c.stamp,x+10,139;size=14,fill=0xffffff)
        draw_label!(e,c.ohl,x+10,161;size=13,fill=0xdce7f2)
        draw_label!(e,c.lcl,x+10,183;size=13,fill=0xdce7f2)
        draw_label!(e,c.vol,x+10,206;size=13,fill=0xdce7f2)
    end
    return DataDrawing("Live Spot candlesticks",(plot.width,plot.height),Workshop.face,
                       [background,toolbar,grid,candles,times,marker,cursor])
end

include("browser.jl")
include("native.jl")

"""
    launch(symbol="BTCUSDT"; host=:browser, renderer, directory=pwd())

Open the chart on a native host or write an independent live browser application.
Browser renderers include Canvas, WebGL2 and WebGPU. Native renderers include CPU,
OpenGL and Vulkan. The data source and drawing definition are shared.
"""
function launch(symbol="BTCUSDT";view=chart_view(),host=:browser,renderer=host===:browser ? :webgl2 : :cpu,
                directory=get(ENV,"VELLUM_TUTORIAL_OUTPUT",pwd()))
    urls = endpoints(symbol;limit=240)
    host in (:wayland,:x11) && return native_window(symbol,view,host;renderer)
    host === :browser || throw(ArgumentError("expected :browser, :wayland or :x11"))
    mkpath(directory)
    path = joinpath(directory,"candlesticks.html")
    bundled_font_notice = read(joinpath(pkgdir(Vellum),"test","fixtures","LiberationSans-LICENSE.txt"),String)
    config = (;symbol,urls...,controls,intervals,plot,bundled_font_notice)
    savehtml(path,view;target=renderer,config,driver=start_chart,module_path=joinpath(directory,"candlesticks.wasm"))
    if isdefined(Main,:IJulia) && Main.IJulia.inited
        src = "data:text/html;base64,"*base64encode(read(path))
        display(MIME"text/html"(),"""<iframe title="Live Binance candlesticks" style="width:100%;max-width:790px;height:510px;border:0" src="$src"></iframe>""")
    end
    return path
end
end
