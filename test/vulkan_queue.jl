using Vellum, Test

"""
    check_queue_vectors()

Draw the portable contract on a real Vulkan compute queue and check every channel and the pending-frame lifecycle.
"""
function check_queue_vectors()
    vk = Vellum.VulkanBackend
    @test_throws ArgumentError vk.QueueBackend(device=:unknown)
    @test_throws ArgumentError vk.QueueBackend(device=(true,1))
    @test_throws ArgumentError make_surface(vk.QueueBackend(),(1921,1081))
    frame = drawing_contract_frame()
    reference = rasterize(frame)
    backend = vk.QueueBackend()
    s = make_surface(backend,frame.size)
    try
        @test_throws ArgumentError readback(s)
        token = submit!(backend,s,frame)
        @test vk.statistics(s).pending
        @test_throws ArgumentError submit!(backend,s,frame)
        @test_throws ArgumentError readback(s)
        @test wait(token) === token && completed(token)
        check_resident_pixels(s,reference)
        stats = vk.statistics(s)
        @test stats.frames == 1 && !stats.pending && !isempty(stats.renderer)
        @test isnothing(stats.gpu_ns) == iszero(stats.timestamp_valid_bits)
        if stats.gpu_ns !== nothing
            @test stats.gpu_ns > 0 && stats.timestamp_period_ns > 0
        end
        @test rasterize(frame;target=:vulkan,device=stats.pci).data == readback(s).data
        withenv("DISPLAY"=>nothing,"WAYLAND_DISPLAY"=>nothing,"WAYLAND_SOCKET"=>nothing) do
            @test rasterize(frame;target=:vulkan).data == readback(s).data
        end
        @test_throws ArgumentError make_surface(vk.QueueBackend(device=(0xfffffffe,0xfffffffe)),frame.size)
        for f in (queue_paints_frame(),frame)
            wait(submit!(backend,s,f))
            check_resident_pixels(s,rasterize(f;size=Int.(frame.size)))
        end
        empty_frame = snapshot(Canvas(size=frame.size))
        discarded = submit!(backend,s,empty_frame)
        check_resident_pixels(s,reference)
        cancel!(discarded)
        cancel!(discarded)
        @test !completed(discarded)
        @test_throws ArgumentError wait(discarded)
        check_resident_pixels(s,reference)
        replacement = submit!(backend,s,empty_frame)
        @test timedwait(()->completed(replacement),10;pollint=0.001) === :ok
        @test all(iszero,readback(s).data)
        @test vk.statistics(s).frames == 4
        pending = submit!(backend,s,frame)
        close(s)
        @test !completed(pending)
        @test_throws ArgumentError readback(s)
        @test_throws ArgumentError submit!(backend,s,frame)
        println("Vulkan queue contract: ",stats)
    finally
        close(s)
    end
end

"""
    check_queue_sources(registry,cpu,fixtures)

Check exact page reuse, inactive cache hits, failed provider IO and cancellation on the owned queue.
"""
function check_queue_sources(registry,cpu,fixtures)
    (;first,second,retry,cropped,sparse,reference,changed,faulty) = fixtures
    vk = Vellum.VulkanBackend
    b = vk.QueueBackend(raster_registry=registry)
    s = make_surface(b,first.size)
    draw(frame) = wait(submit!(b,s,frame))
    try
        draw(first)
        check_resident_pixels(s,reference)
        baseline = vk.statistics(s)
        @test baseline.uploaded_bytes == 4112 && baseline.cached_pages==2
        candidate = submit!(b,s,second)
        check_resident_pixels(s,reference)
        cancel!(candidate)
        @test vk.statistics(s).committed_upload_bytes == 4112
        draw(first)
        @test vk.statistics(s).uploaded_bytes == 4112+2048
        check_resident_pixels(s,reference)
        draw(second)
        check_resident_pixels(s,changed)
        @test vk.statistics(s).committed_upload_bytes == 4112+2048
        @test vk.statistics(s).cached_pages == 3
        before = vk.statistics(s)
        draw(second)
        @test vk.statistics(s).uploaded_bytes == before.uploaded_bytes
        faulty.fail = true
        empty!(faulty.reads)
        before = vk.statistics(s)
        @test_throws "injected tile read failure" submit!(b,s,retry)
        @test sort(faulty.reads) == [0,64]
        @test vk.statistics(s)==before
        check_resident_pixels(s,changed)
        faulty.fail = false
        draw(retry)
        check_resident_pixels(s,reference)
        draw(sparse)
        check_resident_pixels(s,rasterize(sparse;backend=cpu))
        before = vk.statistics(s)
        draw(cropped)
        check_resident_pixels(s,rasterize(cropped;backend=cpu))
        @test vk.statistics(s).uploaded_bytes == before.uploaded_bytes
    finally
        close(s)
        empty!(faulty.reads)
        faulty.fail = true
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    include("fixtures/drawing_contract.jl")
    include("queue_kernel.jl")
    include("desktop_images.jl")
    @testset "Owned Vulkan queue" begin
        check_queue_vectors()
        withenv("VELLUM_TEST_VULKAN_QUEUE"=>"required") do
            test_desktop_images()
        end
    end
end
