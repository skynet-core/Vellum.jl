# Vellum.jl

Vellum is a Julia drawing library with a CPU rasterizer, retained scenes, text shaping, image codecs, SVG/PDF export, and an interactive WebAssembly viewer. From the checkout, start Julia with `julia --project=.` and run the following.

```julia
using Pkg
Pkg.instantiate()
using Vellum

frame = drawing(size=(128, 96)) do edit
    rectangle!(edit, 16, 12, 80, 56; fill=Solid(0.2, 0.5, 0.8))
end
savepng("rectangle.png", frame)
savehtml("gallery.html", (rectangle=frame, empty=Canvas(size=(128,96))); target=:compare)
```

The HTML contains the WebAssembly module, scene data and browser renderer. Julia lowers supported paths, strokes, captured text, clips, groups and dense images to draw commands. Wasmtime assembles the scene program in-process. The browser runs it on scene selection. On every replay, Wasm calls Vellum’s Julia-authored host bindings. Canvas 2D fills paths directly. WebGL2 and WebGPU draw instanced trapezoids from Wasm memory with Vellum’s shaders. Captured text uses shaped outlines. Dynamic browser labels use the browser font engine to create small glyph textures. The page reports unavailable renderers individually. A compatible browser and graphics driver are required for GPU targets. A trusted Julia author file passed to `savehtml` runs in a Julia subprocess.

## Interactive workshops

Edit and run all eight tutorials in the [Docker playground](public/playground/readme.md). Its deployment guide covers the prebuilt images on GitHub Container Registry and local builds.

| Try it | Julia script | IJulia notebook |
| --- | --- | --- |
| Hover live Binance BTC/USDT one-minute candles, inspect OHLC and volume, and move the chart between browser Wasm, Wayland and X11 | [Candlesticks](tutorials/candlesticks.jl) | [Run the notebook](tutorials/candlesticks.ipynb) |
| Orbit a depth-tested surface and compose its mesh with shaped font labels | [3D surface](tutorials/surface_plot.jl) | [Run the notebook](tutorials/surface_plot.ipynb) |
| Build a reading-light panel with a switch, brightness slider and segmented selector | [Touch controls](tutorials/touch_controls.jl) | [Run the notebook](tutorials/touch_controls.ipynb) |
| Build a retained dashboard with gradient meters and linked trend lines | [Script](tutorials/signal_desk.jl) | [Notebook](tutorials/signal_desk.ipynb) |
| Animate and scrub a translucent market panel | [Script](tutorials/glass_market.jl) | [Notebook](tutorials/glass_market.ipynb) |
| Build a Liquid Glass component framework with reusable buttons, switches, sliders and a sound panel | [Framework tutorial](tutorials/liquid_glass.jl) | [Notebook](tutorials/liquid_glass.ipynb) |
| Build a macOS-inspired glass toolbar with animated pointer and keyboard feedback | [Script](tutorials/glass_controls.jl) | [Notebook](tutorials/glass_controls.ipynb) |

From the checkout run `julia --project=. tutorials/candlesticks.jl` and open `candlesticks.html`. The chart fetches public Binance market data without a key. Vellum compiles the shared drawing layers to Wasm for the browser. The same layers produce native frames. The browser uses the kline stream and refreshes from REST when needed. On a Linux desktop, set `ENV["VELLUM_TUTORIAL_HOST"] = "wayland"` or `"x11"` before including the chart script to open the same application in a native window.

## Tests and visual reports

