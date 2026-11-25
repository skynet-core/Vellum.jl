using Test, Pkg, Vellum

# tools/ci.jl launches this as an ordinary consumer with only Vellum added.
@testset "Headless consumer installation" begin
    dependencies = Set(p.name for p in values(Pkg.dependencies()))
    desktop = Set(("GLFW_jll","OpenCV_jll","Wayland_jll","Skia","Skia_jll","Libglvnd_jll","Qt6Base_jll","Vulkan_Loader_jll","VulkanCore","Shaderc_jll"))
    @test isempty(intersect(dependencies,desktop))
    @test !any(name->startswith(name,"Xorg_"),dependencies)
    @test isnothing(Base.get_extension(Vellum,:VellumGLXExt))
    @test isnothing(Base.get_extension(Vellum,:VellumVulkanExt))
    @test_throws "VulkanCore" Vellum.VulkanBackend.queue_extension()
    @test_throws "HarfBuzz_jll" Vellum._requireHarfBuzz()
    @test_throws "GLFW_jll" Vellum.GLHost.library_path()
    if Sys.islinux()
        @test_throws "Wayland_jll" Vellum.WaylandSHM.client_symbols()
        @test isnothing(Vellum.WaylandSHM.client_table[])
    end
    if Sys.islinux() || Sys.isfreebsd()
        @test_throws ArgumentError Vellum.OpenGLBackend.glx_extension()
    end
    @test !only(filter(p->p.format===:webp,Vellum.ImageCodecs.providers())).available

    source = Image(2,2)
    fill!(source,rgbx(35,82,137,255))
    mktempdir() do dir
        input = joinpath(dir,"source.png")
        write_file!(source,input)
        decoded = read_image(input)
        frame = drawing(size=(5,4)) do edit
            draw_image!(edit,resource!(edit,decoded),(0,0,5,4))
        end
        output = joinpath(dir,"result.png")
        savepng(output,frame)
        result = read_image(output)
        @test size(result)==(4,5)
        @test result[2,3]==source[1,1]
        @test occursin("application/wasm",read(savehtml(joinpath(dir,"scene.html"),frame;target=:webgl2),String))
    end
end
