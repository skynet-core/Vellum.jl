"""Shared drawing, input and presentation helpers for the interactive Julia lessons."""
module Workshop

using Vellum, Base64
export ink, label!, roundbox!, widget, application, explore

"""The bundled, redistributable font used to keep Julia and browser labels identical."""
const face = FontData("Liberation Sans",read(joinpath(pkgdir(Vellum),"test","fixtures","LiberationSans-Regular.ttf")))

"""Convert a hexadecimal sRGB color to an opaque drawing paint."""
ink(n) = Solid(((n >> 16) & 255)/255,((n >> 8) & 255)/255,(n & 255)/255)

"""Capture a label as positioned font glyphs at a logical baseline."""
function label!(edit,font,text,x,y,size=15,color=0x193234)
    configure!(edit;font,font_size=size,fill=ink(color))
    Vellum.capture_text!(edit,string(text),(x,y))
end

"""Draw a rounded rectangle using lines and quadratic corners."""
function roundbox!(edit,x,y,w,h,r,color)
    r = min(r,w/2,h/2)
    path = PathData(((:move,x+r,y),(:line,x+w-r,y),(:quad,x+w,y,x+w,y+r),
        (:line,x+w,y+h-r),(:quad,x+w,y+h,x+w-r,y+h),(:line,x+r,y+h),
        (:quad,x,y+h,x,y+h-r),(:line,x,y+r),(:quad,x,y,x+r,y),(:close,)))
    configure!(edit;fill=color isa Integer ? ink(color) : color)
    draw(edit,path)
end

"""Describe one labeled input region in the same logical coordinates as the drawing."""
widget(label,kind,rect,steps=1) = (;label,kind,rect,steps)

"""Compile a finite Julia update function and its frames into a shared interactive drawing."""
function application(title,states,controls,view,update,values;timer=state->(0,0))
    indices = Dict(state=>i for (i,state) in pairs(states))
    length(indices) == length(states) || error("duplicate application state")
    actions = [(i,stop) for (i,c) in pairs(controls) for stop in 1:c.steps]
    transitions = [indices[update(s,control,stop)] for s in states, (control,stop) in actions]
    readings = [values(s,i) for s in states, i in eachindex(controls)]
    InteractiveDrawing(title,map(view,states),controls,transitions,readings;timers=map(timer,states))
end

include("workshop_window.jl")

"""
    explore(app, name; host=:browser, renderer=:webgl2, directory=pwd())

Write a self-contained HTML lesson and its standalone Wasm module or open the
same drawing in a native window. In IJulia the browser drawing is interactive inline.
"""
function explore(app,name;host=Symbol(get(ENV,"VELLUM_TUTORIAL_HOST","browser")),
renderer=Symbol(get(ENV,"VELLUM_TUTORIAL_RENDERER",host===:browser ? "webgl2" : "cpu")),directory=get(ENV,"VELLUM_TUTORIAL_OUTPUT",pwd()))
    host in (:desktop,:wayland,:x11) && return show_window(app,host;target=renderer)
    host === :browser || throw(ArgumentError("choose :browser, :desktop, :wayland or :x11"))
    mkpath(directory)
    html = savehtml(joinpath(directory,name*".html"),app;target=renderer,module_path=joinpath(directory,name*".wasm"))
    if isdefined(Main,:IJulia) && Main.IJulia.inited
        w,h = first(app.frames).size
        source = "data:text/html;base64," * base64encode(read(html))
        display(MIME"text/html"(),"""<iframe title="Interactive Vellum tutorial" width="$(Int(w)+40)" height="$(Int(h)+120)" style="border:0;max-width:100%" src="$source"></iframe>""")
    end
    return rasterize(first(app.frames))
end
end