The [Vellum wiki](https://github.com/skynet-core/Vellum.jl/wiki) and its [in-repository guides](docs/wiki/Home.md) cover installation, testing, profiling, and drawing from an immutable frame into an owned surface.

Run `using Pkg; Pkg.test()` with the repository project active. The generated reports open locally in a browser. To reproduce the desktop workload on Linux, set `ENV["VELLUM_TEST_GLFW"]="true"` and `ENV["VELLUM_TEST_WAYLAND"]="required"` in a Julia session with access to X11 and Wayland before running the tests or coverage tool.

| Report | What it measures |
| --- | --- |
| Source line coverage (`reports/coverage.html`) | Expand a file to see execution counts, missed lines and Julia source. |
| Coverage for editors (`reports/coverage.info`) | LCOV counts and repository-relative paths for source coverage overlays. |
| CPU samples (`profiles/cpu.html`) | Inclusive samples in the warmed test workload, with an inventory of package methods. |
| Direct CPU timings (`profiles/cpu-methods.html`) | Median and p95 time per input, allocations per batch, and the method definitions exercised by the pixel, geometry and codec workloads. |
| CPU stacks for VS Code (`profiles/cpu.cpuprofile`) | Open the file directly in VS Code to inspect the sampled stacks. |
| GPU timings (`profiles/gpu.html`) | CUDA event measurements for pixel blends, color helpers and geometry methods, checked against CPU results. Expand the method inventory to see which methods still lack a device measurement. |
| OpenGL frame profile (`profiles/opengl.html`) | Host submission, GPU timestamps and readback for a warmed frame, with a downloadable Perfetto timeline. |
| Cairo and Skia glyph comparisons (`reports/fonts.html`) | Actual-size and enlarged masks for the same positioned glyphs, with per-renderer alpha differences. |

Regenerate the coverage report with `julia --project=tools/coverage tools/coverage.jl reports/coverage.tsv`. It measures a fresh source copy and writes the HTML before enforcing the 95% minimum. To regenerate the CPU reports, run the following in the repository project.

```julia
using Pkg
Pkg.test(; test_args=["--profile", abspath("profiles")])
```

For GPU measurements, instantiate the environment with `julia --project=tools/profile/gpu -e 'using Pkg; Pkg.instantiate()'`. Then run the following in Julia with the repository project active on a CUDA-capable machine. The script reports any numerical differences and exits unsuccessfully when its comparison tolerance is exceeded.

```julia
push!(LOAD_PATH, abspath("tools/profile/gpu"))
push!(ARGS, abspath("profiles/gpu.tsv"))
include("tools/profile/gpu.jl")
```

The [browser integration check](tools/browser/check.jl) drives Chromium through its local DevTools connection. It uses a disposable profile and checks actual pixels before and after switching scenes on all three targets. Instantiate `tools/browser`, then add that directory to `LOAD_PATH` and include the check in the repository project. Use `--headed` for a desktop session and `--reports` to open the coverage and profile reports, expand a source listing, and validate the CPU sample file. The [link checker](tools/check_links.jl) checks relative source references and contacts the external documentation and artifact URLs.

## Native integrations

Julia packages supply FreeType, FriBidi, HarfBuzz, GLFW, OpenCV and the Wayland client. On Linux, `WaylandSHM.Presenter(display, shm, surface; max_size)` presents CPU surfaces through Wayland shared memory. On an X11 display, `rasterize(frame; target=:opengl)` can render solid paths, strokes, clips and isolated groups through a first-party GLX/Skia backend. It owns its offscreen context and reads back premultiplied RGBA pixels. On a Linux desktop with Vulkan-enabled GTK 4.14+, `target=:vulkan` selects the native GSK Vulkan renderer. The extended bridge APIs remain available. The chart accepts a host and a renderer independently.

The tutorial rendering report (`reports/tutorials/index.html`) compares each tutorial's Julia drawing on the CPU, native OpenGL, native Vulkan and WebGL2. Run the browser check with `--headed --tutorial-proof --workshops --live-binance` to regenerate the images and exercise the controls. The live chart uses Vellum's `DataDrawing` layer API. Its platform adapters deliver input and market data.

## License

Vellum's code, documentation and tutorials are licensed under the [Apache License, Version 2.0](LICENSE). The [project notice](NOTICE) identifies the copyright holders. Third-party components carry their own terms. The bundled Liberation Sans font uses the [SIL Open Font License 1.1](test/fixtures/LiberationSans-LICENSE.txt).
