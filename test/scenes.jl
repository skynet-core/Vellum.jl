
function test_scenes()
    @testset "Retained edits, rendering, and wire revisions" begin
        c = Canvas(size=(24,16))
        initial = snapshot(c)
        red = Solid(1,0,0)
        id = transaction!(c) do e
            rectangle!(e,2,3,10,6;fill=red)
        end
        first = snapshot(c)
        im = rasterize(first)
        @test count(p->p.a==255,im) == 60
        @test im[4,3] == rgbx(255,0,0,255)
        @test isempty(initial.nodes)
        @test_throws ModelError transaction!(e->save(e),c)
        @test snapshot(c) === first
        state = Wire.decode_snapshot(Wire.encode_snapshot(first))
        @test rasterize(state.frame).data == im.data
        @test_throws ArgumentError Wire.decode_snapshot(UInt8[])
        gradient = LinearGradient((0,0),(12,0),(GradientStop(0,Color(0,0,0)), GradientStop(1,Color(1,1,1))))
        transaction!(c) do e
            replace_node!(e,id,rectangle_path(0,0,4,4))
            with_group(e;opacity=0.5) do child
                clip(child,rectangle_path(0,0,12,10))
                rectangle!(child,0,0,24,16;fill=gradient)
            end
        end
        second = snapshot(c)
        bytes, expected = Wire.encode_delta(state, second)
        decoded = Wire.apply_delta(state,bytes)
        @test rasterize(decoded.frame).data == rasterize(second).data
        @test decoded.frame.revision == expected.frame.revision
        @test rasterize(snapshot(Wire.fork_canvas(decoded))).data == rasterize(second).data
        @test rasterize(first).data == im.data
        mktempdir() do dir
            @test occursin("<path",writeSvg(joinpath(dir,"test.svg"),first))
            @test startswith(writePdf(joinpath(dir,"test.pdf"),first),"%PDF-")
            @test read_image(joinpath(dir,"test.svg")).data == im.data
        end
        renderer = CPUBackend.Renderer()
        try
            surface = render(second;backend=renderer)
            @test CPUBackend.pixels(surface).data == rasterize(second).data
            @test CPUBackend.scratch_usage(renderer).reserved_bytes > 0
        finally
            close(renderer)
        end
        view = Vellum.CanvasView(c)
        work = Vellum.request_work!(view,0)
        @test Vellum.complete!(view,work)
        @test Vellum.take_ready!(view) === work
        @test isnothing(Vellum.request_work!(view,1))
        Vellum.suspend!(view)
        @test isnothing(Vellum.request_work!(view,2))
        Vellum.resume!(view)
        @test !isnothing(Vellum.request_work!(view,3))
        close(view)
        @test_throws ModelError Vellum.request_work!(view,4)
    end

    @testset "Camera clipping, depth, and picking" begin
        S = Scene3D
        canvas = Canvas(size=(32,32))
        camera, mesh, material = transaction!(canvas) do e
            (resource!(e,:camera,S.Camera((0,0,0),(0,0,2),(0,1,0))),
             resource!(e,:mesh,S.Mesh(((-1,-1,2),(1,-1,2),(0,1,2)),((1,2,3),))),
             resource!(e,:material,S.Material(255,0,0)))
        end
        scene = S.Scene(snapshot(canvas),camera,(S.Instance(7,mesh,material),))
        renderer = S.SceneCPU()
        surface = make_surface(renderer,(32,32))
        try
            ticket = submit!(renderer,surface,scene)
            @test !completed(ticket)
            wait(ticket)
            @test S.pick(ticket,16,16) == (id=7,depth=2.0)
            @test isnothing(S.pick(ticket,0,0))
            @test S.detached_image(ticket).width == 32
            shaded = S.shade_image(ticket) do world,id
                id == 7 && world[3] ≈ 2 || error("incorrect visible surface sample")
                rgbx(21,42,63,255)
            end
            @test shaded[17,17] == rgbx(21,42,63,255)
            @test shaded[1,1] == rgbx(0,0,0,0)
            next = submit!(renderer,surface,scene)
            @test_throws ModelError S.shade_image(identity,next)
            cancel!(next)
            @test_throws ModelError wait(next)
            @test S.pick(ticket,16,16).id == 7
        finally
            close(surface)
        end
    end
end
