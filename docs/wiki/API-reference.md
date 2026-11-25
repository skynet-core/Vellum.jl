# API reference

From the checkout root, run `julia --project=docs -e 'using Pkg; Pkg.instantiate()'`, followed by `julia --project=docs docs/make.jl`. Open `docs/build/index.html` and use the sidebar or search box to find a documented definition. Each reference page corresponds to one Julia source file. The three advanced workshop pages link to working interactive applications.

For the same docstrings in Julia, enter help mode with `?` and type `Vellum.rasterize`. In a Julia-enabled VS Code workspace, hover over the function name at a call site. Use a qualified name to look up an internal helper, for example `Vellum.OpenGLBackend.glx_extension`.
