"""
    DesktopBackend(; device=:auto, raster_registry=nothing)

Render through the desktop's Vulkan-enabled GTK 4.14+ scene renderer.
Supply a revision resolver to draw tiled images from immutable source pages.
"""
struct DesktopBackend <: Vellum.Backend
    raster_registry::Union{Nothing,Vellum.ImageTiles.AbstractRasterResolver}
    function DesktopBackend(;device=:auto,raster_registry=nothing)
        device === :auto || throw(ArgumentError("the GSK Vulkan provider uses the display device and requires device=:auto"))
        new(raster_registry)
    end
end

"""A retained GTK drawing node and the source textures needed to redraw or revise it."""
struct DeviceNode
    semantic::Vellum.SemanticNode
    pointer::Ptr{Cvoid}
    textures::Set{OpenGLBackend.DesktopTextureKey}
end

"""A transaction's native source textures and the number of bytes supplied by Julia."""
mutable struct SourceTextures
    images::Dict{OpenGLBackend.DesktopTextureKey,Ptr{Cvoid}}
    uploaded_bytes::Int
    pages::Int
end

"""System GTK runtime supplying the display's Vulkan integration. Loaded on the first native call."""
const GTK = "libgtk-4.so.1"

"""GLib error record. The owner releases the message and record together with `g_error_free`."""
struct GError
    domain::UInt32
    code::Cint
    message::Cstring
end

"""A desktop Vulkan renderer, its latest texture and retained top-level GSK drawing nodes."""
mutable struct DesktopSurface <: Vellum.Surface
    backend::Vellum.Backend
    size::Tuple{Int,Int}
    renderer::Ptr{Cvoid}
    texture::Ptr{Cvoid}
    nodes::Dict{UInt64,DeviceNode}
    frame::Union{Nothing,Vellum.Frame}
    draws::Int
    reused::Int
    sources::SourceTextures
    drawing::Bool
    uploaded_bytes::Int
end

"""Require the GTK main thread before creating or accessing desktop Vulkan objects."""
function main_thread()
    Threads.threadid() == 1 || throw(ArgumentError("GSK surfaces belong to the GTK main thread"))
end

"""Check the lifetime and thread of a desktop Vulkan target."""
function check_open(s::DesktopSurface)
    main_thread()
    s.renderer != C_NULL || throw(ArgumentError("GSK surface is closed"))
end

"""Operations admitted by the Vulkan scene renderer, including captured font outlines."""
Vellum.capabilities(b::DesktopBackend) = Vellum.capabilities(OpenGLBackend.DesktopBackend(raster_registry=b.raster_registry))

"""Pin the exact source revisions of a Vulkan plan until its owner closes the plan."""
Vellum.prepare_retention(b::DesktopBackend,frame::Vellum.Frame) =
    Vellum.prepare_retention(OpenGLBackend.DesktopBackend(raster_registry=b.raster_registry),frame)

"""Realize an explicit Vulkan renderer on the default desktop display, failing if the driver is unavailable."""
function Vellum.make_surface(backend::DesktopBackend,size)
    return with_gdk_context(() -> open_desktop_surface(size;backend))
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

