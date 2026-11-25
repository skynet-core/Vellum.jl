using Vellum
include("desktop.jl")

"""The installed first-party GLX renderer, loaded without opening a drawable."""
const GLXRenderer = Vellum.OpenGLBackend.glx_extension()
"""OpenGL library used by the renderer and the timer queries on its context."""
const timer_gl = GLXRenderer.libGL

"""Collect one submission between GPU timestamps and measure host readback after completion."""
function timed_draw(surface, plan, queries)
    native = surface.native
    sample = GLXRenderer.with_context(native) do
        ccall((:glQueryCounter,timer_gl),Cvoid,(Cuint,Cuint),queries[1],0x8e28)
        start = time_ns()
        submit = @timed submit!(plan.backend,surface,plan)
        stop = time_ns()
        ccall((:glQueryCounter,timer_gl),Cvoid,(Cuint,Cuint),queries[2],0x8e28)
        first_gpu,last_gpu = map(queries) do id
            timestamp = Ref{UInt64}()
            ccall((:glGetQueryObjectui64v,timer_gl),Cvoid,(Cuint,Cuint,Ref{UInt64}),id,0x8866,timestamp)
            timestamp[]
        end
        ccall((:glGetError,timer_gl),Cuint,()) == 0 || error("GL timestamp query failed")
        last_gpu > first_gpu || error("OpenGL timestamps did not advance")
        wait(submit.value)
        (;start,stop,first_gpu,last_gpu,submit_bytes=submit.bytes)
    end
    read_start = time_ns()
    transfer = @timed readback(surface)
    read_stop = time_ns()
    return (;sample...,read_start,read_stop,read_bytes=transfer.bytes),transfer.value
end

"""Profile solid paths on a real OpenGL target and check every readback against the CPU image."""
function profile_gl(dir)
    frame = profile_frame()
    expected = rasterize(frame)
    surface = render(frame;backend=Vellum.OpenGLBackend.DesktopBackend())
    plan = prepare(surface.backend,frame)
    try
        rows = GLXRenderer.with_context(surface.native) do
            bits = Ref{Cint}()
            ccall((:glGetQueryiv,timer_gl),Cvoid,(Cuint,Cuint,Ref{Cint}),0x8e28,0x8864,bits)
            bits[] > 0 || error("OpenGL timestamp queries unavailable on this device")
            ids = zeros(Cuint,2)
            ccall((:glGenQueries,timer_gl),Cvoid,(Cint,Ptr{Cuint}),2,ids)
            try
                samples = map(1:35) do _
                    row,image = timed_draw(surface,plan,ids)
                    all(i -> abs(Int(expected.data[i])-Int(image.data[i])) <= 1,eachindex(image.data)) ||
                        error("profiled GPU output differs from the reference")
                    row
                end
                return samples[6:end]
            finally
                ccall((:glDeleteQueries,timer_gl),Cvoid,(Cint,Ptr{Cuint}),2,ids)
            end
        end
        write_device_profile(dir,rows,Vellum.OpenGLBackend.statistics(surface),"OpenGL")
    finally
        close(plan)
        close(surface)
    end
end

profile_gl(isempty(ARGS) ? joinpath(pkgdir(Vellum),"profiles") : abspath(only(ARGS)))
