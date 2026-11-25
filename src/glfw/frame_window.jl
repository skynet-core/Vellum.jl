"""Upload top-left RGBA pixels and blit them upright into the current window's back buffer."""
function present_image(window,image,texture,fbo,extent)
    proc(name) = proc_address(window,name)
    ccall(proc("glBindTexture"),Cvoid,(Cuint,Cuint),0x0de1,texture)
    ccall(proc("glTexParameteri"),Cvoid,(Cuint,Cuint,Cint),0x0de1,0x2801,0x2600)
    ccall(proc("glTexImage2D"),Cvoid,(Cuint,Cint,Cint,Cint,Cint,Cint,Cuint,Cuint,Ptr{UInt8}),
          0x0de1,0,0x8058,image.width,image.height,0,0x1908,0x1401,image.data)
    ccall(proc("glBindFramebuffer"),Cvoid,(Cuint,Cuint),0x8ca8,fbo)
    ccall(proc("glFramebufferTexture2D"),Cvoid,(Cuint,Cuint,Cuint,Cuint,Cint),
          0x8ca8,0x8ce0,0x0de1,texture,0)
    ccall(proc("glCheckFramebufferStatus"),Cuint,(Cuint,),0x8ca8) == 0x8cd5 ||
        error("tutorial window has an incomplete read framebuffer")
    ccall(proc("glBlitFramebuffer"),Cvoid,(Cint,Cint,Cint,Cint,Cint,Cint,Cint,Cint,Cuint,Cuint),
          0,0,image.width,image.height,0,extent[2],extent[1],0,0x4000,0x2600)
    ccall(proc("glBindFramebuffer"),Cvoid,(Cuint,Cuint),0x8ca8,0)
    ccall(proc("glGetError"),Cuint,()) == 0 || error("could not present the tutorial frame")
end

"""
    with_frame_window(callback, width, height, title; platform, target=:cpu)

Open an owned window and pass `callback(window, present)` a frame presenter. Call
`present(frame)` after model changes. The selected native backend renders at the actual
framebuffer extent. A readback and OpenGL blit present those pixels on either window system.
`before_swap(image)` optionally inspects the completed pixels while the window is current.
"""
function with_frame_window(callback,width,height,title;platform,target=:cpu)
    target in (:cpu,:opengl,:vulkan) || throw(ArgumentError("expected a native frame renderer"))
    backend = target===:cpu ? Vellum.CPUBackend.Renderer() : Vellum._drawing_native_backend(target,:auto)
    try
        with_window(width,height,title;platform,libdecor=platform !== :wayland) do window
            texture,fbo = Ref{Cuint}(0),Ref{Cuint}(0)
            proc(name) = proc_address(window,name)
            surface = nothing
            dimensions = (0,0)
            try
                ccall(proc("glGenTextures"),Cvoid,(Cint,Ref{Cuint}),1,texture)
                ccall(proc("glGenFramebuffers"),Cvoid,(Cint,Ref{Cuint}),1,fbo)
                function present(frame;before_swap=identity)
                    extent = framebuffer_size(window)
                    minimum(extent)>0 || return nothing
                    image = without_context(window) do
                        if dimensions!=extent
                            replacement = Vellum.make_surface(backend,extent)
                            isnothing(surface) || close(surface)
                            surface,dimensions = replacement,extent
                        end
                        plan = Vellum.prepare(backend,frame)
                        try
                            Vellum.execute!(backend,surface,plan)
                            Vellum.readback(surface)
                        finally
                            close(plan)
                        end
                    end
                    present_image(window,image,texture[],fbo[],extent)
                    before_swap(image)
                    swap_buffers(window)
                    return nothing
                end
                return callback(window,present)
            finally
                isnothing(surface) || without_context(() -> close(surface),window)
                ccall(proc("glDeleteFramebuffers"),Cvoid,(Cint,Ref{Cuint}),1,fbo)
                ccall(proc("glDeleteTextures"),Cvoid,(Cint,Ref{Cuint}),1,texture)
            end
        end
    finally
        target===:cpu && close(backend)
    end
end