"""Realize the requested GSK renderer for a borrowed GDK window or offscreen textures."""
function open_desktop_surface(size,window=C_NULL,target=:vulkan;backend=DesktopBackend())
    dims = Vellum.checked_dimensions(size...)
    ccall((:gtk_init_check,GTK),Cint,()) != 0 || throw(ArgumentError("GSK requires an accessible desktop display"))
    ccall((:gtk_check_version,GTK),Cstring,(Cuint,Cuint,Cuint),4,14,0) == C_NULL ||
        throw(ArgumentError("GSK requires GTK 4.14 or newer"))
    renderer = if target === :vulkan
        ccall((:gsk_vulkan_renderer_new,GTK),Ptr{Cvoid},())
    elseif target === :opengl
        ccall((:gsk_gl_renderer_new,GTK),Ptr{Cvoid},())
    else
        throw(ArgumentError("unsupported GSK renderer $target"))
    end
    renderer != C_NULL || error("GTK could not create its $target renderer")
    failure = Ref{Ptr{Cvoid}}(C_NULL)
    realized = if window == C_NULL
        display = ccall((:gdk_display_get_default,GTK),Ptr{Cvoid},())
        ccall((:gsk_renderer_realize_for_display,GTK),Cint,(Ptr{Cvoid},Ptr{Cvoid},Ref{Ptr{Cvoid}}),renderer,display,failure)
    else
        ccall((:gsk_renderer_realize,GTK),Cint,(Ptr{Cvoid},Ptr{Cvoid},Ref{Ptr{Cvoid}}),renderer,window,failure)
    end
    if iszero(realized)
        ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),renderer)
        # GLib owns the diagnostic until g_error_free.
        detail = if failure[] != C_NULL
            try
                unsafe_string(unsafe_load(Ptr{GError}(failure[])).message)
            finally
                ccall((:g_error_free,GTK),Cvoid,(Ptr{Cvoid},),failure[])
            end
        else
            "driver unavailable"
        end
        error("GTK could not realize its $target renderer: $detail")
    end
    return DesktopSurface(backend,dims,renderer,C_NULL,Dict(),nothing,0,0,SourceTextures(Dict(),0,0),false,0)
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

"""Return an owned node covering an empty frame or source crop with transparent pixels."""
transparent_node(bounds) = ccall((:gsk_color_node_new,GTK),Ptr{Cvoid},
    (Ref{NTuple{4,Cfloat}},Ref{NTuple{4,Cfloat}}),(0f0,0f0,0f0,0f0),bounds)

"""Render a node into an owned renderer texture and release the supplied node reference."""
function render_texture(renderer,root,bounds)
    root == C_NULL && (root = transparent_node(bounds))
    try
        texture = ccall((:gsk_renderer_render_texture,GTK),Ptr{Cvoid},
                        (Ptr{Cvoid},Ptr{Cvoid},Ref{NTuple{4,Cfloat}}),renderer,root,bounds)
        texture != C_NULL || error("GSK texture rendering failed")
        return texture
    finally
        drop_node(root)
    end
end

"""Release one owned GDK texture or GLib object."""
unref_object(object) = ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),object)

"""Retain a native source texture for a subsequent draw transaction."""
ref_object(object) = ccall((:g_object_ref,GTK),Ptr{Cvoid},(Ptr{Cvoid},),object)

"""Upload packed RGBA8 bytes and return the owned renderer texture used by subsequent draws."""
function upload_texture(renderer,pixels,size)
    w,h = size
    bytes = GC.@preserve pixels ccall((:g_bytes_new,GTK),Ptr{Cvoid},(Ptr{UInt8},Csize_t),pointer(pixels),sizeof(pixels))
    memory = try
        ccall((:gdk_memory_texture_new,GTK),Ptr{Cvoid},(Cint,Cint,Cint,Ptr{Cvoid},Csize_t),w,h,2,bytes,4w)
    finally
        ccall((:g_bytes_unref,GTK),Cvoid,(Ptr{Cvoid},),bytes)
    end
    try
        bounds = (0f0,0f0,Float32(w),Float32(h))
        node = ccall((:gsk_texture_node_new,GTK),Ptr{Cvoid},(Ptr{Cvoid},Ref{NTuple{4,Cfloat}}),memory,bounds)
        return render_texture(renderer,node,bounds)
    finally
        unref_object(memory)
    end
end

"""Track a node's source dependency and acquire its input texture exactly once per frame."""
function resident_texture!(load,s,candidate,used,key,size)
    push!(used,key)
    return get!(candidate.images,key) do
        OpenGLBackend.reserve_desktop_page!(candidate,key)
        haskey(s.sources.images,key) && return ref_object(s.sources.images[key])
        pixels = load()
        texture = upload_texture(s.renderer,pixels,size)
        s.uploaded_bytes += sizeof(pixels)
        candidate.uploaded_bytes += sizeof(pixels)
        return texture
    end
