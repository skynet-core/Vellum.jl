"""Render portable vector frames through the desktop's Vulkan-enabled GTK 4.14+ scene renderer."""
struct DesktopBackend <: Vellum.Backend
    function DesktopBackend(;device=:auto)
        device === :auto || throw(ArgumentError("the GSK Vulkan provider uses the display device and requires device=:auto"))
        new()
    end
end

"""System GTK runtime supplying the display's Vulkan integration. Loaded on the first native call."""
const GTK = "libgtk-4.so.1"

"""A desktop Vulkan renderer, its latest texture and retained top-level GSK drawing nodes."""
mutable struct DesktopSurface <: Vellum.Surface
    size::Tuple{Int,Int}
    renderer::Ptr{Cvoid}
    texture::Ptr{Cvoid}
    nodes::Dict{UInt64,Tuple{Vellum.SemanticNode,Ptr{Cvoid}}}
    frame::Union{Nothing,Vellum.Frame}
    draws::Int
    reused::Int
end

"""Require the GTK main thread before creating or accessing desktop Vulkan objects."""
function main_thread()
    Threads.threadid() == 1 || throw(ArgumentError("desktop Vulkan surfaces belong to the GTK main thread"))
end

"""Check the lifetime and thread of a desktop Vulkan target."""
function check_open(s::DesktopSurface)
    main_thread()
    s.renderer != C_NULL || throw(ArgumentError("Vulkan surface is closed"))
end

"""Operations admitted by the Vulkan scene renderer, including captured font outlines."""
Vellum.capabilities(::DesktopBackend) = Vellum.capabilities(OpenGLBackend.DesktopBackend())

"""Realize an explicit Vulkan renderer on the default desktop display, failing if the driver is unavailable."""
function Vellum.make_surface(::DesktopBackend,size)
    return with_gdk_context(() -> open_desktop_surface(size))
end

"""Restore GDK's graphics binding after probing the display, drawing or downloading a texture."""
function with_gdk_context(f)
    main_thread()
    # A GDK display probe may bind a temporary GL context even for a Vulkan renderer.
    # Release that binding through GDK, which also tracks the current context in TLS.
    prior = ccall((:gdk_gl_context_get_current,GTK),Ptr{Cvoid},())
    try
        return f()
    finally
        current = ccall((:gdk_gl_context_get_current,GTK),Ptr{Cvoid},())
        if current != prior
            if prior == C_NULL
                ccall((:gdk_gl_context_clear_current,GTK),Cvoid,())
            else
                ccall((:gdk_gl_context_make_current,GTK),Cvoid,(Ptr{Cvoid},),prior)
            end
        end
    end
end

"""Open the Vulkan texture renderer inside the caller's graphics-context guard."""
function open_desktop_surface(size)
    dims = Vellum.checked_dimensions(size...)
    ccall((:gtk_init_check,GTK),Cint,()) != 0 || throw(ArgumentError("Vulkan requires an accessible desktop display"))
    ccall((:gtk_check_version,GTK),Cstring,(Cuint,Cuint,Cuint),4,14,0) == C_NULL ||
        throw(ArgumentError("Vulkan requires GTK 4.14 or newer"))
    display = ccall((:gdk_display_get_default,GTK),Ptr{Cvoid},())
    renderer = ccall((:gsk_vulkan_renderer_new,GTK),Ptr{Cvoid},())
    renderer != C_NULL || error("GTK could not create its Vulkan renderer")
    if ccall((:gsk_renderer_realize_for_display,GTK),Cint,(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}),renderer,display,C_NULL) == 0
        ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),renderer)
        error("GTK could not realize its Vulkan renderer on this display")
    end
    return DesktopSurface(dims,renderer,C_NULL,Dict(),nothing,0,0)
end

"""Append a winding-aware vector mask and leave its content open until the matching snapshot pop."""
function push_path(snapshot,geom)
    contours = OpenGLBackend.device_contours(geom)
    builder = ccall((:gsk_path_builder_new,GTK),Ptr{Cvoid},())
    try
        for points in contours
            isempty(points) && continue
            ccall((:gsk_path_builder_move_to,GTK),Cvoid,(Ptr{Cvoid},Cfloat,Cfloat),builder,points[1][1],points[1][2])
            for i in 2:length(points)
                x,y = points[i]
                ccall((:gsk_path_builder_line_to,GTK),Cvoid,(Ptr{Cvoid},Cfloat,Cfloat),builder,x,y)
            end
            ccall((:gsk_path_builder_close,GTK),Cvoid,(Ptr{Cvoid},),builder)
        end
        path = ccall((:gsk_path_builder_free_to_path,GTK),Ptr{Cvoid},(Ptr{Cvoid},),builder)
        builder = C_NULL
        try
            ccall((:gtk_snapshot_push_fill,GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid},Cint),snapshot,path,geom.winding===:evenodd)
        finally
            ccall((:gsk_path_unref,GTK),Cvoid,(Ptr{Cvoid},),path)
        end
    finally
        builder != C_NULL && ccall((:gsk_path_builder_unref,GTK),Cvoid,(Ptr{Cvoid},),builder)
    end
