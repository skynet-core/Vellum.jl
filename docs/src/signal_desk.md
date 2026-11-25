```@meta
EditURL = "../../tutorials/signal_desk.jl"
```

# Build a retained signal dashboard

Select a channel and switch between the hourly and daily samples. The meter,
chart and summary all read the same selection. The three traces use example
measurements so you can repeat every interaction offline.

````@example signal_desk
using Vellum
include(joinpath(pkgdir(Vellum),"tutorials","Studio.jl"))
using .Studio
````

## 1. Give every channel a scale and a meaning

Store samples as percentages. The pair of colors describes the low and high
ends of the meter. Both the touch target and the drawn chip use the same
rectangle, so a host can map a pointer, touch or keyboard action onto it.

````@example signal_desk
names = ("Compute","Memory","Network")
ramps = ((0x478961,0xb7eb5a),(0x266cca,0x45dbef),(0x923e88,0xfa68a5))
samples = ((23,42,35,63,52,81,73), (30,24,52,42,68,56,65), (16,37,25,46,34,58,48))
chips = [widget(names[i],:button,(24+113(i-1),310,105,42)) for i in 1:3]
period = (;widget("Sample period",:segments,(430,310,180,42),2)...,labels=("Hour","Day"))
controls = [chips...,period]
````

## 2. Draw the fixed layout once

Use the same rounded card for a narrow meter bank and a wide chart. In
Studio.jl, card! draws the one-unit border first and insets the content.
Keep grid lines and labels in the background layer so a selection can
change without replacing them.

````@example signal_desk
function dashboard_back(e,f)
    rectangle!(e,0,0,636,378;fill=ink(0x191d2a))
    label!(e,f,"Signal desk",24,51,36,0xf3f4f8)
    label!(e,f,"Resource utilization",26,78,16,0xafb9cb)
    card!(e,24,101,224,188,16,0x424a62,0x24293a)
    card!(e,262,101,348,188,16,0x424a62,0x222737)
    label!(e,f,"Channels",40,130,17,0xf3f4f8)
    label!(e,f,"Utilization",280,130,17,0xf3f4f8)
    for (y,value) in ((158,"100"),(205,"50"),(252,"0"))
        rectangle!(e,309,y,276,1;fill=ink(0x394055))
        label!(e,f,value,279,y+4,11,0xa9b3ca)
    end
end
````

## 3. Derive several components from a single model

Change the selected channel to emphasize its trace. The foreground draws
that trace last, with a marker at each sample. To build a capsule meter,
compare each segment's midpoint with the latest value. Its label gives the
exact percentage where a twelve-segment meter can only approximate it.

````@example signal_desk
function dashboard_front(e,f,(channel,period))
    for i in (filter(!=(channel),1:3)...,channel)
        values = period == 1 ? samples[i] : mod.(samples[i] .+ (11i,4,6,19,9,2,13),84) .+ 6
        latest = last(values)
        y = 148+43(i-1)
        label!(e,f,names[i],40,y+9,13,0xc8cede)
        label!(e,f,string(latest,"%"),197,y+9,13,ramps[i][2])
        for j in 1:12
            x = 40+15(j-1)
            paint = (j-0.5)/12 <= latest/100 ? gradient((x,y+13),(x,y+30),ramps[i][2],ramps[i][1]) : ink(0x41485e)
            roundbox!(e,x,y+13,10,17,5,paint)
        end
        points = [(311+45(j-1),252-0.94v) for (j,v) in pairs(values)]
        trace!(e,points,i==channel ? ramps[i][2] : ramps[i][1],i==channel ? 3.6 : 1.6)
        if i==channel
            for (x,y) in points
                roundbox!(e,x-3.5,y-3.5,7,7,3.5,ramps[i][2])
            end
            label!(e,f,string(latest,"%"),500,57,38,ramps[i][2])
        end
        x,cy,w,h = chips[i].rect
        card!(e,x,cy,w,h,20,i==channel ? ramps[i][2] : 0x41485e,i==channel ? 0x323a4d : 0x222737)
        label!(e,f,names[i],x+17,cy+26,15,0xe5e9f1)
    end
    label!(e,f,period==1 ? "Past hour" : "Past day",311,272,12,0xaeb8cc)
    card!(e,430,310,180,42,20,0x424a62,0x24293a)
    roundbox!(e,433+90(period-1),313,84,36,18,0x414b62)
    label!(e,f,"Hour",459,337,15,0xf0f2f7)
    label!(e,f,"Day",551,337,15,0xf0f2f7)
end
````

## 4. Connect the retained drawing to both hosts

The first three actions select a channel. The two stops of the last control
select a time period and preserve the channel. Each revision shares its
fixed nodes with the previous revision. Inspect the assertion, then select
Network and Day and compare the percentage, markers and meter.

````@example signal_desk
states = [(c,p) for c in 1:3 for p in 1:2]
dashboard_update((c,p),control,stop) = control <= 3 ? (control,p) : (c,stop)
panel = application("Signal desk",states,controls,retained_view((636,378),dashboard_back,dashboard_front),
                    dashboard_update,(s,i)->i==4 ? s[2] : 1)
@assert first(panel.frames).canvas == last(panel.frames).canvas
@assert first(panel.frames).nodes[1] === last(panel.frames).nodes[1]
open_studio(panel,"signal-desk")
````

```@raw html
<p><a href="apps/signal-desk.html">Open the interactive signal desk</a></p>
```

Set VELLUM_TUTORIAL_HOST to wayland or x11 before running the script for a
native window. Set VELLUM_TUTORIAL_RENDERER to vulkan or opengl for native
drawing, or webgl2 in the browser. Tab between controls and use Space to
activate a chip. The arrow keys change the selected period.
