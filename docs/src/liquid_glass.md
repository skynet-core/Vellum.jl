```@meta
EditURL = "../../tutorials/liquid_glass.jl"
```

# Build a Liquid Glass UI framework

Build a reusable set of glass controls, then use it to make a sound panel.
**Spatial audio** changes the listening mode, the level slider changes the
volume and **Reset mix** restores the defaults. Hover, hold, drag away or
navigate with Tab. The controls draw their own focus, hover and press states.
Try changing the accent color or adding a second button bound to a new action.

## 1. Define the widget contract

A component has a semantic role, a logical hit rectangle and an application
action. The framework translates input into actions. The application decides
what they mean. Coordinates stay the same on a desktop and in the browser.

````@example liquid_glass
using Vellum

using Vellum
include(joinpath(pkgdir(Vellum),"tutorials","Studio.jl"))
using .Studio
include(joinpath(pkgdir(Vellum),"tutorials","glass","GlassMaterial.jl"))
using .GlassMaterial
export glass_button, glass_switch, glass_slider, glass_app, material!, open_studio

"""A drawable control with a semantic input descriptor and an application action."""
struct Control
    input::NamedTuple
    action::Symbol
end
"""Create a momentary push button."""
glass_button(label,rect,action) = Control(widget(label,:button,rect),action)
"""Create a switch whose reader returns 1 for off or 2 for on."""
glass_switch(label,rect,action) = Control(widget(label,:switch,rect),action)
"""Create a slider whose reader returns a position from 1 through stops."""
glass_slider(label,rect,action,stops) = Control(widget(label,:range,rect,stops),action)
````

## 2. Draw the material

First render the wallpaper with Vellum, including the curves we expect to
see through the plate. Crop the pixels behind the plate with a margin as wide
as the filter kernel and apply Vellum's Gaussian blur. Draw the filtered
pixels through the rounded clip at a slight magnification, then add a tint
and reflective rim. The shadow comes from the Gaussian-filtered alpha mask of
that same silhouette. All of this is in GlassMaterial.jl.

````@example liquid_glass
"""Prepare and draw the main glass plate from the actual wallpaper pixels."""
function material!(e,backdrop,rect,radius;blur_radius=12)
    plate = prepare_glass!(e,backdrop,rect,radius;blur_radius)
    paint_glass!(e,plate;zoom=1.075,light=0.18,dark=0.51)
end
````

## 3. Give each role a visual and an accessible value

The hit rectangle remains stationary while the surface lifts on hover and
settles inward on press. The switch draws a moving thumb, and the slider
maps its discrete value to the track length. A focused control gets an
explicit rim. Vellum delivers keyboard and pointer events on either host.

````@example liquid_glass
"""Paint a widget at its current value, animation level and focus state."""
function paint_control!(e,font,c,value,level,focused,accent,glass,thumb)
    input = c.input
    x,y,w,h = input.rect
    lift = sinpi(min(level,3)/6)
    press = max(0,(level-3)/3)
    elevation = 2lift-3press
    paint_glass!(e,glass;lift=elevation,zoom=1.14,light=0.27+0.10lift,dark=0.40)
    y -= elevation
    if focused
        configure!(e;stroke=Solid(0.93,0.93,1),stroke_style=StrokeStyle(width=2))
        draw(e,glass_outline(x-2,y-2,w+4,h+4,h/2+2);mode=:stroke)
    end
    function knob!(kx,ky,diameter)
        sx,sy,sw,sh = thumb.area
        scale = diameter/16
        draw_image!(e,thumb.image,(kx+sx*scale,ky+sy*scale,sw*scale,sh*scale))
        roundbox!(e,kx,ky,diameter,diameter,diameter/2,0xf9f8ff)
    end
    if input.kind === :switch
        label!(e,font,input.label,x+17,y+h/2+5,15,0xffffff)
        sx,sy = x+w-49,y+(h-20)/2
        roundbox!(e,sx,sy,35,20,10,value==2 ? accent : 0x5a566c)
        knob!(sx+(value==2 ? 17 : 2),sy+2,16)
    elseif input.kind === :range
        tx,tw = x+16,w-32
        ty = y+h-15
        knob = tx+tw*(value-1)/(input.steps-1)
        label!(e,font,input.label,x+17,y+18,13,0xffffff)
        label!(e,font,string(round(Int,100*(value-1)/(input.steps-1))),x+w-38,y+18,12,0xe3ddff)
        roundbox!(e,tx,ty-2,tw,4,2,0x645d75)
        knob>tx && roundbox!(e,tx,ty-2,knob-tx,4,2,accent)
        knob!(knob-7,ty-7,14)
    else
        label!(e,font,input.label,x+16,y+h/2+5,14,0xffffff)
    end
end
````

## 4. Compile the input model once

For this finite-state framework, a state holds the application's model, the
active control, a requested feedback phase and an animation level. A clock
tick advances one level. A command invokes the user's reducer. Enumerate
reachable states and record one frame for each distinct visual appearance.
This approach suits a small bounded control panel. Every additional independent
setting increases the number of reachable states.

