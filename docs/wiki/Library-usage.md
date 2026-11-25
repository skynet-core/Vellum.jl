# Drawing and backend execution

## Draw your first frame

```julia
using Vellum
frame = drawing(size=(96, 48)) do edit
    rectangle!(edit, 0, 0, 96, 48; fill=Solid(1, 1, 1))
    with_group(edit; opacity=0.5) do group
        clip(group, rectangle_path(8, 8, 64, 24))
        rectangle!(group, 0, 0, 40, 40; fill=Solid(1, 0, 0))
        rectangle!(group, 24, 0, 40, 40; fill=Solid(1, 0, 0))
    end
end
savepng("drawing.png", frame)
savehtml("drawing.html", frame; target=:compare)
```

The frame stores drawing operations in order. The two opaque rectangles are composed inside an isolated group. The renderer applies the group's opacity once, so the overlap and the single-covered region have the same color. A clip captures its transform when you create it. Coordinates start at the top left and increase right and down. `size=(width, height)` selects the physical pixel extent when rasterizing. Index the returned Julia image by one-based row and column.

## Paths, text and images

Use `PathData` to describe lines and curves, then `draw(edit, path; mode=:fill)` or `mode=:stroke`. A fill can use nonzero or even-odd winding. Set a transform with `configure!`, or scope it inside `with_state`. Shapes use logical coordinates. Rendering to a different physical size scales them with the frame. A provider that advertises `:path_precision_1_256px` promises a maximum precision loss of 1/256 physical pixel per axis when narrowing path coordinates.

Register font bytes as `FontData`, configure the font and logical size, then call `draw_text!` with a baseline position. Capturing a shaped run with `Vellum.capture_text!` retains positioned glyphs and exact font revisions for replay. For images, pass an `Image` or a `Vellum.ImageStorage` provider to `resource!` and pass the returned reference to `draw_image!`. A strided buffer is copied according to its layout. The immutable frame can outlive the source buffer.

Dense image snapshots use premultiplied sRGB RGBA8. With half-opacity red, the red and alpha bytes are both about 128. `Solid` accepts straight, normalized color channels. A backend must advertise support for operations that require a different color space. Nearest sampling selects the source texel. Linear sampling interpolates premultiplied channels and clamps at the source rectangle.

## Own a surface and read its pixels

```julia
renderer = CPUBackend.Renderer()
try
    surface = render(frame; backend=renderer)
    try
        image = readback(surface)
        @assert image[16, 16] == image[16, 32]
    finally
        close(surface)
    end
finally
    close(renderer)
end
```

`prepare` checks frame requirements against backend capabilities and retains resources for execution. `render` prepares the frame and executes it into a fresh surface. The caller owns that surface. `readback` makes a detached CPU image, and `rasterize` combines these steps for a one-shot image. Pass a backend object to use your own provider. Implement `capabilities`, `make_surface`, `execute!` and `readback`. A provider with native handles also implements `close` for its surface. For presentation, keep the pixels on the device and pass completed work to the platform presenter according to its ownership and thread requirements.

## Register a format

For animated GIF and WebP files, use `ImageCodecs.eachframe(io)` to get composited images in display order. Each frame carries a duration in seconds and a disposal rule. The sequence exposes the encoded loop count. The decoder enforces frame and decoded-byte limits across the sequence. The still-image decoding API returns the first frame. WebP encodes losslessly by default. Set an integer quality to encode lossy RGB with lossless alpha. WebP currently assumes sRGB and rejects embedded ICC profiles and EXIF orientation metadata.

```julia
using Vellum
swatch = Image(2, 1)
swatch[1, 1] = rgbx(rgba(255, 32, 0, 128))
bytes = encode_webp(swatch)
@assert decode_webp(bytes).data == swatch.data
lossy = ImageCodecs.encode_image(swatch; format=:webp, quality=85).bytes
@assert decode_webp_dimensions(lossy) == (2, 1)
```

Supply a bounded signature probe to make a codec discoverable by the byte and stream decoding APIs. This example recognizes a six-byte swatch consisting of a two-byte signature followed by one straight-alpha RGBA pixel. Its decoder converts the color to Vellum's premultiplied representation.

```julia
C = ImageCodecs
registry = C.CodecRegistry()
probe = prefix -> prefix == UInt8[0x56, 0x31]
inspect_swatch = (io, limits, cancelled) -> begin
    limits.header_bytes >= 2 || throw(ArgumentError("swatch header exceeds the byte budget"))
    probe(read(io, 2)) || throw(ArgumentError("invalid swatch signature"))
    C.ImageHeader(1, 1, :swatch, :rgba, 8, :straight, :srgb, :declared, 1)
end
decode_swatch = (bytes, header, limits, cancelled) -> begin
    length(bytes) == 6 || throw(ArgumentError("expected one RGBA pixel"))
    image = Image(1, 1)
    image[1, 1] = rgbx(rgba(bytes[3:6]...))
    image
end
C.register_provider!(registry, C.CodecProvider(:example, :swatch, Returns(true),
    inspect_swatch, decode_swatch, nothing; probe, probe_bytes=2))
result = C.decode_image(UInt8[0x56, 0x31, 255, 0, 0, 255]; registry)
try
    @assert result.source.format == :swatch
finally
    close(result)
end
```

### Browser line quality

Vellum keeps drawing and hit testing in logical coordinates. The browser renderer uses a denser backing image for curves, strokes, glyph masks and translucent groups. For a 640 × 374 scene on a 2× display, the backing canvas is 2560 × 1496, which the browser composites into 1280 × 748 display pixels. Moving the window to a display with a different density refreshes the scene. Extra sampling stops at 8 megapixels or 8192 pixels per side, preserving at least the native display density. This costs up to four times as many backing pixels as rendering at native density alone.

Build the sound panel step by step in the [Liquid Glass framework lesson](../../tutorials/liquid_glass.jl) or [interactive Julia notebook](../../tutorials/liquid_glass.ipynb). The same controls handle keyboard, mouse and touch input on the browser canvas. Native windows reuse the Julia reducer and drawing.
