using Vellum

# A family of ribbons, sampled from the same curve.
# Change the frequency or spacing, then run again.
frequency = 1.4
spacing = 5.0

drawing(size=(480, 320)) do pen
    rectangle!(pen, 0, 0, 480, 320; fill=Solid(0.055, 0.12, 0.17))
    for band in 0:24
        t = band / 24
        ink = Solid(0.34 + 0.55t, 0.90 - 0.33t, 0.78 - 0.53t)
        points = map(0:80) do i
            u = i / 80
            x = 32 + 416u
            y = 104 + spacing * band +
                42sinpi(2frequency*u + 0.72t) * sinpi(u)
            (i == 0 ? :move : :line, x, y)
        end
        configure!(pen; stroke=ink, stroke_style=StrokeStyle(width=2.5))
        draw(pen, PathData(Tuple(points)); mode=:stroke)
    end
end
