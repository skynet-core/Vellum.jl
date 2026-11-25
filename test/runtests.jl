using Test, Vellum, Base64

const fontfile = joinpath(@__DIR__, "fixtures", "LiberationSans-Regular.ttf")
include("images.jl")
include("scenes.jl")
include("text.jl")
include("storage.jl")
include("browser.jl")
include("data_drawing.jl")
include("rendering.jl")
include("surfaces.jl")
include("fixtures/drawing_contract.jl")
include("queue_kernel.jl")
include("tiles.jl")
include("regressions.jl")
include("hosts.jl")
include("graphics.jl")
Sys.islinux() && include("wayland.jl")

function run_suite()
    @testset "Vellum" begin
        test_images()
        test_scenes()
        test_text()
        test_storage()
        test_opencv()
        test_browser()
        @testset "Data-driven drawing" test_data_drawing()
        @testset "Vulkan Julia draw kernel" begin
            QueueKernelTests.compare(drawing_contract_frame())
            QueueKernelTests.compare(queue_paints_frame())
            QueueKernelTests.compare(queue_filtered_frame())
            QueueKernelTests.compare(queue_deep_frame(8))
            @test_throws ArgumentError QueueKernelTests.render_kernel(queue_deep_frame(9),(12,12))
            @test_throws ArgumentError Vellum.OpenGLBackend.pack_frame(queue_deep_frame(3),(12,12))
            test_queue_window_geometry()
            test_queue_atlas()
        end
        test_rendering()
        test_surfaces()
        test_tiles()
        test_regressions()
        test_hinting()
        test_hosts()
        test_graphics()
        Sys.islinux() && test_wayland()
    end
end

run_suite()
if length(ARGS) == 2 && first(ARGS) == "--profile"
    include(joinpath(@__DIR__, "..", "tools", "profile", "cpu.jl"))
    cpu_profile(run_suite, abspath(last(ARGS)))
end
