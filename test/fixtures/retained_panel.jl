"""Return three immutable revisions of one panel, with two static nodes and one edited fill."""
function retained_panel()
    canvas = Canvas(size=(180,100))
    id = transaction!(canvas) do e
        face = FontData("Liberation Sans",read(joinpath(@__DIR__,"LiberationSans-Regular.ttf")))
        font = resource!(e,:font,face)
        rectangle!(e,0,0,180,100;fill=Solid(30/255,36/255,56/255))
        configure!(e;font,font_size=32,fill=Solid(1,1,1))
        Vellum.capture_text!(e,"Quote 08",(15,75))
        colors = (GradientStop(0,Color(1,0,0)),GradientStop(1,Color(0,1,0)))
        rectangle!(e,5,5,135,26;fill=LinearGradient((0,0),(130,0),colors))
    end
    first = snapshot(canvas)
    transaction!(e -> Vellum.update_node!(e,id;fill=Solid(0,0,1)),canvas)
    second = snapshot(canvas)
    transaction!(e -> Vellum.remove_node!(e,id),canvas)
    return (first,second,snapshot(canvas))
end
