# # Animate a glass market panel
#
# Build the entrance of a market dashboard like the supplied motion study.
# The fixed graphite backdrop shows through tinted panels. A lime price trace
# draws on after the cards appear. Use Replay to watch the entrance, or drag
# the scrubber to inspect its timing. Prices in this lesson are sample data.
using Vellum
include(joinpath(pkgdir(Vellum),"tutorials","Studio.jl"))
using .Studio

# ## 1. Separate the backdrop and the glass
#
# Give the backdrop a directional light source. The diagonal bands make the
# panel's transparency visible. Use the same card component as the signal
# dashboard, then draw it inside an opacity group. This composites the card
# as one surface, including its border.
function glass_back(e,f)
    rectangle!(e,0,0,636,390;fill=gradient((0,390),(636,0),0x111919,0x53615c))
    for x in -500:80:640
        path = PathData(((:move,x,390),(:line,x+25,390),(:line,x+263,0),(:line,x+238,0),(:close,)))
        configure!(e;fill=Solid(0.06,0.09,0.09,0.32))
        draw(e,path)
    end
    label!(e,f,"Market overview",27,54,35,0xf5f6ee)
    label!(e,f,"Spot market   /   BTC · USD",29,80,15,0xc4cec9)
    card!(e,24,313,588,57,16,0x65716a,0x222b28)
end

# ## 2. Reveal two cards on a staggered timeline
#
# Give each card a local progress value. The cubic curve slows each card as
# it approaches its final position. After the entrance, progressively
# interpolate the endpoint of the next line segment so the trace grows
# continuously between known prices.
ease(t) = 1-(1-clamp(t,0,1))^3
function glass_front(e,f,(step,playing))
    t = (step-1)/12
    price = ease(t/0.62)
    chart = ease((t-0.12)/0.72)
    y = 108+18(1-price)
    with_group(e;opacity=0.18+0.78price) do g
        card!(g,24,y,189,183,17,0xa8b7aa,gradient((24,y),(213,y+183),0x424e47,0x222c29))
        label!(g,f,"Bitcoin",40,y+36,19,0xf0f3e9)
        label!(g,f,"64,284",40,y+92,41,0xffffff)
        roundbox!(g,40,y+109,75,26,13,0x475e3b)
        label!(g,f,"+2.18%",50,y+128,14,0xd3f39e)
        label!(g,f,"Sample close · USD",40,y+161,14,0xc7d2ca)
    end
    y = 108+28(1-chart)
    with_group(e;opacity=0.14+0.82chart) do g
        card!(g,226,y,386,183,17,0x92a298,gradient((226,y),(612,y+183),0x3e4a43,0x202a26))
        label!(g,f,"Price trend",244,y+34,18,0xf2f6ee)
        for ly in (60,95,130)
            rectangle!(g,245,y+ly,346,1;fill=ink(0x52605a))
        end
        values = (125,124,103,109,84,88,89,67,78,57,64,55,60,43,49)
        progress = clamp((t-0.17)/0.83,0,1)*(length(values)-1)
        index = min(1+floor(Int,progress),length(values)-1)
        points = [(245+(i-1)*24.5,y+values[i]) for i in 1:index]
        fpart = progress-(index-1)
        endpoint = (245+24.5progress,y+values[index]+fpart*(values[index+1]-values[index]))
        push!(points,endpoint)
        if progress>0
            trace!(g,points,0xc8f080,3)
            roundbox!(g,endpoint[1]-4,endpoint[2]-4,8,8,4,0xe3ffbc)
        end
        label!(g,f,"09:00",245,y+161,12,0xc7d2ca)
        label!(g,f,"16:00 UTC",529,y+161,12,0xc7d2ca)
    end
    roundbox!(e,34,323,102,36,18,0xc7eb92)
    label!(e,f,playing ? "Playing" : "Replay",57,347,16,0x203020)
    label!(e,f,"Reveal",153,347,15,0xe4ebe5)
    roundbox!(e,220,339,308,5,2.5,0x617267)
    t>0 && roundbox!(e,220,339,308t,5,2.5,0xc7eb92)
    roundbox!(e,213+308t,334,15,15,7.5,0xe3ffbc)
    label!(e,f,string(round(Int,100t),"%"),548,347,15,0xe4ebe5)
end

# ## 3. Let time and user input drive the same reducer
#
# There are thirteen poses. Replay starts the first pose and requests a tick
# every 55 milliseconds. A tick advances one pose. Dragging the slider
# cancels the pending tick and holds that position. The final pose holds
# until the next interaction. This keeps the app still when idle.
controls = [widget("Replay entrance",:button,(34,319,102,44)),
            widget("Reveal progress",:range,(220,319,308,44),13)]
states = [(13,false); [(i,false) for i in 1:12]; [(i,true) for i in 1:12]]
function motion_update((pose,playing),control,stop)
    control == 2 && return (stop,false)
    playing || return (1,true)
    return (pose+1,pose+1<13)
end
tick(s) = s[2] ? (55,1) : (0,0)
preview = application("Market overview",states,controls,retained_view((636,390),glass_back,glass_front),
                      motion_update,(s,i)->i==2 ? s[1] : 1;timer=tick)
@assert motion_update((8,true),2,4) == (4,false)
open_studio(preview,"glass-market")

#md # ```@raw html
#md # <p><a href="apps/glass-market.html">Play and scrub the market panel</a></p>
#md # ```
#
# The browser dispatches the timed action through Wasm. A Wayland or X11
# window dispatches the same action from its monotonic clock. To compare
# renderers, run the script again with VELLUM_TUTORIAL_HOST set to x11 and
# VELLUM_TUTORIAL_RENDERER set to opengl or vulkan. Tab to the slider and
# press an arrow to move one pose at a time.
