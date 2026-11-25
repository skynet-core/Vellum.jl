# Vellum engineering backlog

**Start with the portable frame contract, unit coverage and the method inventory.** These can proceed together. The next Vulkan milestones are bounded streaming for large image sources and native 3D depth and picking.

| When | Work to pick up |
| --- | --- |
| Now | Pin the [frame fixtures](#compatibility-fixtures). Add deterministic [failure tests](#unit-coverage). Inventory [timings](#cpu-and-gpu-measurements) and [docstrings](#reference-and-ide-help) from the same source definitions. |
| Once the fixtures pass | Expand [GPU submission](#device-submission-and-residency), run [Cairo and Skia comparisons](#cairo-and-skia-comparisons) and qualify [image codecs](#image-codecs). Extract a consumer only after its replacement passes the fixtures. |
| As platforms become available | Qualify one [desktop, web](#desktop-and-web) or [mobile](#mobile-and-support-matrix) configuration at a time. Decide on Direct3D, AVIF and HDR at their decision points below. |
| Every release | Publish same-revision coverage, profiles, [tutorial proofs](#interactive-tutorials) and [platform results](#release-evidence-and-wiki). |

## Starting point · 25 November 2026

| Area | Verified baseline |
| --- | --- |
| Unit coverage | Julia 1.10.13 covered **13,989 of 21,027 executable lines (66.53%)** at `564c72f`. At this size, another **5,987** covered lines would reach the 95% release gate. [Coverage runner](tools/coverage.jl) |
| Method timings | At the same revision, Julia 1.13.4 directly timed **102 of 4,145 loaded CPU methods**. An RTX 3090 ran checked timings for 13 Vulkan and 70 CUDA workloads. Desktop OpenGL/Vulkan and browser WebGL2/WebGPU also have frame-level GPU timers. Canvas 2D exposes host timings. [Profiling guide](docs/wiki/Profiling.md) |
| Desktop graphics | The owned Vulkan queue presents to X11 and Wayland. Two isolated Weston/Mesa compositor captures matched the CPU reference exactly. The queue now renders all eight tutorials' initial scenes on an RTX 3090 within two channel values of the CPU reference. The surface-plot mesh and glass texture preparation still run on the CPU. [Window tests](test/vulkan_window.jl) · [Tutorial comparison](tools/browser/tutorials.jl) |
| Tutorials | At `564c72f`, the local browser suite passed **285/285** checks, including live Binance updates, tutorial rendering and the visual reports. All eight Julia/notebook pairs and 24 playground previews passed on hosted Linux amd64 at `06f6b4d`. [Browser suite](tools/browser/check.jl) · [Notebook checks](docs/check_notebooks.jl) |
| Hosted builds | Both Linux builds and FreeBSD amd64 passed at `06f6b4d`. At `564c72f`, FreeBSD amd64 passed. The Linux window artifact checks and FreeBSD ARM qualification have their own jobs. [Previous matrix](https://github.com/skynet-core/Vellum.jl/actions/runs/45683255194) · [Window commit matrix](https://github.com/skynet-core/Vellum.jl/actions/runs/45686578998) |

## Epic 1 · Portable drawing API

### Frame semantics

- [ ] Specify coordinates, transforms, clips, fill rules, isolated group opacity, premultiplied alpha, color conversion, image sampling and glyph positions for `Context`, `Canvas` and immutable frames. Preserve immediate pixel access on `Context`.
- [ ] Move remaining device discovery and selection into providers. Document ownership of borrowed windows, device-resident results and readback copies.
- [ ] Define device-space error bounds beyond paths. Test transformed geometry on devices with narrower precision, strict-mode errors and opt-in raster fallback within its byte budget.

### Compatibility fixtures

- [ ] Snapshot exported bindings, private method signatures and shipped sources before package extraction. Compare each migration against the snapshot.
- [ ] Replay one corpus in fresh CPU, desktop and browser installations at multiple scales. Compare clipped curves, translucent groups, strided images, shaped glyphs, antialiased edges and resource lifetimes. [Shared fixture](test/fixtures/drawing_contract.jl)

## Epic 2 · First-party desktop graphics

### Device submission and residency

- [ ] Qualify workshop-sized draws on additional GPU drivers and record device timings for the separate filter and upload passes. Include atlas growth, nested blur and the tutorial’s real input state changes. [Queue entry point](src/opengl/vulkan_queue.jl)
- [ ] Supersede obsolete streaming requests. Bound active pages and staging memory for flat and layered sources. Test resident-only, combined and split transfers, inactive page reuse and counters after a partial upload. [Streaming adapter](src/opengl/vulkan_source_stream.jl)
- [ ] Qualify remaining capability queries, cache budgets, diagnostics and teardown against the 74-symbol bridge inventory. Run both providers in a fresh project with bridge overrides unset. [Desktop checks](tools/ci.jl)
- [ ] Port indexed 3D geometry, overlays, depth and picking to the first-party Vulkan API. Match color, depth and picked object IDs against the CPU reference before extracting the 3D consumer. [Current adapter](src/scene3d/vulkan.jl)

### Window presentation and recovery

- [ ] **Vulkan recovery.** Inject timeout, failed submission, out-of-date swapchain, surface loss and device loss. Verify that the last completed frame survives where applicable and that callers can release and reopen resources.
- [ ] **Borrowed OpenGL windows.** Support arbitrary EGL drawables alongside GLX and GDK. Check thread ownership, restoration of host GL state and framebuffer cleanup during resize and failure.
- [ ] **Display qualification.** Extend compositor pixel checks to OpenGL on Wayland and to additional drivers. Cover fractional display scaling, unavailable devices and partial startup on both window systems. Record physical GPU timings separately from software-driver results.

## Epic 3 · Text quality

### Font selection and shaping

- [ ] Qualify fallback faces, bidirectional text and hinting on each claimed platform ABI. Verify grayscale antialiasing across surfaces and LCD rendering on opaque surfaces with known display geometry.
- [ ] Pin redistributable fonts and Pango/HarfBuzz reference runs. Match faces, variations, language, features, direction, glyph order and normalized clusters. Calibrate the proposed 1/64 px tolerance for unhinted advances and offsets.

### Cairo and Skia comparisons

- [ ] Extend the three single-face raster cases to kerning, ligatures, combining marks, mixed Arabic/Hebrew and Latin, Devanagari, CJK fallback, missing glyphs, and supported variable and color fonts. [Current comparison](tools/text/compare.jl)
- [ ] Draw identical positioned glyphs at 9–16 px, fractional origins, high DPI, rotation and on transparent surfaces. Freeze per-mode tolerances that catch lost strokes, clipped descenders, displaced accents and broken joins on each claimed renderer.
- [ ] Publish actual-size samples, enlarged differences, ink bounds and per-glyph alpha/color errors for both references. Explain reference disagreements and regenerate hashed fixtures offline from Julia.

## Epic 4 · Formats and package boundaries

### Image codecs

- [ ] Finish capability reporting for inspection, reading, writing, sequences, pages, tiles and bit depth. Exercise a third-party codec through bounded auto-detection, path/IO access, first-frame reads and whole-decode limits. [Codec registry](src/formats/codecs.jl)
- [ ] Qualify PNG and JPEG first, then BMP, PPM, QOI, GIF and WebP. Test alpha, ICC, orientation, precision, lossy error, truncation, animation timing, loops and disposal with independent fixtures. Implement ICC and EXIF handling for tagged WebP.
- [ ] Implement bounded multipage TIFF inspection and page access, including pages with different dimensions or metadata. Keep SVG and PDF vector exports in the compatibility suite.
- [ ] **Future decision.** Select AVIF or HDR providers when a consumer supplies a workload and measurable fidelity requirements.

### Consumer migration

- [ ] Extract GLFW hosting, OpenCV, brushes and 3D behind optional entry points. Exercise old and new APIs on a real consumer through a documented migration period. Preserve OpenCV leases, stride, ownership and asynchronous jobs.
- [ ] Move pressure curves, history, selection, paragraph layout, zoom, scheduling, image-pyramid/cache policy, transport, synchronization and gallery controls into consumers. Retain tile access, stable resource IDs, positioned glyphs and interactive replay in core.
- [ ] After each extraction, run `rasterize`, `savepng` and `savehtml` in a fresh project. Verify offline headless rendering after artifact installation. Keep Vellum code, tests and build helpers in Julia, including in-process shader, browser-binding and Wasm generation.

## Epic 5 · Platform support

### Desktop and web

- [ ] **Linux and FreeBSD, amd64 and aarch64.** Qualify headless installation, offscreen GL/Vulkan, X11 and Wayland windows, resize, scale and recovery per architecture. Establish a reproducible FreeBSD ARM Julia/Wasmtime build and check artifact and driver availability.
- [ ] **Web.** Expand browser and device coverage for Canvas 2D, WebGL2 and WebGPU. Verify that Vellum-generated Wasm drives replay through its own browser bindings. Block external rendering libraries, switch scenes, trace native calls and check displayed pixels offline. [Browser suite](tools/browser/check.jl)
- [ ] **Windows.** Implement Win32 presentation and qualify offscreen and windowed OpenGL and Vulkan. Evaluate Direct3D after both pass.
- [ ] **macOS.** Qualify Metal/AppKit, supported desktop OpenGL contexts and Vulkan through a packaged portability implementation. Publish feature limits for each.

### Mobile and support matrix

- [ ] **iOS and Android.** Implement Metal/UIKit and Android native-surface Vulkan, followed by Android GLES. Launch packaged Julia apps on real devices. Exercise backing scale, rotation, background/resume and surface recreation.
- [ ] Publish an OS × architecture × renderer × presenter matrix. Record Julia version, device/driver, installation, pixels, presentation and recovery. Identify mobile builds that execute Julia and those that replay preauthored frames.

## Epic 6 · Coverage and performance

### Unit coverage

The largest unit-test gaps at `564c72f` are the browser device bindings (364 missed lines), OpenGL adapter (346), PDF writer (287) and GLX extension (283). The generated `reports/coverage.html` shows the missed lines in context.

- [ ] Reach **≥95% executable Julia line coverage** across core and maintained providers. Start with device initialization, queue submission and streaming failures, font fallback and codec limits. Inject driver outcomes to reproduce failure paths in unit tests.
- [ ] Merge unit counts by revision, path and line, including unloaded providers and extracted packages. Publish highlighted HTML, editor-readable LCOV and package/combined totals. Report real-driver integration coverage separately. [Coverage tooling](tools/coverage.jl)

### CPU and GPU measurements

- [ ] Inventory every authored public/private method, constructor, closure and extension of an external generic. Map generated wrappers to source. Classify each method as host, device or both, including optional providers.
- [ ] Time each host-callable method after warm-up. Record package, signature, source location, workload, median, p95, allocations and sample count. Batch tiny calls with runtime inputs, consume outputs and measure cold start separately. [CPU runner](tools/profile/cpu.jl)
- [ ] Attribute device work to every applicable method. Separate host submission, GPU execution and readback. Benchmark helpers in checked batches and timestamp production work. Identify inlined helpers, unavailable timers and inapplicable measurements in each row. [GPU runner](tools/profile/gpu.jl) · [Vulkan workloads](tools/profile/vulkan_methods.jl)

## Epic 7 · Documentation and learning

### Reference and IDE help

- [ ] Document **every authored global, type and method signature** across core, providers, tests and tools. Cover constants, constructors, callable types and field invariants. Explain anonymous callbacks at their enclosing definition.
- [ ] Check signature-first docstrings against the inventory. Include units, ownership, mutation and errors where applicable. Reject placeholders and unrelated overloads. Build the Documenter reference, run doctests and compare representative VS Code hovers with Julia help. [Reference build](docs/make.jl)

### Interactive tutorials

Each lesson has one Julia drawing definition. Changing the host or renderer must preserve drawing, hit testing and visible controls. Host adapters may deliver input, market data and accessibility semantics. Learners should only need Vellum APIs to draw.

- [ ] **Live candlesticks.** Exercise Binance reconnects and same-candle updates. Verify time, OHLC, volume, crosshair and hover tooltips on the TradingView-style chart across Wasm, Wayland and X11 using the same Vellum drawing and hit-testing code. [Chart lesson](tutorials/candlesticks.jl)
- [ ] **3D and UI.** Qualify a GPU depth-tested orbiting mesh with shaped labels. Exercise the route, dashboards, touch and Liquid Glass controls with hover, press, drag, keyboard and reduced motion. Explain the state changes and verify blur, cast shadows and antialiased edges in displayed pixels.
- [ ] **Every lesson change.** Generate pure Julia, Markdown and IJulia editions from one Literate source. Run a fresh kernel, change a parameter and compare outputs. Keep every lesson editable and switchable across all three playground previews. [Notebook check](docs/check_notebooks.jl) · [Preview check](public/playground/build_lessons.jl)
- [ ] **Every renderer change.** Capture each lesson on CPU, desktop OpenGL, native Vulkan and browser WebGL2. Route all visible drawing through Vellum. Check edits/removals, unchanged siblings, idle scheduling and native node reuse. Record device identity and CPU intermediates. Fix defects in the library and add regressions. [Renderer proof](tools/browser/tutorials.jl)

## Epic 8 · Release and distribution

### Release evidence and wiki

- [ ] Generate one offline, source-linked report from Julia with HTML coverage, CPU/GPU method tables, VS Code CPU stacks, GPU timelines, text comparisons and machine-readable data. Record revision, fixtures, runtime, driver/device, warm-up, sample size and units.
- [ ] Enforce the coverage, timing, documentation and platform gates on the release revision. Expose missing measurements, check report links offline and investigate repeatable performance regressions on the same hardware.
- [ ] Rehearse the four wiki guides from a clean checkout. Build a headless frame, reproduce a fixture and a missed line, trace a draw to GPU completion, then follow the usage guide from PNG through browser export, borrowed surfaces and custom codecs. [Guide sources](docs/wiki/Home.md)
- [ ] Publish release-matched wiki pages and the API archive. Follow the published README through the guides, scripts, notebooks, figures and source links. [Wiki publisher](docs/stage_wiki.jl) · [Link checker](tools/check_links.jl)

### CI and playground containers

- [ ] Keep the hosted Linux amd64/aarch64 compositor captures and the three-target browser pixel check passing on each release. Both Linux window checks passed at `564c72f`. [Build workflow](.github/workflows/ci.yml)
- [ ] Confirm all four Linux/FreeBSD jobs on one release revision. Pull matching GHCR service and worker images on both Linux architectures, execute an edited Julia lesson and switch preview backends. [Container workflow](.github/workflows/playground.yml) · [Deployment guide](public/playground/readme.md)

The local design rationale and symbol-by-symbol migration notes are in the gitignored `roadmaps/rework-roadmap.md` and `roadmaps/native-bridge-inventory.md`.
