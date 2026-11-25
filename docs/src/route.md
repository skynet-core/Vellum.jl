```@meta
EditURL = "../../tutorials/route.jl"
```

# Draw a route with Vellum

Start in a Julia project containing Vellum, or activate a checkout with
`using Pkg; Pkg.activate("."); Pkg.instantiate()`. The lesson runs on a
headless CPU. In Jupyter, select a Julia kernel using that project.

````@example route
using Vellum
````

## Choose a route

The map measures 160 by 96 logical units. The origin is its top-left corner.
Change `route_y` from 32 to 64 and rerun the following cells. The green park
stays in place while the route and both stations move.

````@example route
route_y = 32
````

## Record the drawing

A frame captures operations in order. Clip the two roads and the stations
to the map inset. The control points specify a gently curving railway.

````@example route
frame = drawing(size=(160, 96)) do edit
    rectangle!(edit, 0, 0, 160, 96; fill=Solid(0.96, 0.94, 0.88))
    rectangle!(edit, 44, 16, 66, 62; fill=Solid(0.62, 0.78, 0.58))
    clip(edit, rectangle_path(8, 8, 144, 80))
    for x in (36, 116)
        rectangle!(edit, x, 0, 6, 96; fill=Solid(1, 1, 1))
    end
    track = PathData(((:move, 0, route_y), (:line, 42, route_y),
                      (:cubic, 72, route_y, 78, route_y+12, 106, route_y+12),
                      (:line, 160, route_y+12)))
    configure!(edit; stroke=Solid(0.12, 0.25, 0.55), stroke_style=StrokeStyle(width=4))
    draw(edit, track; mode=:stroke)
    for (x, y) in ((36, route_y), (116, route_y+12))
        rectangle!(edit, x-4, y-4, 8, 8; fill=Solid(0.12, 0.25, 0.55))
        rectangle!(edit, x-2, y-2, 4, 4; fill=Solid(1, 1, 1))
    end
end
````

## Inspect the result

Render at double resolution. Julia indexes images by row then column.
The white center of the first station provides a check at either route height.
Jupyter displays the returned image inline.

````@example route
route_image = rasterize(frame; size=(320, 192))
@assert size(route_image) == (192, 320)
@assert route_image[2route_y+1, 73] == rgbx(255, 255, 255, 255)
route_image
````

## Save and explore

The script and notebook write the same PNG in the current working directory.
To try the interactive browser renderers, also evaluate
`savehtml("route.html", frame; target=:compare)` and open the file.
The browser needs graphics support for the WebGL2 and WebGPU panels.

````@example route
savepng("route.png", route_image)
````

Return the drawing so an interactive host can present it on its selected backend.

````@example route
frame
````
