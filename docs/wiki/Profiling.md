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

For a tiled desktop image, look up the crop layout, page bounds, edge-page dimensions and cache partition workloads in this table. The renderer's `statistics(surface).uploaded_bytes` counts source bytes transferred, including abandoned candidates. Compare it with `committed_upload_bytes` to see how much upload work belonged to published frames.

## Time a Wasm frame on each browser backend

From the checkout, run the browser integration suite with its profiling flag on a desktop graphics driver. This workload uses a Julia `DataDrawing` with 256 rectangles and replays it through Vellum's production Wasm program on Canvas 2D, WebGL2 and WebGPU.

```julia
using Pkg
Pkg.activate("tools/browser")
Pkg.instantiate()
Pkg.activate(".")
push!(LOAD_PATH, abspath("tools/browser"))
append!(ARGS, ["--headed", "--browser-profile"])
include("tools/browser/check.jl")
```

Open `profiles/canvas.html`, `profiles/webgl2.html` or `profiles/webgpu.html` to see the browser, framebuffer size and distributions for 51 warmed draws. Each report links to the raw samples. Host submission measures the synchronous update. Readback includes waiting for a pixel, checked against its expected RGBA value on every submission. These intervals can overlap.

WebGL2 device time comes from an elapsed-time query. WebGPU uses timestamp writes at the start and end of the production render pass, then copies the timestamps and pixel into a readable buffer. Only the profiling page requests the optional device feature. Canvas 2D exposes host submission and pixel-readback timings. The graphics reports identify the device, and the runner reports unavailable or interrupted queries. Browser timestamp precision can give successive samples the same value or round a short interval to zero. [WebGL timer queries](https://registry.khronos.org/webgl/extensions/EXT_disjoint_timer_query_webgl2/) · [WebGPU timestamp queries](https://www.w3.org/TR/webgpu/#timestamp-query)

## Time CUDA drawing helpers

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

On an X11 desktop, run `julia --project=environments/desktop tools/profile/opengl.jl` for the first-party OpenGL provider. Open `profiles/opengl.html` for median and p95 across 30 post-warm-up frames. The CPU and GPU clocks each have their own origin in `profiles/opengl.trace.json`. Load this file in Perfetto to inspect per-frame durations. The host readback starts after the final GPU timestamp becomes available.

## Time an offscreen Vulkan frame

Run `julia --project=environments/desktop tools/profile/vulkan.jl` on a Float64-capable Vulkan device with queue timestamps. Open `profiles/vulkan.html` for 30 warmed draws of 32 paths. Each draw submits the production compute kernel, waits for its fence and checks every output channel against the CPU renderer. The GPU interval covers queued input transfers and the draw. The host readback copies the published mapped output. Open `profiles/vulkan.trace.json` in Perfetto to inspect submission, execution and readback per frame. [Vulkan timestamp semantics](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdWriteTimestamp.html)

The same command measures the 13 Julia drawing functions used in the Vulkan kernel. Open `profiles/vulkan-methods.html` and follow a definition to its Julia source. For each function, a specialized compute dispatch writes 8,192 results from runtime inputs. The runner checks each result against Julia and records 51 post-warm-up device intervals. Each interval includes shader-side argument preparation, inlined callees and the output store.
