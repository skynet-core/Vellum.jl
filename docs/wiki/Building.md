# Building from a checkout

Open Julia in the root of the Vellum checkout. The project supports Julia 1.10 or later in the 1.x series. Instantiate with a network connection the first time so Julia can install the versioned packages and platform artifacts.

```julia
using Pkg
Pkg.activate(".")
Pkg.instantiate()
using Vellum

frame = drawing(size=(32, 20)) do edit
    rectangle!(edit, 2, 3, 12, 8; fill=Solid(1, 0, 0))
end
image = rasterize(frame)
@assert size(image) == (20, 32)
@assert image[4, 3] == rgbx(255, 0, 0, 255)
savepng("first-frame.png", image)
```

## Select the providers for your application

The root project installs the CPU renderer, PNG and JPEG codecs, font outline handling and the Wasm exporter. From a clean consumer project, `Pkg.develop(path="/path/to/Vellum.jl")` installs the same core. CI draws and reads back a PNG and exports a Wasm scene with the display variables unset, then checks the dependency graph for graphics drivers, window libraries and OpenCV.

The checkout includes a desktop project for the native workshops. From the checkout root run `julia --project=environments/desktop -e 'using Pkg; Pkg.instantiate()'` once, then `julia --project=environments/desktop tutorials/liquid_glass.jl`. The project uses the local Vellum source. The drawing and backend selection APIs work in either project when their providers are installed.

| Feature in your own Julia project | Packages to add with `Pkg.add` |
| --- | --- |
| Shape text with HarfBuzz | `HarfBuzz_jll` |
| Decode and encode WebP, including animated input | `libwebp_jll` |
| Draw to an offscreen desktop OpenGL surface through GLX | `Skia`, `Xorg_libX11_jll` |
| Open a GLFW window or use Wayland shared-memory presentation | `GLFW_jll` for GLFW, `Wayland_jll` for shared memory |
| Process images with OpenCV | `OpenCV_jll`. FreeBSD aarch64 uses OpenCV 4 from ports. |

Browser export embeds Vellum's own Canvas 2D, WebGL2 or WebGPU bindings alongside the Wasm drawing program. The geometry and shaders ship with the export. Open the file in a browser with the graphics APIs you want to exercise.

Desktop window integration requires an accessible display and the appropriate OS driver. The Linux Wayland shared-memory presenter borrows a host surface. The chart workshop can open either a Wayland or an X11 window. Offscreen desktop OpenGL on X11 uses a first-party GLX/Skia provider for solid paths, strokes, clips and isolated groups. The extended bridge profiles require compatible bridges. See the [usage guide](Library-usage.md) and [testing guide](Testing.md).

To build the tutorial and API reference locally, instantiate the `docs` project, then run `julia --project=docs docs/make.jl` from the checkout root. The documentation build uses Literate.jl and Documenter.jl. Open `docs/build/route.html` to read the rendered tutorial.

The Linux desktop Vulkan provider requires GTK 4.14 or newer built with Vulkan support, a usable display and a Vulkan driver. The provider selects the display device with `device=:auto`. It loads GTK on the first Vulkan request. The explicit bridge constructor remains available for the extended native profiles.

## GitHub Actions

Pushes, pull requests and manual runs build, precompile and test Vellum on Linux and FreeBSD on amd64 and aarch64. The Linux jobs use GitHub's Ubuntu runners. The FreeBSD jobs boot a FreeBSD 14.4 guest, verify the CPU architecture reported by Julia and run the same `tools/ci.jl` entry point in that guest.

CI installs Julia 1.13.4. Its official FreeBSD release archive covers amd64. On FreeBSD aarch64 the job builds Julia from its checksum-verified full source archive. A cold source build under emulation can exhaust the hosted job time limit. To reuse a prepared toolchain, set the repository variables `FREEBSD_AARCH64_JULIA_URL` and `FREEBSD_AARCH64_JULIA_SHA256` to a trusted tar archive with a single top-level directory containing `bin/julia`, and its SHA-256. FreeBSD amd64 uses the Wasmtime binary from Wasmtime_jll. The FreeBSD aarch64 guest builds the matching Wasmtime C library and test runner and installs OpenCV 4 from FreeBSD packages.

Runner and toolchain details are maintained in the [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [FreeBSD VM action](https://github.com/vmactions/freebsd-vm), [Julia downloads](https://julialang.org/downloads/manual-downloads/) and [FreeBSD Julia port](https://github.com/freebsd/freebsd-ports/blob/main/lang/julia/Makefile).
