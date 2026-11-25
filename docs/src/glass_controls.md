```@meta
EditURL = "../../tutorials/glass_controls.jl"
```

# Build an animated glass toolbar

Build a small map viewer with two reusable controls. **Route** shows a walking
route and **Places** labels the coves. Hover to lift a control, hold to press
it, and release over it to toggle a map layer. Drag outside before releasing
to cancel. Tab and Shift+Tab move focus. Space and Enter activate a switch.

Apple's Liquid Glass guidance places controls on a distinct layer above
content. We'll make a portable interpretation of that material by magnifying
the underlying map inside a curved lens, tinting it and painting its edges.
The map, lens, symbols, lettering, press animation and keyboard focus ring
are Vellum drawing commands. The canvas hit-tests the same rectangles.
Its fallback descendants expose the switches to keyboard and assistive technology.
[Apple's materials guide](https://developer.apple.com/design/human-interface-guidelines/materials)

````@example glass_controls
using Vellum
include(joinpath(pkgdir(Vellum),"tutorials","Studio.jl"))
using .Studio
````

## 1. Give the controls a shared geometry

One descriptor supplies the label, position and semantic role for drawing,
hit testing and accessibility. Keep the hit rectangle fixed while its visual
surface moves under the pointer. Here both controls are switches because
their on/off values persist after release.

````@example glass_controls
"""A map-layer switch with a fixed logical hit rectangle and a drawn symbol."""
struct LayerSwitch
    label::String
    rect::NTuple{4,Int}
    symbol::Symbol
end
switches = [LayerSwitch("Route",(34,294,119,48),:route),
            LayerSwitch("Places",(159,294,125,48),:places)]
controls = [widget(c.label,:switch,c.rect) for c in switches]
extent = (640,374)
````

## 2. Record the map underneath the glass

Our imaginary coastline is one cubic path. Vary its horizontal offset to
make depth contours. Reusing this vector drawing inside the toolbar will
make the coastline bend very slightly at the glass boundary.

````@example glass_controls
"""Return the coast contour. Closing it along the left border makes the mainland."""
function coastline(offset;land=false)
    segments = Tuple[(:move,345+offset,-12),(:cubic,415+offset,58,264+offset,63,300+offset,107),
        (:cubic,340+offset,151,472+offset,107,414+offset,178),
        (:cubic,381+offset,222,193+offset,204,245+offset,275),
        (:cubic,277+offset,319,199+offset,340,208+offset,389)]
    land && append!(segments,[(:line,-16,389),(:line,-16,-12),(:close,)])
    PathData(Tuple(segments))
end

"""Paint a continuous bathymetric map at any affine transform."""
function paint_map!(e)
    rectangle!(e,-16,-16,672,406;fill=gradient((30,0),(610,374),0x8ed2c6,0x246885))
    for offset in (74,56,40,27,16,8)
        configure!(e;stroke=Solid(0.91,1.0,0.97,0.34),stroke_style=StrokeStyle(width=1))
        draw(e,coastline(offset);mode=:stroke)
    end
    configure!(e;fill=ink(0xf3dfa7))
    draw(e,coastline(0;land=true))
    configure!(e;fill=gradient((0,0),(360,360),0xf5e7c6,0xcfb683))
    draw(e,coastline(-5;land=true))
    for offset in (-21,-44,-72,-108,-153)
        configure!(e;stroke=Solid(0.50,0.39,0.20,0.22),stroke_style=StrokeStyle(width=1))
        draw(e,coastline(offset);mode=:stroke)
    end
end

include(joinpath(pkgdir(Vellum),"tutorials","glass","GlassMaterial.jl"))
using .GlassMaterial
````

## 3. Cast the shadow and draw the glass

A floating toolbar occludes light below it. Rasterize the very same silhouette
used by the lens into a transparent mask. Give the mask room on every side
for the Gaussian kernel and its offset. The narrow shadow stays close to the
lower rim. A wider, lighter shadow fades into the contour lines below it.
Both layers take their shape from the mask's alpha.
The shared GlassMaterial.jl implements these two passes with Vellum.shadow.
Record the shadow as one image in the fixed background. The browser and
native backends composite that same resource beneath the lens. Hovering or
pressing a switch reuses it.

Clip before applying the magnifying transform. This holds the glass boundary
still while its content changes scale around the center. A dark translucent
tint gives the labels contrast against sand and water. The rim and specular
line are separate strokes. All devices render these paths directly.

````@example glass_controls
"""Draw the lens over the static map and add a narrow reflective upper edge."""
function paint_lens!(e)
    x,y,w,h = 24,285,271,66
    lens = capsule(x,y,w,h)
    cast_shadow,destination = lens_shadow(lens,x,y,w,h)
    draw_image!(e,resource!(e,cast_shadow),destination)
    save(e)
    clip(e,lens)
    s = 1.16
    transform!(e,Transform2D(s,0,0,s,(1-s)*(x+w/2),(1-s)*(y+h/2)))
    paint_map!(e)
    restore(e)
    configure!(e;fill=Solid(0.06,0.15,0.18,0.79))
    draw(e,lens)
    configure!(e;stroke=Solid(1,1,1,0.70),stroke_style=StrokeStyle(width=1.4))
    draw(e,lens;mode=:stroke)
    trace!(e,[(57,287),(258,287)],0xc9dad0,1)
end

"""Compose the fixed backdrop, chart title, scale and floating toolbar."""
function atlas_back!(e,font)
    paint_map!(e)
    roundbox!(e,25,28,29,4,2,0xa95538)
    label!(e,font,"Pelican Sound",24,79,38,0x253d3e)
    label!(e,font,"Coastal walking map",27,104,17,0x465751)
    label!(e,font,"N",585,46,15,0xe8f5e9)
    trace!(e,[(582,71),(591,51),(600,71),(591,67),(582,71)],0xe8f5e9,2)
    trace!(e,[(527,337),(527,344),(601,344),(601,337)],0xe6f3e9,2)
    label!(e,font,"500 m",547,333,13,0xe6f3e9)
    paint_lens!(e)
end

"""Paint the same route or place glyph in the control and map legend."""
function glyph!(e,symbol,x,y,color)
    if symbol === :route
        trace!(e,[(x,y+5),(x+6,y-4),(x+12,y+2),(x+18,y-6)],color,2)
        for (dx,dy) in ((0,5),(18,-6))
            roundbox!(e,x+dx-2.5,y+dy-2.5,5,5,2.5,color)
        end
    else
        path = PathData(((:move,x+9,y+9),(:cubic,x+4,y+4,x+1,y+1,x+1,y-3),
            (:cubic,x+1,y-13,x+17,y-13,x+17,y-3),(:cubic,x+17,y+1,x+14,y+4,x+9,y+9),(:close,)))
        configure!(e;stroke=ink(color),stroke_style=StrokeStyle(width=1.8))
        draw(e,path;mode=:stroke)
        roundbox!(e,x+7,y-5,4,4,2,color)
    end
end

"""Draw one switch with a lens highlight, a press displacement and a keyboard focus ring."""
function paint_switch!(e,font,c,enabled,level,focused)
    x,y,w,h = c.rect
    lift = sinpi(min(level,3)/6)
    press = max(0,(level-3)/3)
    inset = 2+2press-lift
    y += 1.5press-1.5lift
    if focused
        configure!(e;stroke=Solid(0.80,0.96,1),stroke_style=StrokeStyle(width=2))
        draw(e,capsule(x-1,y-1,w+2,h+2);mode=:stroke)
    end
    paint = enabled ? Solid(0.88,0.96,0.87,0.86+0.1lift) : Solid(0.94,0.99,0.98,0.08+0.19lift)
    roundbox!(e,x+inset,y+inset,w-2inset,h-2inset,h/2-inset,paint)
    fg = enabled ? 0x213d3c : 0xf1f8f2
    glyph!(e,c.symbol,x+14,y+24,fg)
    label!(e,font,c.label,x+41,y+30,17,fg)
    enabled && roundbox!(e,x+w-17,y+22,5,5,2.5,fg)
end
````

## 4. Separate a gesture from its command

The model is (visible layers, active control, requested phase, animation level).
Hover and keyboard focus target level 3. Press targets 6. Leaving targets 0.
Each clock tick moves one level toward the current target, so releasing halfway
through a press reverses from the current position. A release inside or a
keyboard activation commits the switch. Pointer cancellation only releases it.
Store two layer choices as bits: Route is 1 and Places is 2.

````@example glass_controls
goal(phase) = phase === :press ? 6 : phase === :idle ? 0 : 3
ison(mask,i) = !iszero(mask & (1 << (i-1)))
initial = (1,0,:idle,0)
"""Apply a host-neutral event and return the next map model."""
function respond((mask,owner,phase,level),i,event)
    if event === :activate
        return (xor(mask,1 << (i-1)),owner,phase,level)
    elseif event === :tick
        level += sign(goal(phase)-level)
    else
        if i != 0 && i != owner
            owner,level = i,0
        end
        phase = event
    end
    return phase === :idle && level == 0 ? (mask,0,:idle,0) : (mask,owner,phase,level)
end

"""Draw selected layers and the current visual response of each reusable switch."""
function atlas_front!(e,font,(mask,owner,phase,level))
    if ison(mask,1)
        points = [(231,122),(250,145),(276,151),(294,175),(276,191),(242,206),(220,233),(189,248)]
        trace!(e,points,0xfff2cb,6)
        trace!(e,points,0x9f432e,3)
        for (x,y) in (first(points),last(points))
            roundbox!(e,x-5,y-5,10,10,5,0xfbf1d4)
            roundbox!(e,x-3,y-3,6,6,3,0x953b2d)
        end
    end
    if ison(mask,2)
        for (x,y,label) in ((291,88,"Shell Cove"),(366,182,"East Point"),(204,248,"Fern Beach"))
            roundbox!(e,x-3,y-3,6,6,3,0x263f41)
            label!(e,font,label,x+8,y-5,14,0x19393a)
        end
    end
    for (i,c) in pairs(switches)
        paint_switch!(e,font,c,ison(mask,i),owner==i ? level : 0,owner==i && phase===:focus)
    end
end
````

## 5. Compile the component model for both hosts

Start with the initial state and visit only reachable states. The first
columns activate switches. Vellum assigns the remaining columns to visual
feedback and the clock. Equal-looking states share a recorded frame. The
map and the lens keep the same retained nodes across all revisions.

````@example glass_controls
events = [(i,:activate) for i in eachindex(controls)]
push!(events,(0,:idle))
for i in eachindex(controls), phase in (:hover,:press,:focus)
    push!(events,(i,phase))
    @assert length(events) == Vellum.feedback_action(controls,i,phase)
end
push!(events,(0,:tick))
tick = Vellum.feedback_action(controls,0,:tick)
@assert tick == length(events)

"""Enumerate reachable states once and build a shared interactive drawing."""
function make_atlas()
    states = [initial]
    indices = Dict(initial=>1)
    rows = Vector{Int}[]
    for state in states
        row = Int[]
        for (i,event) in events
            dest = respond(state,i,event)
            index = get!(indices,dest) do
                push!(states,dest)
                length(states)
            end
            push!(row,index)
        end
        push!(rows,row)
    end
    view = retained_view(extent,atlas_back!,atlas_front!)
    cache = Dict{Tuple{Int,Int,Bool,Int},Frame}()
    frames = map(states) do state
        mask,owner,phase,level = state
        get!(()->view(state),cache,(mask,owner,phase===:focus,level))
    end
    transitions = permutedims(hcat(rows...))
    values = [1+ison(s[1],i) for s in states,i in eachindex(controls)]
    timers = [s[4]==goal(s[3]) ? (0,0) : (30,tick) for s in states]
    InteractiveDrawing("Pelican Sound",frames,controls,transitions,values;timers,feedback=true)
end
atlas = make_atlas()
@assert atlas.frames[1].nodes[1] === atlas.frames[atlas.transitions[1,1]].nodes[1]
````

## 6. Switch platforms and inspect the result

Run the final cell to open the browser version inline in Jupyter, or open
glass-controls.html after running the script. Set the two variables below
before running the script to choose a host and renderer. The drawing and
reducer are shared across all combinations.

| Host | Renderer | Result |
|:-----|:---------|:-------|
| browser | webgl2, canvas, webgpu | Offline HTML with an embedded Wasm module |
| desktop | cpu | System GLFW window, including the macOS desktop host |
| x11 or wayland | opengl, vulkan, cpu | Linux desktop window |

On Linux the OpenGL drawing provider needs an X11 or XWayland display,
including when Wayland presents its result. Vulkan needs a Vulkan-enabled
GTK 4.14+ desktop. The native presenter reads back the frame and blits it.
Browser Reduce Motion settles animations immediately. Set VELLUM_REDUCED_MOTION
to 1 for the same behavior in a Julia window.

```julia
ENV["VELLUM_TUTORIAL_HOST"] = "x11"
ENV["VELLUM_TUTORIAL_RENDERER"] = "vulkan"
include(joinpath(pkgdir(Vellum),"tutorials","glass_controls.jl"))
```

````@example glass_controls
open_studio(atlas,"glass-controls")
````

```@raw html
<p><a href="apps/glass-controls.html">Open the interactive glass toolbar</a></p>
```