````@example liquid_glass
"""Build an InteractiveDrawing from controls, a pure reducer, a value reader and a fixed background."""
function glass_app(title,size,controls,initial,reduce,read_value,background;accent=0xcbb5ff)
    inputs = [c.input for c in controls]
    events = [(i,:command,j) for (i,c) in enumerate(inputs) for j in 1:c.steps]
    push!(events,(0,:idle,0))
    for i in eachindex(controls), phase in (:hover,:press,:focus)
        push!(events,(i,phase,0))
        @assert length(events)==feedback_action(inputs,i,phase)
    end
    push!(events,(0,:tick,0))
    target(phase) = phase===:press ? 6 : phase===:idle ? 0 : 3
    function advance(state,event)
        model,owner,phase,level = state
        i,kind,stop = event
        if kind===:command
            model = reduce(model,controls[i].action,stop)
        elseif kind===:tick
            level += sign(target(phase)-level)
        else
            if i>0 && i!=owner
                owner,level = i,0
            end
            phase = kind
        end
        return (model,phase===:idle && level==0 ? 0 : owner,phase,level)
    end
    states = [(initial,0,:idle,0)]
    ids = Dict(first(states)=>1)
    rows = Vector{Int}[]
    for state in states
        row = map(events) do event
            next = advance(state,event)
            get!(ids,next) do
                push!(states,next)
                length(states)
            end
        end
        push!(rows,row)
    end
    # Sample the finished plate underneath each control. Revisions share these
    # resources, so dragging the slider never reruns the Gaussian convolution.
    surfaces = NamedTuple[]
    thumb = Ref{NamedTuple}()
    function prepare_controls(e,frame)
        backdrop = rasterize(frame)
        for c in controls
            rect = c.input.rect
            push!(surfaces,prepare_glass!(e,backdrop,rect,rect[4]/2;
                                         blur_radius=7,shadow_radius=10,shadow_offset=4))
        end
        mask,area = lens_shadow(capsule(0,0,16,16),0,0,16,16;ambient_radius=5,ambient_offset=2)
        thumb[] = (;image=resource!(e,mask),area)
    end
    paint = retained_view(size,background,(e,font,state)->begin
        model,owner,phase,level = state
        for (i,c) in enumerate(controls)
            paint_control!(e,font,c,read_value(model,c.action),i==owner ? level : 0,
                           owner==i && phase===:focus,accent,surfaces[i],thumb[])
        end
    end;after_background=prepare_controls)
    visuals = Dict{Tuple,Frame}()
    frames = map(states) do s
        get!(() -> paint(s),visuals,(s[1],s[2],s[3]===:focus,s[4]))
    end
    timers = [s[4]==target(s[3]) ? (0,0) : (30,length(events)) for s in states]
    values = [read_value(s[1],c.action) for s in states,c in controls]
    InteractiveDrawing(title,frames,inputs,permutedims(hcat(rows...)),values;timers,feedback=true)
end
````

## 5. Build a sound panel with the framework

The application supplies wallpaper, a title, three controls and a reducer.
The controls share the material and feedback code above. Edit the accent
or the starting volume, rerun this lesson and try the same gestures again.

````@example liquid_glass
"""Paint the sound panel's violet and apricot wallpaper in drawing coordinates."""
function wallpaper!(e)
    rectangle!(e,-40,-40,560,406;fill=gradient((0,0),(465,290),0x393668,0xa095df))
    for (offset,color) in ((78,0x615191),(48,0x9f85ce),(24,0xffc6a5),(0,0xcc8496))
        wave = PathData(((:move,-40,250-offset),(:cubic,120,40-offset,200,420-offset,520,94-offset),
                         (:line,520,380),(:line,-40,380),(:close,)))
        configure!(e;fill=ink(color))
        draw(e,wave)
    end
    # Fine contours make the optical difference visible across each glass edge.
    for offset in 0:7:49
        ridge = PathData(((:move,-30,75+offset),(:cubic,125,-60+offset,230,200+offset,510,55+offset)))
        configure!(e;stroke=Solid(0.94,0.88,1,0.66),stroke_style=StrokeStyle(width=1.3))
        draw(e,ridge;mode=:stroke)
    end
end
"""Draw a glass plate above the wallpaper and label the panel."""
function panel_background!(e,font)
    wallpaper!(e)
    rect = (25,24,430,264)
    wallpaper = rasterize(drawing(wallpaper!;size=(480,318)))
    material!(e,wallpaper,rect,34;blur_radius=12)
    label!(e,font,"Listening room",50,74,31,0xffffff)
end

controls = [glass_switch("Spatial audio",(48,95,262,44),:spatial),
            glass_slider("Volume",(48,151,384,58),:volume,4),
            glass_button("Reset mix",(48,225,104,38),:reset)]
defaults = (spatial=true,volume=3)
"""Apply the command emitted by a widget to the application's own model."""
function mix_update(model,action,stop)
    action===:spatial && return merge(model,(spatial=!model.spatial,))
    action===:volume && return merge(model,(volume=stop,))
    return defaults
end
"""Expose a one-based value to each component and its accessibility description."""
mix_value(model,action) = action===:spatial ? 1+model.spatial : action===:volume ? model.volume : 1
mixer = glass_app("Listening room",(480,318),controls,defaults,mix_update,mix_value,panel_background!;accent=0xc6b5ff)
open_studio(mixer,"liquid-glass")
````

## 6. Switch hosts

In the playground select Canvas 2D or WebGL2. For a native window, set
VELLUM_TUTORIAL_HOST to wayland or x11 and VELLUM_TUTORIAL_RENDERER to opengl
or vulkan before running this script. The same component tree, reducer and
recordings drive each renderer.
```@raw html
<p><a href="apps/liquid-glass.html">Open the interactive sound panel</a></p>
```
