# # Orbit a shaded 3D surface
#
# Sample a wave on a regular grid, light its triangles and project axis labels
# with the same camera as the mesh. Move the orbit slider to see which parts
# of the surface come forward.
using Vellum
include(joinpath(pkgdir(Vellum),"tutorials","Workshop.jl"))
using .Workshop
import Vellum.Scene3D as S

# ## 1. Triangulate and light the height field
#
# The horizontal plane is x–z and y is height. Two triangles cover each grid
# cell. Split the mesh into small patches that fit the renderer's per-mesh
# limits. A shared material identifies all covered pixels after the depth pass.
grid = range(-1.6,1.6;length=16)
height_at(x,z) = 0.65cos(2x)*sin(1.7z)
vertices = [(x,height_at(x,z),z) for z in grid for x in grid]
faces = NTuple{3,Int}[]
for j in 0:14, i in 0:14
    a = 1+i+16j
    push!(faces,(a,a+16,a+1),(a+1,a+16,a+17))
end

"""Create a mesh for each group of two grid rows with compact local vertex indices."""
function wave_meshes(vertices,faces)
    map(collect(Iterators.partition(faces,60))) do chunk
        indices = unique(collect(Iterators.flatten(chunk)))
        local_faces = [map(n -> findfirst(==(n),indices),f) for f in chunk]
        S.Mesh(vertices[indices],local_faces)
    end
end
mesh_parts = wave_meshes(vertices,faces)

# ## 2. Use a depth buffer
#
# Register the mesh pieces, choose a perspective camera and wait for the scene
# submission. Each sample keeps the nearest triangle. Make the empty background
# transparent so a separately drawn coordinate grid can appear behind the mesh.
# At each visible pixel use its depth to recover its world coordinates. The
# slope of the height function gives a smooth normal. A diffuse light and a
# fine mesh grid reveal curvature between the sample points.
"""Render the surface from one camera, returning detached premultiplied RGBA pixels."""
function wave_image(camera)
    assets = Canvas(size=(384,232))
    cam,objects = transaction!(assets) do e
        reference = resource!(e,:camera,camera)
        material = resource!(e,:material,S.Material(31,102,102))
        items = [S.Instance(i,resource!(e,:mesh,m),material) for (i,m) in pairs(mesh_parts)]
        reference,items
    end
    scene = S.Scene(snapshot(assets),cam,objects;background=S.Material(255,255,255))
    renderer = S.SceneCPU(faces=512)
    target = make_surface(renderer,(384,232))
    try
        ticket = submit!(renderer,target,scene)
        wait(ticket)
        S.shade_image(ticket) do world,object_id
            wx,_,wz = world
            normal = (1.3sin(2wx)*sin(1.7wz),1.0,-1.105cos(2wx)*cos(1.7wz))
            diffuse = max(0,sum(normal .* (-0.48,0.80,0.36))/sqrt(sum(abs2,normal)))
            t = clamp(0.75diffuse+0.25*(height_at(wx,wz)+0.65)/1.3,0,1)
            distance = min(abs(wx-0.4round(wx/0.4)),abs(wz-0.4round(wz/0.4)))
            shadow = 1-0.2clamp(1-distance/0.015,0,1)
            rgb = shadow .* ((18,67,84) .* (1-t) .+ (161,215,181) .* t)
            return rgbx(round.(UInt8,rgb)...,255)
        end
    finally
        close(target)
    end
end

# ## 3. Project a grid and anchor the labels
#
# Subtract the camera eye and resolve the displacement along the camera's
# right, up and forward axes. Divide by depth to obtain a screen position.
# The axis labels stay upright while their anchors move with the orbit.
angles = [20,35,50,65,80,95,110,125,140]
"""Project a world-space point into the plot viewport, centered at (290,205)."""
function plot_point(camera,point)
    delta = point .- camera.eye
    depth = sum(delta .* camera.forward)
    scale = 140/(depth*camera.half_height)
    (290+scale*sum(delta .* camera.right),205-scale*sum(delta .* camera.up))
end
"""Project and stroke one grid line on the floor below the surface."""
function gridline!(e,camera,a,b)
    p,q = plot_point(camera,a),plot_point(camera,b)
    configure!(e;stroke=ink(0xd2dcd6),stroke_style=StrokeStyle(width=0.9))
    draw(e,PathData(((:move,p...),(:line,q...)));mode=:stroke)
end

"""Compose the lit mesh, projected axes, captured font labels and an orbit control."""
function plot_view(i)
    camera = S.Camera((5cosd(angles[i]),3.4,5sind(angles[i])),(0,-0.05,0),(0,1,0);fovy=0.71)
    image = wave_image(camera)
    drawing(size=(580,418)) do e
        font = resource!(e,:font,Workshop.face)
        rectangle!(e,0,0,580,418;fill=ink(0xfafbf7))
        label!(e,font,"Wave surface",26,40,29,0x152e32)
        label!(e,font,"y = 0.65 cos(2x) sin(1.7z)",27,65,16,0x485d5d)
        label!(e,font,"x, z: -1.6 to 1.6",442,64,14,0x485d5d)
        for t in -1.6:0.4:1.61
            gridline!(e,camera,(t,-0.73,-1.6),(t,-0.73,1.6))
            gridline!(e,camera,(-1.6,-0.73,t),(1.6,-0.73,t))
        end
        configure!(e;sampling=:linear)
        w = 280*384/232
        draw_image!(e,resource!(e,image),(290-w/2,65,w,280))
        ## Anchor the height axis at the leftmost floor corner in this view.
        corners = [(x,-0.73,z) for x in (-1.6,1.6) for z in (-1.6,1.6)]
        ax,_,az = argmin(p -> first(plot_point(camera,p)),corners)
        gridline!(e,camera,(ax,-0.73,az),(ax,0.78,az))
        for h in (-0.6,0.0,0.6)
            x,y = plot_point(camera,(ax,h,az))
            rectangle!(e,x-4,y,5,1;fill=ink(0x92a6a0))
            label!(e,font,string(h),x-31,y+4,11,0x485d5d)
        end
        hx,hy = plot_point(camera,(ax,0.78,az))
        label!(e,font,"y",hx-4,hy-6,15,0x415959)
        for (text,point) in (("x",(1.96,-0.73,0.0)),("z",(0.0,-0.73,1.96)))
            x,y = plot_point(camera,point)
            label!(e,font,text,x-3,y+5,16,0x415959)
        end
        rectangle!(e,26,347,528,1;fill=ink(0xd5dfd9))
        label!(e,font,"Orbit",26,384,16)
        label!(e,font,string(angles[i],"°"),505,384,16)
        roundbox!(e,97,379,382,4,2,0xcdd9d2)
        x = 97+382*(i-1)/(length(angles)-1)
        i>1 && roundbox!(e,97,379,x-97,4,2,0x417b72)
        roundbox!(e,x-8,373,16,16,8,0x245f59)
    end
end

# ## 4. Orbit the plot
#
# Drag the thumb or press an arrow key while the slider is focused. Each stop
# selects a different depth-tested camera view. Change the height function to
# explore another surface, then rerun the mesh and view cells.
plot_controls = [widget("Camera azimuth",:range,(97,358,382,44),length(angles))]
plot_app = application("Wave surface",collect(eachindex(angles)),plot_controls,plot_view,
                       (_,_,stop)->stop,(state,_)->state)
explore(plot_app,"surface-plot")

#md # ```@raw html
#md # <p><a href="apps/surface-plot.html">Open the interactive 3D plot</a></p>
#md # ```
