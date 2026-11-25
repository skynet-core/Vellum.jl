# Vellum Playground

Edit a Julia drawing in the left panel and press **Run Julia** or **Ctrl/⌘ + Enter**. The right panel runs Vellum's Canvas 2D or WebGL2 renderer in your browser. Changing the renderer reruns the current source. The status reports the context the browser opened and the physical canvas dimensions. A failed edit displays its Julia error and keeps the last drawing visible.

## Run the tutorials

Choose a lesson above the editor. Every runnable tutorial in the checkout has an editable Julia source and prebuilt Canvas 2D and WebGL2 previews. Selecting a lesson or changing its backend opens the corresponding export. **Run Julia** executes the editor contents in an isolated worker. The Notebook link downloads the Julia notebook for the selected lesson. Switching lessons keeps edits in memory for the current page session. Link directly to a lesson by appending its filename stem to the URL, for example `/#liquid_glass` or `/#candlesticks`.

The Liquid Glass framework lesson implements its button, switch, slider and event handling in the editor. The live chart preview permits connections to the two official Binance market-data hosts. The Julia worker runs offline for every lesson.

## Deploy the published images

From the repository root on a Linux amd64 or arm64 Docker host, pull the matching service and Julia worker, then start the editor. Include the worker in the pull because the broker launches it on demand with `--pull=never`.

```console
export COMPOSE_FILE=public/playground/compose.yaml
docker compose --profile build pull worker-image broker
docker compose up -d --no-build --pull never --wait
```

Open **http://127.0.0.1:8080/**. Use `/#liquid_glass` to open the glass framework tutorial directly. To pin a deployment or roll back, set `VELLUM_IMAGE_TAG=sha-<full Git commit>` in the environment before **both** commands. The default tag is `latest`. If the packages are private, sign in to GHCR with an account that has package read access before pulling.

The [Playground images workflow](../../.github/workflows/playground.yml) builds on native Linux amd64 and arm64 runners. Each starts its Compose stack, serves the bundled lessons, and executes Julia through the web service for both Canvas and WebGL2. After both architectures pass, the workflow creates matching multi-platform tags for `ghcr.io/skynet-core/vellum.jl/playground-service` and `ghcr.io/skynet-core/vellum.jl/playground-worker`. Pushing to `main` or dispatching the workflow on `main` triggers publication. A deployment host pulls these images explicitly.

## Build from source

With Docker Engine and the Compose plugin running, execute these commands from the repository root.

```console
export VELLUM_IMAGE_TAG=local
docker compose -f public/playground/compose.yaml --profile build build worker-image broker
docker compose -f public/playground/compose.yaml up -d --no-build --pull never --wait
```

Open **http://127.0.0.1:8080/**. The initial drawing runs automatically. The first build downloads Julia packages and browser rendering artifacts. Workers use the installed copy of this checkout and render offline. Rebuild both images after changing Vellum, the sample or the playground code.

To inspect or stop the services:

```console
docker compose -f public/playground/compose.yaml logs web broker
docker compose -f public/playground/compose.yaml down
```

Set `VELLUM_PORT` before launch to change the published port. On Linux with a rootless Docker daemon, set `VELLUM_ENGINE_SOCKET` to that daemon's Unix socket. For a shared deployment, use a dedicated engine or VM for the broker and put your HTTPS reverse proxy and access or rate limits in front of the web service. The default listener is loopback. Set `VELLUM_LISTEN` explicitly to bind a different host address. The proxy should preserve the Host header for the editor's origin check.

## Local Julia development

Build the worker image once from the checkout root:

```console
docker build --target runtime -f public/playground/Dockerfile -t vellum-playground-worker:local .
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=public/playground -e 'using Pkg; Pkg.instantiate()'
julia --project=. public/playground/build_lessons.jl
julia --project=. public/playground/server.jl
```

Open the same loopback URL. This development server launches the identical disposable Docker workers. Set `VELLUM_ENGINE=podman` if you build the worker with Podman and use its local engine. Stop the Julia server with Ctrl+C.

## Write a drawing

Return a Vellum `Frame`, `Canvas` or `InteractiveDrawing` as the final expression, or export a single HTML drawing into the working directory. The editor runs ordinary Julia with functions, loops, types and the packages already installed in the worker project. Every run starts a fresh process. The bundled [example](sketch.jl) draws a family of colored paths. Try this smaller example to verify a geometry change:

```julia
using Vellum

drawing(size=(320, 200)) do pen
    rectangle!(pen, 0, 0, 320, 200; fill=Solid(0.08, 0.16, 0.21))
    for i in 1:5
        rectangle!(pen, 24 + 52(i-1), 100-10i, 32, 20i; fill=Solid(0.40, 0.86, 0.72))
    end
end
```

## How a run works

1. The editor sends up to 32 KiB of Julia source and a renderer choice to the web service.
2. The broker starts a new worker from a fixed image. Only the source enters its standard input. The worker has an unprivileged UID, a read-only root filesystem, a 96 MiB temporary filesystem, no network, no host mounts, a one-CPU limit and 1 GiB of memory. The broker bounds output and enforces a 60-second execution deadline. A second request while it is busy receives HTTP 429.
3. In the worker, Julia evaluates the buffer as `sketch.jl` and calls Vellum's `savehtml` on the resulting drawing. The exported page includes its Wasm program and renderer. Julia evaluation happens in the worker. Graphics commands run on the viewer's browser.
4. The web service returns the preview document to an iframe with an opaque origin. The embedded content cannot read the editor. The Compose web service has no engine socket. The separate broker has engine-level authority and accepts only the two fixed rendering endpoints on its internal network.

Drafts live in browser memory for the current page session. The repository includes the editable Julia sources, notebooks, Docker configuration and standalone tutorial previews. The service image regenerates those previews from the Julia lessons when it builds.

## Verify the complete path

With the playground running and Chromium installed, run:

```console
julia --project=. public/playground/check.jl http://127.0.0.1:8080
```

Set `VELLUM_BROWSER` to the Chromium executable if needed. The check edits and executes real Julia, compares red and blue pixels from browser screenshots, switches WebGL2 to Canvas 2D, and confirms an invalid edit leaves the last valid preview visible.
