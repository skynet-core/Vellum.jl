# Profiling

For a small workload, build the frame once, warm up the drawing call and measure allocated bytes in a second call. The result includes the temporary CPU renderer and the returned pixel buffer.

```julia
using Vellum
frame = drawing(size=(128, 96)) do edit
    rectangle!(edit, 12, 12, 60, 32; fill=Solid(0, 0.4, 0.7))
end
rasterize(frame)
bytes = @allocated rasterize(frame)
```

To profile the warmed test workload, start Julia with the checkout active and run `using Pkg; Pkg.test(; test_args=["--profile", abspath("profiles")])`. Open `profiles/cpu.cpuprofile` in VS Code to explore the stacks. The HTML table shows inclusive sample counts. A zero means the sampler did not observe that method.

Open `profiles/cpu-methods.html` for directly timed workloads and `profiles/cpu-methods.tsv` for their source signatures, sample sizes and revision. The runner uses prepared inputs and an output buffer, warms each workload, and times 51 batches. Median and p95 report nanoseconds per input, including the loop and output store. Allocation counts and bytes are per batch. The table lists methods still awaiting a direct measurement.

The CUDA helper workload needs a CUDA-capable device. From a fresh Julia session in the checkout, run the following.

```julia
using Pkg
Pkg.activate("tools/profile/gpu")
Pkg.instantiate()
Pkg.activate(".")
push!(LOAD_PATH, abspath("tools/profile/gpu"))
push!(ARGS, abspath("profiles/gpu.tsv"))
include("tools/profile/gpu.jl")
```

Open `profiles/gpu.html` for the numerical comparisons and median and p95 device times per batch. CUDA events cover execution of the helper kernels. A native draw has additional costs. CPU submission measures how long the host spends queuing work, device elapsed time measures execution on the GPU, and `readback(surface)` transfers completed pixels to a host image. The current CUDA report does not time an OpenGL or Vulkan draw.

On an X11 desktop, run `julia --project=. tools/profile/opengl.jl` for the first-party OpenGL provider. Open `profiles/opengl.html` for median and p95 across 30 post-warm-up frames. The CPU and GPU clocks each have their own origin in `profiles/opengl.trace.json`. Load this file in Perfetto to inspect per-frame durations. The host readback starts after the final GPU timestamp becomes available.
