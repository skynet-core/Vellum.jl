"""Small component vocabulary shared by the signal desk and glass market tutorials."""
module Studio
using Vellum
include("Workshop.jl")
using .Workshop
export ink,label!,roundbox!,widget,application,explore,gradient,card!,trace!,retained_view,open_studio

"""Build a two-stop sRGB gradient between two points in the panel."""
gradient(a,b,c,d) = LinearGradient(a,b,(GradientStop(0,ink(c).color),GradientStop(1,ink(d).color)))

"""Draw a framed card with an inset fill. Both paints can be solid or gradients."""
function card!(e,x,y,w,h,r,border,body)
    roundbox!(e,x,y,w,h,r,border)
    roundbox!(e,x+1,y+1,w-2,h-2,r-1,body)
end

"""Stroke an open polyline with round joints in logical drawing coordinates."""
function trace!(e,points,color,width=2)
    commands = Tuple((i==1 ? :move : :line,p...) for (i,p) in enumerate(points))
    configure!(e;stroke=ink(color),stroke_style=StrokeStyle(;width,cap=:round,join=:round))
    draw(e,PathData(commands);mode=:stroke)
end

"""Record the fixed component tree once. Each call replaces its foreground group and returns an immutable revision."""
function retained_view(size,background,foreground;after_background=nothing)
    canvas = Canvas(;size)
    font = transaction!(canvas) do e
        face = resource!(e,:font,Workshop.face)
        background(e,face)
        face
    end
    if !isnothing(after_background)
        fixed = snapshot(canvas)
        transaction!(e->after_background(e,fixed),canvas)
    end
    layer = nothing
    return function(model)
        layer = transaction!(canvas) do e
            isnothing(layer) || Vellum.remove_node!(e,layer)
            with_group(child -> foreground(child,font,model),e)
        end
        return snapshot(canvas)
    end
end

"""Open the same application in WebGL2, or in a Wayland/X11 window using the requested native renderer."""
function open_studio(app,name)
    host = Symbol(get(ENV,"VELLUM_TUTORIAL_HOST","browser"))
    renderer = Symbol(get(ENV,"VELLUM_TUTORIAL_RENDERER",host===:browser ? "webgl2" : host===:desktop ? "cpu" : "vulkan"))
    return explore(app,name;host,renderer)
end
end