end

"""Append the painted area of a solid or linear-gradient drawing operation."""
function append_brush(snap,brush,state,viewport,bounds)
    if brush isa Vellum.Solid
        r,g,b,a = brush.color.channels
        rgba = Float32.((r,g,b,a*state.opacity))
        ccall((:gtk_snapshot_append_color,GTK),Cvoid,
              (Ptr{Cvoid},Ref{NTuple{4,Cfloat}},Ref{NTuple{4,Cfloat}}),snap,rgba,bounds)
    else
        firstpoint,lastpoint = OpenGLBackend.gradient_axis(brush,state,viewport)
        stops = [(Float32(s.position),Float32.(s.color.channels)) for s in brush.stops]
        ccall((:gtk_snapshot_push_opacity,GTK),Cvoid,(Ptr{Cvoid},Cdouble),snap,state.opacity)
        ccall((:gtk_snapshot_append_linear_gradient,GTK),Cvoid,(Ptr{Cvoid},Ref{NTuple{4,Cfloat}},
              Ref{NTuple{2,Cfloat}},Ref{NTuple{2,Cfloat}},Ptr{Tuple{Float32,NTuple{4,Float32}}},Csize_t),
              snap,bounds,Float32.(firstpoint),Float32.(lastpoint),stops,length(stops))
        ccall((:gtk_snapshot_pop,GTK),Cvoid,(Ptr{Cvoid},),snap)
    end
end

"""Upload a dense image and append a sampled texture with its clip, opacity and affine transform."""
function append_image(snap,node,frame,viewport)
    p = OpenGLBackend.image_placement(node,frame,viewport)
    isnothing(p) && return
    image = p.image
    bytes = ccall((:g_bytes_new,GTK),Ptr{Cvoid},(Ptr{UInt8},Csize_t),image.data,length(image.data))
    texture = try
        ccall((:gdk_memory_texture_new,GTK),Ptr{Cvoid},(Cint,Cint,Cint,Ptr{Cvoid},Csize_t),
              image.width,image.height,2,bytes,4image.width)
    finally
        ccall((:g_bytes_unref,GTK),Cvoid,(Ptr{Cvoid},),bytes)
    end
    try
        isnothing(p.mask) || push_path(snap,p.mask)
        ccall((:gtk_snapshot_push_opacity,GTK),Cvoid,(Ptr{Cvoid},Cdouble),snap,node.operation.state.opacity)
        matrix = ccall((:graphene_matrix_alloc,GTK),Ptr{Cvoid},())
        try
            a,b,c,d,x,y = p.transform.coefficients
            ccall((:graphene_matrix_init_from_2d,GTK),Ptr{Cvoid},(Ptr{Cvoid},Cdouble,Cdouble,Cdouble,Cdouble,Cdouble,Cdouble),matrix,a,b,c,d,x,y)
            ccall((:gtk_snapshot_transform_matrix,GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),snap,matrix)
            rect = (0f0,0f0,Float32(image.width),Float32(image.height))
            ccall((:gtk_snapshot_append_scaled_texture,GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid},Cint,Ref{NTuple{4,Cfloat}}),
                  snap,texture,node.operation.state.sampling===:nearest ? 1 : 0,rect)
        finally
            ccall((:graphene_matrix_free,GTK),Cvoid,(Ptr{Cvoid},),matrix)
            ccall((:gtk_snapshot_pop,GTK),Cvoid,(Ptr{Cvoid},),snap)
            isnothing(p.mask) || ccall((:gtk_snapshot_pop,GTK),Cvoid,(Ptr{Cvoid},),snap)
        end
    finally
        ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),texture)
    end
end

"""Record a prepared node and its clips into a GTK snapshot in physical pixel coordinates."""
function append_node(snap,node,frame,viewport,bounds)
    op = node.operation
    layers = 0
    try
        if op isa Vellum.CompositeGroup
            ccall((:gtk_snapshot_push_opacity,GTK),Cvoid,(Ptr{Cvoid},Cdouble),snap,op.opacity)
            layers += 1
            foreach(child -> append_node(snap,child,frame,viewport,bounds),op.nodes)
        else
            for clip in op.state.clips
                push_path(snap,OpenGLBackend.device_geometry(clip.path,viewport*clip.transform,clip.winding))
                layers += 1
            end
            op isa Vellum.ImageRegion && return append_image(snap,node,frame,viewport)
            push_path(snap,OpenGLBackend.node_geometry(node,frame,viewport))
            layers += 1
            append_brush(snap,op isa Vellum.StrokePath ? op.state.stroke : op.state.fill,op.state,viewport,bounds)
        end
    finally
        for _ in 1:layers
            ccall((:gtk_snapshot_pop,GTK),Cvoid,(Ptr{Cvoid},),snap)
        end
    end
end

