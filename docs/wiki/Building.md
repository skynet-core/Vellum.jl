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

The CPU renderer can run in a headless process with its dependencies installed. Browser export also needs the PixiJS artifact. Generate one gallery while online to provision it. The exported HTML embeds its renderer, scene data and WebAssembly. Open the file in a browser with the graphics APIs you want to exercise.

Desktop window integration requires an accessible display and the appropriate OS driver. The Linux Wayland shared-memory presenter borrows a host surface. The chart workshop can open either a Wayland or an X11 window. Offscreen desktop OpenGL on X11 uses a first-party GLX/Skia provider for solid paths, strokes, clips and isolated groups. The extended bridge profiles require compatible bridges. See the [usage guide](Library-usage.md) and [testing guide](Testing.md).

To build the tutorial and API reference locally, instantiate the `docs` project, then run `julia --project=docs docs/make.jl` from the checkout root. The documentation build uses Literate.jl and Documenter.jl. Open `docs/build/route.html` to read the rendered tutorial.

The Linux desktop Vulkan provider requires GTK 4.14 or newer built with Vulkan support, a usable display and a Vulkan driver. The provider selects the display device with `device=:auto`. It loads GTK on the first Vulkan request. The explicit bridge constructor remains available for the extended native profiles.

## GitHub Actions

Pushes, pull requests and manual runs build, precompile and test Vellum on Linux and FreeBSD on amd64 and aarch64. The Linux jobs use GitHub's Ubuntu runners. The FreeBSD jobs boot a FreeBSD 14.4 guest, verify the CPU architecture reported by Julia and run the same `tools/ci.jl` entry point in that guest.

CI installs Julia 1.13.4. Its official FreeBSD release archive covers amd64. On FreeBSD aarch64 the job builds Julia from its checksum-verified full source archive. A cold source build under emulation can exhaust the hosted job time limit. To reuse a prepared toolchain, set the repository variables `FREEBSD_AARCH64_JULIA_URL` and `FREEBSD_AARCH64_JULIA_SHA256` to a trusted tar archive with a single top-level directory containing `bin/julia`, and its SHA-256. FreeBSD amd64 uses the Wasmtime binary from Wasmtime_jll. The FreeBSD aarch64 guest builds the matching Wasmtime C library and test runner and installs OpenCV 4 from FreeBSD packages.

Runner and toolchain details are maintained in the [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [FreeBSD VM action](https://github.com/vmactions/freebsd-vm), [Julia downloads](https://julialang.org/downloads/manual-downloads/) and [FreeBSD Julia port](https://github.com/freebsd/freebsd-ports/blob/main/lang/julia/Makefile).