end

"""Assemble a sampled crop from resident GPU page textures before interpolating across their joins."""
function tiled_texture(s,candidate,used,p,retention)
    root = recorded_node() do snap
        OpenGLBackend.visit_desktop_pages(retention,p) do key,(x,y),load
            w,h = OpenGLBackend.RasterPages.dimensions(key)
            texture = resident_texture!(load,s,candidate,used,key,(w,h))
            rect = Float32.((x,y,w,h))
            ccall((:gtk_snapshot_append_scaled_texture,GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid},Cint,Ref{NTuple{4,Cfloat}}),
                  snap,texture,1,rect)
        end
    end
    return render_texture(s.renderer,root,(0f0,0f0,Float32.(p.size)...))
end

"""Append a resident source with its clip, opacity, sampling mode and physical transform."""
function append_image(snap,node,frame,viewport,s,candidate,used,retention)
    p = OpenGLBackend.image_placement(node,frame,viewport)
    isnothing(p) && return
    tiled = p.source isa Vellum.RasterReference
    texture = if tiled
        tiled_texture(s,candidate,used,p,retention)
    else
        resident_texture!(() -> Vellum._dense_crop(p.source,p.crop).data,s,candidate,used,(p.source,p.crop),p.size)
    end
    try
        isnothing(p.mask) || push_path(snap,p.mask)
        ccall((:gtk_snapshot_push_opacity,GTK),Cvoid,(Ptr{Cvoid},Cdouble),snap,node.operation.state.opacity)
        matrix = ccall((:graphene_matrix_alloc,GTK),Ptr{Cvoid},())
        try
            a,b,c,d,x,y = p.transform.coefficients
            ccall((:graphene_matrix_init_from_2d,GTK),Ptr{Cvoid},(Ptr{Cvoid},Cdouble,Cdouble,Cdouble,Cdouble,Cdouble,Cdouble),matrix,a,b,c,d,x,y)
            ccall((:gtk_snapshot_transform_matrix,GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),snap,matrix)
            rect = (0f0,0f0,Float32.(p.size)...)
            ccall((:gtk_snapshot_append_scaled_texture,GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid},Cint,Ref{NTuple{4,Cfloat}}),
                  snap,texture,node.operation.state.sampling===:nearest ? 1 : 0,rect)
        finally
            ccall((:graphene_matrix_free,GTK),Cvoid,(Ptr{Cvoid},),matrix)
            ccall((:gtk_snapshot_pop,GTK),Cvoid,(Ptr{Cvoid},),snap)
            isnothing(p.mask) || ccall((:gtk_snapshot_pop,GTK),Cvoid,(Ptr{Cvoid},),snap)
        end
    finally
        tiled && unref_object(texture)
    end
end

"""Record a prepared node and its clips into a GTK snapshot in physical pixel coordinates."""
function append_node(snap,node,frame,viewport,bounds,s,candidate,used,retention)
    op = node.operation
    layers = 0
    try
        if op isa Vellum.CompositeGroup
            ccall((:gtk_snapshot_push_opacity,GTK),Cvoid,(Ptr{Cvoid},Cdouble),snap,op.opacity)
            layers += 1
            foreach(child -> append_node(snap,child,frame,viewport,bounds,s,candidate,used,retention),op.nodes)
        else
            for clip in op.state.clips
                push_path(snap,OpenGLBackend.device_geometry(clip.path,viewport*clip.transform,clip.winding))
                layers += 1
            end
            op isa Vellum.ImageRegion && return append_image(snap,node,frame,viewport,s,candidate,used,retention)
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
    s.backend === backend && plan.backend === backend || throw(ArgumentError("foreign Vulkan plan"))
    return with_gdk_context(() -> draw_retained!(s,plan))
end

