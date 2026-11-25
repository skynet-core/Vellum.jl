# Vellum guides

These guides accompany the 0.1 development checkout. Start with a CPU image, then use the same drawing to explore portable frames, browser export and backend execution.

The [API reference](API-reference.md) explains how to browse the searchable reference and look up a definition in the Julia REPL or editor.

Run the lessons in a browser with the [interactive playground and container deployment guide](https://github.com/skynet-core/Vellum.jl/blob/main/public/playground/readme.md).

The [route tutorial](../../tutorials/route.jl) runs as a Julia script. Open the [interactive notebook](../../tutorials/route.ipynb) in Jupyter with a Julia kernel to edit the route and inspect the drawing inline.

| Interactive workshop | Julia script | Jupyter notebook |
| --- | --- | --- |
| Hover live Binance BTC/USDT candles, then switch the chart to a Wayland or X11 window | [Script](../../tutorials/candlesticks.jl) | [Notebook](../../tutorials/candlesticks.ipynb) |
| Orbit a depth-tested surface with captured font labels | [Script](../../tutorials/surface_plot.jl) | [Notebook](../../tutorials/surface_plot.ipynb) |
| Build a touch-controlled reading light with switch, slider and segmented selector | [Script](../../tutorials/touch_controls.jl) | [Notebook](../../tutorials/touch_controls.ipynb) |
| Build a Liquid Glass framework and a sound panel | [Script](../../tutorials/liquid_glass.jl) | [Notebook](../../tutorials/liquid_glass.ipynb) |
| Build a retained dashboard with gradient meters and linked trend lines | [Script](../../tutorials/signal_desk.jl) | [Notebook](../../tutorials/signal_desk.ipynb) |
| Animate and scrub a translucent market panel | [Script](../../tutorials/glass_market.jl) | [Notebook](../../tutorials/glass_market.ipynb) |
| Build a glass toolbar with hover, press, cancellation and keyboard focus | [Script](../../tutorials/glass_controls.jl) | [Notebook](../../tutorials/glass_controls.ipynb) |

Each workshop writes a standalone HTML application and its Wasm module in the working directory. The plot and reading light run offline. The chart needs network access for Binance market data. In a checkout, use `julia --project=. tutorials/candlesticks.jl` to start with the chart.

| Guide | What you can do |
| --- | --- |
| [Building](Building.md) | Instantiate a checkout and verify an offline, headless render. |
| [Testing](Testing.md) | Run unit tests, exercise native and browser integrations, and inspect missed lines. |
| [Profiling](Profiling.md) | Measure allocations, inspect CPU stacks and read the GPU timing report. |
| [Library usage](Library-usage.md) | Draw a frame, work with images and text, and manage a render surface. |

The Vellum guides and tutorials are distributed under the [Apache License, Version 2.0](https://github.com/skynet-core/Vellum.jl/blob/main/LICENSE).
