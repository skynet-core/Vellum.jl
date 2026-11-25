using Vellum, Test

"""A revision which can interrupt the second tile read after the first reached the renderer."""
mutable struct InterruptedRaster <: Vellum.ImageTiles.AbstractRasterRevision
    source::Vellum.ImageTiles.OwnedTileRevision
    fail::Bool
    reads::Vector{Int}
end

"""Describe the exact underlying test revision."""
Vellum.ImageStorage.image_metadata(s::InterruptedRaster) = Vellum.ImageStorage.image_metadata(s.source)
"""Forward the immutable revision tag."""
Vellum.ImageStorage.storage_revision(s::InterruptedRaster) = Vellum.ImageStorage.storage_revision(s.source)
"""Charge the same validated source storage to the test registry."""
Vellum.ImageTiles.retained_bytes(s::InterruptedRaster) = Vellum.ImageTiles.retained_bytes(s.source)
"""Release the test authority when its final pin closes."""
Base.close(s::InterruptedRaster) = close(s.source)

"""Record each source read and inject a recoverable failure on the second page."""
function Vellum.ImageStorage.borrow_pixels(s::InterruptedRaster,region;kwargs...)
    push!(s.reads,region[1])
    s.fail && region[1] >= 64 && error("injected tile read failure")
    return Vellum.ImageStorage.borrow_pixels(s.source,region;kwargs...)
end

"""Compose a dense patch and two adjacent tiled colors at twice their source scale."""
function resident_frame(descriptor,dense;crop=nothing)
    return drawing(size=(256,16)) do e
        configure!(e;sampling=:linear)
        draw_image!(e,resource!(e,:image,descriptor),(0,0,256,16);source=crop)
        draw_image!(e,resource!(e,:image,dense),(0,0,4,4))
    end
end

"""Compare every physical channel, including the interpolated seam, with the CPU reference."""
function check_resident_pixels(surface,reference)
    actual = readback(surface)
    @test size(actual) == size(reference)
    @test maximum(abs.(Int.(actual.data) .- Int.(reference.data))) <= 1
end

"""Exercise source reuse, failure, cancellation, retry and release using the public drawing lifecycle."""
function test_desktop_images()
    pages = Vellum.ImageTiles
    gpu = Vellum.OpenGLBackend
    registry = pages.RasterRegistry(namespace=18,source_bytes=1024^2,max_assets=8,max_revisions=8,max_leases=32)
    pins = pages.AbstractRevisionLease[]
    cpu = CPUBackend.Renderer(raster_registry=registry)
    try
        page(color) = pages.RgbaTile(64,8,repeat(UInt8[color...],64*8))
        shared = page((255,0,0,255))
        right = page((0,0,255,255))
        green = page((0,255,0,255))
        source(other) = pages.OwnedTileRevision(128,8,[((0,0),shared),((1,0),other)];tile_size=64,share_pages=true)
        first_ref,pin = pages.publish_revision!(registry,source(right))
        push!(pins,pin)
        next_ref,pin = pages.publish_revision!(registry,source(green);asset=first_ref.asset)
        push!(pins,pin)
        faulty = InterruptedRaster(source(right),true,Int[])
        retry_ref,pin = pages.publish_revision!(registry,faulty)
        push!(pins,pin)
        blank_ref,pin = pages.publish_revision!(registry,pages.OwnedTileRevision(128,8,[];tile_size=64,share_pages=true))
        push!(pins,pin)
        patch = Image(2,2)
        fill!(patch,rgbx(50,80,100,255))
        dense = ImageData(patch)
        first = resident_frame(first_ref,dense)
        second = resident_frame(next_ref,dense)
        retry = resident_frame(retry_ref,dense)
        cropped = resident_frame(first_ref,dense;crop=(55.5,0,16,8))
        sparse = resident_frame(blank_ref,dense)
        reference = rasterize(first;backend=cpu)
        changed = rasterize(second;backend=cpu)
        backend = gpu.DesktopBackend(raster_registry=registry)
        @test_throws CapabilityError prepare(gpu.DesktopBackend(),first)
        plan = prepare(backend,second)
        try
            placement = gpu.image_placement(second.nodes[1],second,Transform2D())
            @test gpu.desktop_page_grid((63,0,65,1)) == (0:1,0:0)
            @test_throws ModelError gpu.desktop_page_grid((0,0,16384,16384))
            visited = Int[]
            gpu.visit_desktop_pages(plan.retention,placement) do key,(x,y),bytes
                @test y == 0
                push!(visited,x)
                @test sizeof(bytes()) == 64*8*4
            end
            @test visited == [0,64]
        finally
            close(plan)
        end
        @test_throws ModelError gpu.visit_desktop_pages((args...)->nothing,plan.retention,
            gpu.image_placement(second.nodes[1],second,Transform2D()))
        retry_plan = prepare(backend,retry)
        try
            p = gpu.image_placement(retry.nodes[1],retry,Transform2D())
            @test_throws ErrorException gpu.visit_desktop_pages(retry_plan.retention,p) do key,offset,load
                load()
            end
            @test faulty.reads == [0,64]
            empty!(faulty.reads)
        finally
            close(retry_plan)
        end
        fixtures = (;first,second,retry,cropped,sparse,reference,changed,faulty)
        if get(ENV,"VELLUM_TEST_VULKAN","") == "required"
            check_vulkan_sources(registry,cpu,fixtures)
        end
        if get(ENV,"VELLUM_TEST_OPENGL","") == "required"
            check_gl_sources(backend,cpu,fixtures)
        end
    finally
        close(cpu)
        foreach(close,pins)
        close(registry)
    end
