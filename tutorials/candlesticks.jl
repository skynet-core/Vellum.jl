# # Watch live BTC/USDT candlesticks
#
# Open a rolling chart of the last 48 one-minute candles from Binance Spot.
# Hover over a bar to inspect its UTC time, open, high, low, close and traded
# volume in BTC. Keep the pointer over the newest candle and watch the values
# and its body change as trades arrive. No account or API key is needed.
using Vellum
include(joinpath(pkgdir(Vellum),"tutorials","binance","BinanceChart.jl"))
using .BinanceChart

# ## 1. Select the public market
#
# BTC is the base asset and USDT is the quote asset. Prices are USDT per BTC.
# The REST kline endpoint supplies the recent history. The browser also opens
# the symbol's one-minute WebSocket kline stream. Binance normally publishes
# updates for this interval every two seconds. Try ETHUSDT for another pair.
# [Market-data endpoints](https://github.com/binance/binance-spot-api-docs/blob/master/faqs/market_data_only.md)
# and [kline stream fields](https://github.com/binance/binance-spot-api-docs/blob/master/web-socket-streams.md#klinecandlestick-streams-for-utc).
symbol = "BTCUSDT"
urls = BinanceChart.endpoints(symbol)

# ## 2. Update a candle in place
#
# Binance identifies a candle by its opening timestamp. A stream packet's
# k.o, k.h, k.l and k.c contain OHLC prices, k.v is cumulative volume and
# k.x tells us when the bar closes. Replace the bar with that timestamp.
# A new timestamp appends a bar; the oldest falls out of the window. Trade
# counts prevent a delayed history response from replacing a newer update.
# The browser reconnects after a disconnect and polls REST while waiting.
# If Binance is unreachable, the status reports the error and retries.
#
# A native Julia session can inspect a snapshot directly by evaluating
# `last(BinanceChart.history(urls.history))`.
urls.stream

# ## 3. Map market prices into a drawing
#
# Open chart_view in tutorials/binance/BinanceChart.jl. Its candle layer calls
# rectangle! three times per row for the wick, body and volume bar. Each call
# uses the same price-to-height conversion. The other layers draw the labels,
# toolbar, last price and cursor. A native host materializes the view as an
# ordinary Vellum frame. Browser export compiles those layer expressions to
# Wasm and binds the selected renderer.
view = BinanceChart.chart_view()
sample = [(time=1_700_000_000_000,open=100.0,high=110.0,low=98.0,price=108.0,volume=12.0,trades=4,closed=true)]
sample_model = BinanceChart.chart_model(symbol,sample,"Example candle")
sample_frame = drawing(view,sample_model)
@assert rasterize(sample_frame)[200,318] == rgbx(38,166,154,255)

# ## 4. Open the live view
#
# Run the next cell in Jupyter or VS Code to embed the interactive chart.
# In a script, open the generated candlesticks.html. Move the mouse without
# clicking, tap a bar on a touch screen, or focus the chart and use the arrow
# keys. Escape dismisses the tooltip. Switch among 1m, 5m, 15m and 1h, drag
# back through 240 bars, scroll or press + / − to zoom, and press Latest
# to follow the market again. The status identifies the active feed.
#
# Set host to :wayland or :x11 to open the native window on Linux. Those hosts
# poll Binance every three seconds, upload Vellum pixels to the window and
# show the same hover fields. Close the window or press Escape to return.
# All hosts need internet access to Binance for current prices.
host = Symbol(get(ENV,"VELLUM_TUTORIAL_HOST","browser"))
renderer = Symbol(get(ENV,"VELLUM_TUTORIAL_RENDERER",host===:browser ? "webgl2" : "cpu"))
BinanceChart.launch(symbol;view,host,renderer)

#md # ```@raw html
#md # <p><a href="apps/candlesticks.html">Open the live Binance chart</a></p>
#md # ```
