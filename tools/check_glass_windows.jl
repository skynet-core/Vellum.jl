using Test, Vellum

"""Open the glass tutorial through its real desktop event loop and compare the first presented frame."""
function check_windows(app)
    @testset "Glass toolbar desktop presentations" begin
        for platform in (:wayland,:x11), target in (:opengl,:vulkan)
            seen = Ref(false)
            Vellum.GLHost.run_interactive(app;platform,target,before_swap=(window,state,image)->begin
                @test Vellum.GLHost.backend(window) === platform
                @test (image.width,image.height) == Vellum.GLHost.framebuffer_size(window)
                reference = rasterize(app.frames[state];size=(image.width,image.height))
                error = sum(abs(Int(actual)-Int(want)) for (actual,want) in zip(image.data,reference.data))/length(image.data)
                @test error < 4.5
                println(platform," / ",target," · ",image.width," × ",image.height," · mean RGBA error ",round(error;digits=3))
                seen[] = true
                Vellum.GLHost.request_close!(window)
            end)
            @test seen[]
        end
    end
end

mktempdir() do out
    withenv("VELLUM_TUTORIAL_HOST"=>"browser","VELLUM_TUTORIAL_OUTPUT"=>out) do
        for (file,entry) in (("glass_controls.jl",:atlas),("liquid_glass.jl",:mixer))
            lesson = Module(gensym(:GlassWindowCheck))
            Core.eval(lesson,:(include(p)=Base.include($lesson,p)))
            Base.include(lesson,joinpath(pkgdir(Vellum),"tutorials",file))
            check_windows(Base.invokelatest(getproperty,lesson,entry))
        end
    end
end