"""Submit a retained tree to a window or texture. Rebuild size-dependent nodes after resize."""
function draw_retained!(s,plan,size=s.size;to_window=false)
    s.drawing && throw(ArgumentError("GSK draw is already recording"))
    frame = plan.frame
    viewport = Vellum.Transform2D(size[1]/frame.size[1],0,0,size[2]/frame.size[2],0,0)
    bounds = (0f0,0f0,Float32(size[1]),Float32(size[2]))
    reuse = s.size == size && s.frame !== nothing && s.frame.canvas == frame.canvas && s.frame.size == frame.size && s.frame.resources === frame.resources
    candidate = empty(s.nodes)
    sources = SourceTextures(empty(s.sources.images),0,0)
    reused = 0
    retention = Vellum.execution_retention(plan)
    s.drawing = true
    try
        root = recorded_node() do snap
            for node in frame.nodes
                entry = reuse ? get(s.nodes,node.id,nothing) : nothing
                if entry !== nothing && entry.semantic === node
                    ptr = entry.pointer
                    used = entry.textures
                    for key in used
                        get!(sources.images,key) do
                            OpenGLBackend.reserve_desktop_page!(sources,key)
                            ref_object(s.sources.images[key])
                        end
                    end
                    ptr != C_NULL && ccall((:gsk_render_node_ref,GTK),Ptr{Cvoid},(Ptr{Cvoid},),ptr)
                    reused += 1
                else
                    used = Set{OpenGLBackend.DesktopTextureKey}()
                    ptr = recorded_node(child -> append_node(child,node,frame,viewport,bounds,s,sources,used,retention))
                end
                candidate[node.id] = DeviceNode(node,ptr,used)
                ptr != C_NULL && ccall((:gtk_snapshot_append_node,GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid}),snap,ptr)
            end
        end
        texture = if to_window
            root == C_NULL && (root = transparent_node(bounds))
            try
                ccall((:gsk_renderer_render,GTK),Cvoid,(Ptr{Cvoid},Ptr{Cvoid},Ptr{Cvoid}),s.renderer,root,C_NULL)
                C_NULL
            finally
                drop_node(root)
            end
        else
            render_texture(s.renderer,root,bounds)
        end
        s.texture != C_NULL && ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),s.texture)
        s.texture,s.nodes,s.frame,candidate = texture,candidate,frame,s.nodes
        sources.uploaded_bytes += s.sources.uploaded_bytes
        s.sources,sources = sources,s.sources
        s.size = size
        s.draws += 1
        s.reused = reused
        return s
    finally
        s.drawing = false
        Vellum.close_retention(retention)
        foreach(entry -> drop_node(entry.pointer),values(candidate))
        foreach(unref_object,values(sources.images))
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

"""
    statistics(surface::DesktopSurface)

Report the GSK renderer, completed draws, reused nodes and resident sources. The cumulative
`uploaded_bytes` includes transfers from failed draws. `committed_upload_bytes` counts published draws.
"""
function statistics(s::DesktopSurface)
    check_open(s)
    name = ccall((:g_type_name_from_instance,GTK),Cstring,(Ptr{Cvoid},),s.renderer)
    return (;renderer=unsafe_string(name),frames=s.draws,reused=s.reused,s.uploaded_bytes,
            committed_upload_bytes=s.sources.uploaded_bytes,resident_images=length(s.sources.images))
end

"""Release all retained drawing nodes, the completed texture and the realized Vulkan renderer."""
function Base.close(s::DesktopSurface)
    main_thread()
    s.renderer == C_NULL && return
    s.drawing && throw(ArgumentError("GSK draw is recording"))
    foreach(unref_object,values(s.sources.images))
    empty!(s.sources.images)
    foreach(entry -> drop_node(entry.pointer),values(s.nodes))
    empty!(s.nodes)
    s.texture != C_NULL && ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),s.texture)
    ccall((:gsk_renderer_unrealize,GTK),Cvoid,(Ptr{Cvoid},),s.renderer)
    ccall((:g_object_unref,GTK),Cvoid,(Ptr{Cvoid},),s.renderer)
    s.renderer = s.texture = C_NULL
    s.frame = nothing
end
