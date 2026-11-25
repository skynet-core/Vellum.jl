# Testing and coverage

From a Julia session at the checkout root, run the suite in its package test environment.

```julia
using Pkg
Pkg.activate(".")
Pkg.test()
```

The headless suite exercises rendering, codecs, resource ownership and browser export. On a Linux desktop with X11 and Wayland available, set `ENV["VELLUM_TEST_GLFW"] = "true"` and `ENV["VELLUM_TEST_WAYLAND"] = "required"` before `Pkg.test()` to require live window checks. An ordinary headless pass establishes the behavior exercised on that run. Look at the platform settings before using a pass as evidence for a display integration.

The browser check traces Canvas path fills, WebGL2 instanced draws and WebGPU render-pass draws back to a Wasm call. It also replays a retained scene and checks that WebGL2 reuses its vertex buffers. To inspect the rendered pixels on all three backends, start a fresh Julia process in the checkout and run the following with Chromium installed. Set `ENV["VELLUM_BROWSER"]` to the browser executable when it differs from `google-chrome`. Add `"--headed"` to `ARGS` for a desktop session.

```julia
using Pkg
Pkg.activate("tools/browser")
Pkg.instantiate()
Pkg.activate(".")
push!(LOAD_PATH, abspath("tools/browser"))
include("tools/browser/check.jl")
```

Run `julia --project=. tools/ci.jl --headless` to install Vellum in an empty consumer project and verify the headless dependency graph, image-to-image rendering and Wasm export.

Run `julia --project=. tools/ci.jl --desktop` on Linux with GTK 4.14+, X11 and Wayland available. It installs Vellum, shaping and native OpenGL dependencies in a fresh consumer project, unsets both bridge overrides and tests OpenGL and Vulkan on each display system. The host submits retained edits, changes the window size with a redraw pending, closes each renderer and checks that it still owns its window and GL context. X11 checks compare actual window pixels with the CPU rasterizer. Wayland checks use compositor frame feedback.

The desktop image check draws a dense patch and two adjacent source tiles. It changes just one tile, verifies the transferred byte count, and compares the interpolated seam and fractional crop with the CPU image. A provider throws during its second page read. The test verifies that the committed pixels and textures survive, then retries. OpenGL also exercises fence polling, cancellation and close with a draw pending. The Vulkan check inspects the native type of each resident texture on the test driver.

The browser check switches scenes and reads displayed pixels through a disposable local browser profile. To reproduce the contract scene on CPU, load Vellum, include `test/fixtures/drawing_contract.jl`, and call `savepng("contract.png", drawing_contract_frame())`. Its expected pixels use zero-based `(x, y)`. The Julia image index is `image[y+1, x+1]`.

To generate unit-only line coverage, run `julia --project=tools/coverage tools/coverage.jl` from the root. Open `reports/coverage.html`, expand a source file and inspect the code beside its execution count, or load `reports/coverage.info` in an LCOV-compatible editor. The runner includes shipped extensions and writes reports before enforcing the 95% unit minimum. Use `--integration` for a separate combined report that requires Linux X11, real OpenGL and Wayland. Run the browser check with `--workshops` to send pointer and keyboard input to the offline workshops. Add `--live-binance` for a networked check of the 48-bar snapshot, incoming updates and live hover tooltip. The browser suite also checks the interior holes of B, 8, O, D and 0 across all three renderers.

To compare font rasterization, instantiate the `tools/text` project and run `julia --project=tools/text tools/text/compare.jl`. Open `reports/fonts.html` and inspect the masks at their original size as well as the enlarged differences. This diagnostic supplies the same captured glyph IDs and positions to Vellum, Cairo and Skia using the bundled Liberation Sans face. It records raster differences for three cases. Independent shaping validation and qualification of additional scripts are still open.

## Tutorial acceptance

To check the published Julia scripts, Markdown and IJulia notebooks, install Jupyter's `nbclient` runtime (CI uses version 0.11.0). Run these commands from the checkout root. Set `JUPYTER_EXECUTE` to the path of `jupyter-execute` if you installed it in a separate environment.

```sh
julia --startup-file=no --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=docs docs/check_notebooks.jl
```

The check regenerates the Markdown and notebook cells in a temporary directory. It runs each published script in a clean drawing project and each notebook in a fresh Julia kernel, then compares the saved files and the inline display byte for byte. The route lesson produces a PNG. The other seven produce standalone HTML and Wasm. A ninth kernel moves the route and checks the pixels at both station positions and in the unchanged park. The check creates a temporary kernel specification and removes it on exit.

To check the playground copies, instantiate the checkout and `public/playground` projects, then run `julia --project=. public/playground/build_lessons.jl --check`. It runs the editor source for every lesson on Canvas 2D, WebGL2 and WebGPU and compares all 24 exports with the published files.

The Linux x86-64 CI job opens a fresh Chromium profile and blocks remote requests before loading the export. It inspects the compiled WebAssembly module's imports and checks that the page embeds its scripts. For both a retained scene and a changing data model, it observes a Wasm caller on the stack of the Canvas fill, WebGL2 instanced draw and WebGPU render-pass draw, then reads the displayed pixels. The separate live Binance check enables network access for market data.

Every tutorial must have one Julia drawing definition. A host adapter can deliver data and input. Vellum owns the drawing, Wasm compilation and graphics presentation. A tutorial is accepted after its scene has rendered through CPU, desktop OpenGL, native Vulkan and browser WebGL2. Retained-scene checks edit and remove a node, check the surviving pixels and revisit a previously displayed revision. Fix renderer defects in the library and add a regression there. The surface plot uses Vellum's CPU depth renderer for its mesh and the selected backend for the composed frame.

Instantiate and activate `environments/desktop` with the browser test environment on `LOAD_PATH` for the native comparison. Pass `--headed --tutorial-proof --workshops --live-binance` to the browser check to regenerate `reports/tutorials/index.html`, exercise the interactive controls and verify the Binance feed. The report uses pinned prices for like-for-like comparisons. The live check separately requires a change in the newest candle's trade count or timestamp.

The touch-controls check removes every accessibility descendant from the mounted canvas, compares screenshots before and after removal, then clicks the switch and drags the slider with browser pointer events. The glass toolbar check compares hover, held, activated and keyboard-focused frames on each renderer and exercises touch cancellation and reduced motion. Reload the page after inspecting fallback nodes in DevTools to restore their accessibility semantics.

Pass `--smoothing` to measure WebGL2 coverage of an oblique edge at 1× and 2× display density. The test compares composited screenshot pixels with the area of the pixel on either side of the line, and changes display density while the scene is open. With `VELLUM_EDGE_BASELINE` set to an earlier export of `slope_scene()` and `VELLUM_GLASS_BASELINE` set to an earlier WebGL2 glass tutorial, the check also writes a side-by-side map, matched crops and measurements to `reports/smoothing/index.html`. Generate the current `tutorials/output/glass-controls.html` before comparing two builds.

On a Linux desktop with both display protocols available, run `julia --project=environments/desktop tools/check_glass_windows.jl` to present the glass tutorial in Wayland and X11 windows using desktop OpenGL and Vulkan. The check reads the presented frame at the window's framebuffer dimensions.

The shadow check measures RGB darkening beneath the glass toolbar over sand and over water at four distances, using an unobstructed map for comparison. Set `VELLUM_SHADOW_BASELINE` to an older glass-controls WebGL2 export to generate matching before-and-after crops in `reports/shadow/index.html`. Use `VELLUM_GLASS_COMPARISON` to pin the second map for a line-smoothing comparison when the tutorial design has since changed.