end

"""Check retained Vulkan textures, node reuse, independent CPU pixels and rollback on the actual renderer."""
function check_vulkan_sources(registry,cpu,fixtures)
    (;first,second,retry,cropped,sparse,reference,changed,faulty) = fixtures
    vk = Vellum.VulkanBackend
    vulkan = vk.DesktopBackend(raster_registry=registry)
    surface = make_surface(vulkan,first.size)
    draw(frame) = begin
        prepared = prepare(vulkan,frame)
        try
            execute!(vulkan,surface,prepared)
        finally
            close(prepared)
        end
    end
    try
        draw(first)
        check_resident_pixels(surface,reference)
        original = vk.statistics(surface)
        @test original.uploaded_bytes == 2*64*8*4 + 2*2*4
        @test original.resident_images == 3
        for texture in values(surface.sources.images)
            storage = unsafe_string(ccall((:g_type_name_from_instance,Vellum.VulkanBackend.GTK),
                                          Cstring,(Ptr{Cvoid},),texture))
            @test storage in ("GdkDmabufTexture","GdkGLTexture","GdkVulkanTexture")
        end
        draw(second)
        committed = vk.statistics(surface)
        @test committed.uploaded_bytes-original.uploaded_bytes == 64*8*4
        check_resident_pixels(surface,changed)
        draw(second)
        @test vk.statistics(surface).uploaded_bytes == committed.uploaded_bytes
        @test vk.statistics(surface).reused == length(second.nodes)
        before_error = vk.statistics(surface)
        @test_throws ErrorException draw(retry)
        @test faulty.reads == [0,64]
        @test vk.statistics(surface) == merge(before_error,(uploaded_bytes=before_error.uploaded_bytes+64*8*4,))
        check_resident_pixels(surface,changed)
        faulty.fail = false
        draw(retry)
        check_resident_pixels(surface,reference)
        draw(cropped)
        check_resident_pixels(surface,rasterize(cropped;backend=cpu))
        draw(sparse)
        check_resident_pixels(surface,rasterize(sparse;backend=cpu))
        @test vk.statistics(surface).resident_images == 1
        draw(snapshot(Canvas(size=first.size)))
        @test vk.statistics(surface).resident_images == 0 && all(iszero,readback(surface).data)
        println("Vulkan committed texture transfers: ",original," -> ",committed)
    finally
        close(surface)
        empty!(faulty.reads)
        faulty.fail = true
    end
end

"""Check GL fence publication, cancellation and cleanup through the public surface API."""
function check_gl_sources(backend,cpu,fixtures)
    gpu = Vellum.OpenGLBackend
    (;first,second,retry,cropped,sparse,reference,changed,faulty) = fixtures
    surface = make_surface(backend,first.size)
    try
        token = submit!(backend,surface,first)
        @test gpu.statistics(surface).pending
        @test_throws ArgumentError readback(surface)
        @test_throws ArgumentError submit!(backend,surface,second)
        @test wait(token) === token && completed(token)
        check_resident_pixels(surface,reference)
        original = gpu.statistics(surface)
        @test original.resident_images == 3
        @test original.uploaded_bytes == 2*64*8*4 + 2*2*4
        @test_throws ArgumentError cancel!(token)
        token = submit!(backend,surface,second)
        check_resident_pixels(surface,reference)
        cancel!(token)
        cancel!(token)
        @test !completed(token)
        @test_throws ArgumentError wait(token)
        @test gpu.statistics(surface) == merge(original,(uploaded_bytes=original.uploaded_bytes+64*8*4,))
        check_resident_pixels(surface,reference)
        token = submit!(backend,surface,second)
        @test timedwait(()->completed(token),5) === :ok
        check_resident_pixels(surface,changed)
        committed = gpu.statistics(surface)
        @test committed.committed_upload_bytes - original.committed_upload_bytes == 64*8*4
        @test committed.uploaded_bytes - original.uploaded_bytes == 2*64*8*4
        @test committed.resident_images == 3
        wait(submit!(backend,surface,second))
        @test gpu.statistics(surface).uploaded_bytes == committed.uploaded_bytes
        before_error = gpu.statistics(surface)
        @test_throws ErrorException submit!(backend,surface,retry)
        @test faulty.reads == [0,64]
        @test gpu.statistics(surface) == merge(before_error,(uploaded_bytes=before_error.uploaded_bytes+64*8*4,))
        check_resident_pixels(surface,changed)
        faulty.fail = false
        wait(submit!(backend,surface,retry))
        @test faulty.reads == [0,64,0,64]
        check_resident_pixels(surface,reference)
        wait(submit!(backend,surface,cropped))
        check_resident_pixels(surface,rasterize(cropped;backend=cpu))
        wait(submit!(backend,surface,sparse))
        check_resident_pixels(surface,rasterize(sparse;backend=cpu))
        @test gpu.statistics(surface).resident_images == 1
        closing = submit!(backend,surface,second)
        close(surface)
        @test !completed(closing)
        @test_throws ArgumentError wait(closing)
        @test_throws ArgumentError readback(surface)
        println("OpenGL committed texture transfers: ",original," -> ",committed)
    finally
        close(surface)
    end
    recreated = render(first;backend)
    try
        check_resident_pixels(recreated,reference)
    finally
        close(recreated)
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    @testset "Desktop resident images" test_desktop_images()
end
