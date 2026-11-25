```@meta
EditURL = "../../tutorials/touch_controls.jl"
```

# Build a small touch interface

Build a reading-light controller with a switch, stepped brightness slider
and two-position color selector. The grouped card, rounded controls and large
targets follow the iPhone settings patterns used in iOS 27.2. The example draws its own
controls with Vellum. Try it with touch, a mouse or the keyboard.

See Apple's [toggles](https://developer.apple.com/design/human-interface-guidelines/toggles)
and [sliders](https://developer.apple.com/design/human-interface-guidelines/sliders)
guidance for the interaction patterns behind the components.

````@example touch_controls
using Vellum
include(joinpath(pkgdir(Vellum),"tutorials","Workshop.jl"))
using .Workshop
````

## 1. Define three reusable controls

Each component owns a label and a logical rectangle measured in drawing
units. Its input region is at least 44 units high. The range also owns its
stop labels. A two-stop range can present itself as a segmented selector.
The application owns values, which keeps a component reusable across screens.

````@example touch_controls
"""A two-state switch with a labeled row-sized hit target."""
struct ToggleRow
    label::String
    rect::NTuple{4,Int}
end
"""A labeled slider with evenly spaced stops from left to right."""
struct SliderRow
    label::String
    rect::NTuple{4,Int}
    stops::Int
end
"""An exclusive selector that displays one segment per label."""
struct SegmentRow
    label::String
    rect::NTuple{4,Int}
    labels::Tuple{String,String}
end

"""Expose each component's input role, accessible name, extent and stop count."""
input(c::ToggleRow) = widget(c.label,:switch,c.rect)
input(c::SliderRow) = widget(c.label,:range,c.rect,c.stops)
input(c::SegmentRow) = (;widget(c.label,:segments,c.rect,length(c.labels))...,labels=c.labels)
````

## 2. Paint the controls from their values

All three components implement `paint!`. A switch moves its thumb as well
as changing color. A slider shows its current percentage and filled track.
A selected segment gets a raised white pill. The canvas receives pointer
events and tests these logical rectangles. Its fallback buttons and range
expose roles, values and keyboard input to assistive technology.

````@example touch_controls
"""Paint the switch's name, track and thumb. Value 2 means on."""
function paint!(e,font,c::ToggleRow,value)
    x,y,w,h = c.rect
    label!(e,font,c.label,x+12,y+30,17)
    right = x+w-62
    roundbox!(e,right,y+9,51,30,15,value == 2 ? 0x21875d : 0x869191)
    roundbox!(e,right+(value == 2 ? 24 : 3),y+12,24,24,12,0xffffff)
end

"""Paint a brightness slider and print the selected percentage."""
function paint!(e,font,c::SliderRow,value)
    x,y,w,h = c.rect
    level = (value-1)/(c.stops-1)
    label!(e,font,c.label,x,y-3,16)
    label!(e,font,string(round(Int,100level),"%"),x+w-42,y-3,15)
    roundbox!(e,x,y+20,w,6,3,0xd3dcd8)
    level > 0 && roundbox!(e,x,y+20,w*level,6,3,0x206bba)
    roundbox!(e,x+w*level-10,y+12,21,21,10,0x17578f)
end

"""Paint two exclusive segments, highlighting the current selection."""
function paint!(e,font,c::SegmentRow,value)
    x,y,w,h = c.rect
    roundbox!(e,x,y+2,w,h-4,15,0xe6ece9)
    roundbox!(e,x+(value-1)*w/2+3,y+5,w/2-6,h-10,12,0xffffff)
    for (i,text) in pairs(c.labels)
        label!(e,font,text,x+(i-1)*w/2+46,y+29,16)
    end
end
````

## 3. Compose a screen and connect its preview

The model is `(power, level, tone)`. Use five brightness stops and two color
temperatures. The preview keeps its amber or blue hue and varies brightness
with the selected level. The text reports the power state and selected tone
even when the light is off.

````@example touch_controls
components = (ToggleRow("Reading light",(28,168,304,48)),
              SliderRow("Brightness",(48,248,264,44),5),
              SegmentRow("Color temperature",(45,301,270,46),("Warm","Cool")))
"""Draw the reading-light preview and every component for one model value."""
function panel_view(model)
    power,level,tone = model
    drawing(size=(360,376)) do e
        font = resource!(e,:font,Workshop.face)
        rectangle!(e,0,0,360,376;fill=ink(0xf0f3f1))
        label!(e,font,"Reading light",22,41,28)
        roundbox!(e,18,58,324,90,24,0x23373c)
        palette = tone == 1 ? (0.98,0.73,0.35) : (0.50,0.80,1.0)
        strength = power == 2 ? (level-1)/4 : 0
        rgb = round.(Int,255 .* (0.18 .+ 0.80strength .* palette))
        color = (rgb[1]<<16) | (rgb[2]<<8) | rgb[3]
        roundbox!(e,36,77,52,52,26,color)
        label!(e,font,power == 2 ? "Light on" : "Light off",108,99,21,0xffffff)
        label!(e,font,tone == 1 ? "Warm white" : "Cool white",108,123,15,0xd4e0dc)
        roundbox!(e,18,158,324,200,24,0xffffff)
        for (component,value) in zip(components,model)
            paint!(e,font,component,value)
        end
    end
end
````

## 4. Dispatch an action and inspect the result

Each event changes one field. Toggling power preserves the brightness and
temperature, so turning the light back on restores the preview. Try the
assertion first, then turn the light on, drag brightness and tap Cool.
Use Tab to focus a control, Space to toggle and arrow keys to change a range.

````@example touch_controls
"""Reduce one control event to a new immutable model."""
function panel_update((power,level,tone),control,stop)
    control == 1 && return (3-power,level,tone)
    control == 2 && return (power,stop,tone)
    return (power,level,stop)
end
@assert panel_update((1,4,2),1,1) == (2,4,2)
models = [(power,level,tone) for power in 1:2 for level in (3,1,2,4,5) for tone in 1:2]
panel = application("Reading light",models,collect(input.(components)),panel_view,panel_update,
                    (model,component)->model[component])
explore(panel,"touch-controls")
````

```@raw html
<p><a href="apps/touch-controls.html">Open the interactive reading light</a></p>
```

## 5. Reuse the module

`touch-controls.wasm` holds the transition table and drawing commands.
A Wasm host imports `vellum.draw(offset, length)`, calls `dispatch(0)` for the
switch, then calls the scene export for the new state. The HTML host does
this on each interaction. To add a sixth brightness stop, change both the
slider's stop count and the model's level range and use the new maximum
when normalizing brightness in the preview.