"""Record a GSK snapshot as an owned render node. Empty recordings return a null pointer."""
function recorded_node(record)
    snap = ccall((:gtk_snapshot_new,GTK),Ptr{Cvoid},())
    try
        record(snap)
        return ccall((:gtk_snapshot_to_node,GTK),Ptr{Cvoid},(Ptr{Cvoid},),snap)
    finally
        ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),snap)
    end
end

"""Drop the owned reference to a possibly empty GSK drawing."""
drop_node(p) = p == C_NULL || (ccall((:gsk_render_node_unref,GTK),Cvoid,(Ptr{Cvoid},),p); true)

"""Submit the retained frame and atomically replace the completed texture and node cache."""
function Vellum.execute!(backend::DesktopBackend,s::DesktopSurface,plan::Vellum.PreparedFrame)
    check_open(s)
    plan.backend === backend || throw(ArgumentError("foreign Vulkan plan"))
    return with_gdk_context(() -> draw_retained!(s,plan.frame))
end

"""Build or reuse immutable device nodes and publish the completed texture after successful rendering."""
function draw_retained!(s,frame)
    viewport = Vellum.Transform2D(s.size[1]/frame.size[1],0,0,s.size[2]/frame.size[2],0,0)
    bounds = (0f0,0f0,Float32(s.size[1]),Float32(s.size[2]))
    reuse = s.frame !== nothing && s.frame.canvas == frame.canvas && s.frame.size == frame.size && s.frame.resources === frame.resources
    candidate = empty(s.nodes)
    reused = 0
    try
        root = recorded_node() do snap
            for node in frame.nodes
                entry = reuse ? get(s.nodes,node.id,nothing) : nothing
                if entry !== nothing && first(entry) === node
                    ptr = last(entry)
                    ptr != C_NULL && ccall((:gsk_render_node_ref,GTK),Ptr{Cvoid},(Ptr{Cvoid},),ptr)
                    reused += 1
                else
                    ptr = recorded_node(child -> append_node(child,node,frame,viewport,bounds))
                end
                candidate[node.id] = (node,ptr)
                ptr != C_NULL && ccall((:gtk_snapshot_append_node,GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),snap,ptr)
            end
        end
        if root == C_NULL
            root = ccall((:gsk_color_node_new,GTK),Ptr{Cvoid},(Ref{NTuple{4,Cfloat}},Ref{NTuple{4,Cfloat}}),
                         (0f0,0f0,0f0,0f0),bounds)
        end
        texture = try
            ccall((:gsk_renderer_render_texture,GTK),Ptr{Cvoid},(Ptr{Cvoid},Ptr{Cvoid},Ref{NTuple{4,Cfloat}}),s.renderer,root,bounds)
        finally
            drop_node(root)
        end
        texture != C_NULL || error("Vulkan rendering failed")
        s.texture != C_NULL && ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),s.texture)
        s.texture,s.nodes,s.frame,candidate = texture,candidate,frame,s.nodes
        s.draws += 1
        s.reused = reused
        return s
    finally
        foreach(entry -> drop_node(last(entry)),values(candidate))
    end
end

"""Download the completed Vulkan texture in premultiplied, top-down RGBA byte order."""
function Vellum.readback(s::DesktopSurface)
    check_open(s)
    s.texture != C_NULL || throw(ArgumentError("Vulkan surface has no completed frame"))
    return with_gdk_context(() -> download_texture(s))
end

"""Download a realized renderer's current texture inside its graphics-context guard."""
function download_texture(s)
    image = Vellum.Image(s.size...)
    reader = ccall((:gdk_texture_downloader_new,GTK),Ptr{Cvoid},(Ptr{Cvoid},),s.texture)
    try
        ccall((:gdk_texture_downloader_set_format,GTK),Cvoid,(Ptr{Cvoid},Cint),reader,2)
        ccall((:gdk_texture_downloader_download_into,GTK),Cvoid,(Ptr{Cvoid},Ptr{UInt8},Csize_t),reader,image.data,4image.width)
    finally
        ccall((:gdk_texture_downloader_free,GTK),Cvoid,(Ptr{Cvoid},),reader)
    end
    return image
end

"""Report the realized native renderer type, completed draws and nodes reused in the last draw."""
function statistics(s::DesktopSurface)
    check_open(s)
    name = ccall((:g_type_name_from_instance,GTK),Cstring,(Ptr{Cvoid},),s.renderer)
    return (;renderer=unsafe_string(name),frames=s.draws,reused=s.reused)
end

"""Release all retained drawing nodes, the completed texture and the realized Vulkan renderer."""
function Base.close(s::DesktopSurface)
    main_thread()
    s.renderer == C_NULL && return
    foreach(entry -> drop_node(last(entry)),values(s.nodes))
    empty!(s.nodes)
    s.texture != C_NULL && ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),s.texture)
    ccall((:gsk_renderer_unrealize,GTK),Cvoid,(Ptr{Cvoid},),s.renderer)
    ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),s.renderer)
    s.renderer = s.texture = C_NULL
    s.frame = nothing
end
