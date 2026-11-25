"""Shared vector silhouettes and Gaussian shadow masks for the glass lessons."""
module GlassMaterial
using Vellum
export capsule, glass_outline, lens_shadow, prepare_glass!, paint_glass!

"""Capsule outline for the lens clip and rim."""
capsule(x,y,w,h) = glass_outline(x,y,w,h,h/2)

"""Closed rounded rectangle with cubic quarter-circle corners."""
function glass_outline(x,y,w,h,r)
    r = clamp(r,0,min(w,h)/2)
    k = 0.552285r
    PathData(((:move,x+r,y),(:line,x+w-r,y),(:cubic,x+w-r+k,y,x+w,y+r-k,x+w,y+r),
        (:line,x+w,y+h-r),(:cubic,x+w,y+h-r+k,x+w-r+k,y+h,x+w-r,y+h),(:line,x+r,y+h),
        (:cubic,x+r-k,y+h,x,y+h-r+k,x,y+h-r),(:line,x,y+r),(:cubic,x,y+r-k,x+r-k,y,x+r,y),(:close,)))
end

"""Build the contact and ambient shadow from a lens path in local coordinates."""
function lens_shadow(lens,x,y,w,h;ambient_radius=16,ambient_offset=6)
    pad = ambient_radius+ambient_offset+1
    area = (w+2pad,h+2pad)
    mask = rasterize(drawing(size=area) do pen
        transform!(pen,Transform2D(1,0,0,1,pad-x,pad-y))
        configure!(pen;fill=Solid(1,1,1))
        draw(pen,lens)
    end)
    ambient = shadow(mask,Vec2(0,ambient_offset),0,ambient_radius,rgba(18,30,34,78))
    contact = shadow(mask,Vec2(0,2),0,5,rgba(13,26,30,75))
    draw(ambient,contact)
    return ambient,(x-pad,y-pad,area...)
end

"""Allocate a padded Gaussian-filtered copy of the pixels behind a surface and its silhouette shadow once."""
function prepare_glass!(e,backdrop,rect,radius;blur_radius=10,shadow_radius=14,shadow_offset=5)
    x,y,w,h = rect
    outline = glass_outline(x,y,w,h,radius)
    # Include the filter support on each side before blurring, then clip when drawing.
    pad = blur_radius+2
    region = (x-pad,y-pad,w+2pad,h+2pad)
    frost = super_image(backdrop,region...)
    blur!(frost,blur_radius)
    shade,shade_rect = lens_shadow(outline,x,y,w,h;ambient_radius=shadow_radius,ambient_offset=shadow_offset)
    return (;rect,outline,frost=resource!(e,frost),region,
            shade=resource!(e,shade),shade_rect)
end

"""Composite a prepared glass surface. The shadow stays on the receiving surface as the glass lifts."""
function paint_glass!(e,glass;lift=0.0,zoom=1.09,light=0.22,dark=0.43)
    x,y,w,h = glass.rect
    draw_image!(e,glass.shade,glass.shade_rect)
    save(e)
    transform!(e,Transform2D(1,0,0,1,0,-lift))
    save(e)
    clip(e,glass.outline)
    rx,ry,rw,rh = glass.region
    cx,cy = x+w/2,y+h/2
    configure!(e;sampling=:linear)
    draw_image!(e,glass.frost,(cx+zoom*(rx-cx),cy+zoom*(ry-cy),zoom*rw,zoom*rh))
    restore(e)
    tint = LinearGradient((x,y),(x+w*0.25,y+h),(
        GradientStop(0,Solid(0.79,0.77,0.95,light).color),
        GradientStop(1,Solid(0.08,0.07,0.19,dark).color)))
    configure!(e;fill=tint)
    draw(e,glass.outline)
    configure!(e;stroke=Solid(1,0.98,1,0.57),stroke_style=StrokeStyle(width=1))
    draw(e,glass.outline;mode=:stroke)
    restore(e)
end
end
