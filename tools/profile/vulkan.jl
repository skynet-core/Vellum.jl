using Vellum
include("desktop.jl")
include("vulkan_methods.jl")

"""
    profile_vulkan(dir)

Profile the actual queue dispatch, fence publication and mapped readback. Check every frame against CPU pixels.
"""
function profile_vulkan(dir)
    frame = profile_frame()
    expected = rasterize(frame)
    b = Vellum.VulkanBackend.QueueBackend()
    surface = make_surface(b,frame.size)
    plan = prepare(b,frame)
    try
        origin = nothing
        rows = map(1:35) do _
            start = time_ns()
            submit = @timed submit!(b,surface,plan)
            stop = time_ns()
            wait(submit.value)
            stats = Vellum.VulkanBackend.statistics(surface)
            isnothing(stats.gpu_ns) && error("this Vulkan queue has no device timestamps")
            stats.gpu_ns > 0 || error("Vulkan timestamps did not advance")
            first,last = stats.device_ticks
            isnothing(origin) && (origin = first)
            mask = typemax(UInt64) >> (64-Int(stats.timestamp_valid_bits))
            first_gpu = round(UInt64,((first-origin)&mask)*stats.timestamp_period_ns)
            last_gpu = first_gpu+round(UInt64,stats.gpu_ns)
            read_start = time_ns()
            transfer = @timed readback(surface)
            read_stop = time_ns()
            all(i -> abs(Int(expected.data[i])-Int(transfer.value.data[i])) <= 1,eachindex(expected.data)) ||
                error("Vulkan queue pixels differ from CPU reference")
            (;start,stop,first_gpu,last_gpu,submit_bytes=submit.bytes,read_start,read_stop,read_bytes=transfer.bytes)
        end
        stats = Vellum.VulkanBackend.statistics(surface)
        vendor = "PCI "*join(string.(stats.pci;base=16),':')*" · driver "*string(stats.driver_version)*
            " · queue "*string(stats.queue_family)*" · timestamp period "*string(stats.timestamp_period_ns)*" ns"
        write_device_profile(dir,rows[6:end],(;stats.renderer,vendor),"Vulkan")
    finally
        close(plan)
        close(surface)
    end
end

let dir = isempty(ARGS) ? joinpath(pkgdir(Vellum),"profiles") : abspath(only(ARGS))
    profile_vulkan(dir)
    profile_vulkan_methods(dir)
end
