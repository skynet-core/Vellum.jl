"""A recording provider for testing one-shot surface ownership and cleanup."""
struct SurfaceTestBackend <: Backend
    events::Vector{Symbol}
    failure::Symbol
end

"""An owned test surface that records explicit transfers and destruction."""
struct SurfaceTestTarget <: Surface
    backend::SurfaceTestBackend
    size::Tuple{Int,Int}
end

"""The test renderer accepts a solid filled path under the device-space precision contract."""
Vellum.capabilities(::SurfaceTestBackend) = Capabilities(features=(:fill_path,:path_precision_1_256px))

"""Record a surface allocation of the requested physical extent."""
function Vellum.make_surface(backend::SurfaceTestBackend, size)
    push!(backend.events, :allocate)
    return SurfaceTestTarget(backend,size)
end

"""Record execution and optionally raise a test driver error."""
function Vellum.execute!(backend::SurfaceTestBackend, surface::SurfaceTestTarget, ::PreparedFrame)
    push!(backend.events, :execute)
    backend.failure === :execute && error("execution failed")
    return surface
end

"""Return a fresh test image unless the driver failed during transfer."""
function Vellum.readback(surface::SurfaceTestTarget)
    push!(surface.backend.events, :readback)
    surface.backend.failure === :readback && error("readback failed")
    return new_image(surface.size...)
end

"""Record release of the caller's render target."""
Base.close(surface::SurfaceTestTarget) = (push!(surface.backend.events, :close); nothing)

"""Test backend dispatch, explicit pixel transfers and cleanup after driver errors."""
function test_surfaces()
    @testset "Portable scene at native and double resolution" begin
        frame = drawing_contract_frame()
        for scale in (1,2)
            image = rasterize(frame;size=frame.size .* scale)
            for (x,y,expected) in drawing_contract_probes()
                actual = image[y*scale+1,x*scale+1]
                @test all(abs(Int(getfield(actual,c))-Int(getfield(expected,c))) <= 1 for c in 1:4)
            end
            # The two captured glyphs must occupy both halves of their reference region.
            for columns in (66:76,78:87)
                @test any(image[y,x].r < 96 for y in (11scale):(22scale),
                          x in (first(columns)*scale):(last(columns)*scale))
            end
        end
    end
    @testset "Surface ownership at the drawing API" begin
        frame = drawing(size=(8,4)) do edit
            rectangle!(edit,0,0,2,3;fill=Solid(1,0,0))
        end
        backend = SurfaceTestBackend(Symbol[], :none)
        surface = render(frame; backend)
        @test backend.events == [:allocate,:execute]
        close(surface)
        empty!(backend.events)
        @test size(rasterize(frame; backend, size=(16,8))) == (8,16)
        @test backend.events == [:allocate,:execute,:readback,:close]
        for (failure, expected) in ((:execute, [:allocate,:execute,:close]),
                                    (:readback, [:allocate,:execute,:readback,:close]))
            backend = SurfaceTestBackend(Symbol[],failure)
            @test_throws ErrorException rasterize(frame; backend)
            @test backend.events == expected
        end
        cpu = CPUBackend.Renderer()
        try
            surface = render(frame; backend=cpu)
            image = readback(surface)
            fill!(image, rgba(0,0,0,0))
            @test readback(surface)[1,1] == rgbx(255,0,0,255)
            close(surface)
        finally
            close(cpu)
        end
    end
end
