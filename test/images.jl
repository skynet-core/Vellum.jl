
function test_images()
    @testset "Pixels, compositing, and transforms" begin
        im = new_image(5, 3)
        @test size(im) == (3, 5)
        @test axes(im) == (1:3, 1:5)
        @test all(p -> p == rgbx(0, 0, 0, 0), im)
        @test_throws ArgumentError Image(0, 1)
        @test_throws ArgumentError Image(2, 1, zeros(UInt8, 7))
        @test_throws ArgumentError Image(typemax(Int), 2)
        @test_throws BoundsError im[0]
        @test_throws BoundsError im[4, 1]
        for (i, a) in enumerate(UInt8[0, 1, 63, 128, 255])
            c = rgba(255, 0, 0, a)
            set_color!(im, i, 2, c)
            @test im[2, i] == im[i+5] == rgbx(a, 0, 0, a)
            @test rgbx(to_straight_alpha(im[i+5])) == im[i+5]
        end
        for transform! in (flip_horizontal!, flip_vertical!)
            d = copy(im)
            transform!(d)
            transform!(d)
            @test d.data == im.data
        end
        @test rotate_90(rotate_90(rotate_90(rotate_90(im)))).data == im.data
        @test sub_image(super_image(im, -2, -1, 9, 6), 2, 1, 5, 3).data == im.data
        @test minify_by2(magnify_by2(im)).data == im.data
        @test resize(im, 5, 3).data == im.data
        @test diff(im, copy(im))[1] == 0
        @test opaque_bounds(im) == rect(1, 1, 4, 1)
        @test_throws ArgumentError blender(BlendMode(-1))
        @test_throws ArgumentError blender(BlendMode(20))
        for mode in (NormalBlend, DarkenBlend, MultiplyBlend, ColorBurnBlend, LightenBlend,
                     ScreenBlend, ColorDodgeBlend, OverlayBlend, SoftLightBlend, HardLightBlend,
                     DifferenceBlend, ExclusionBlend, HueBlend, SaturationBlend, ColorBlend,
                     LuminosityBlend, MaskBlend, SubtractMaskBlend, ExcludeMaskBlend)
            for a in (0, 80, 255), b in (0, 192, 255)
                result = blender(mode)(rgbx(rgba(39, 171, 70, a)), rgbx(rgba(201, 58, 17, b)))
                @test max(result.r,result.g,result.b) <= result.a
            end
        end
        for op in (blur!, spread!, apply_opacity!)
            d = copy(im)
            op(d, op === apply_opacity! ? 1 : 0)
            @test d.data == im.data
        end
        m = translate(Vec2(3, -2)) * rotate(0.3) * scale(Vec2(2, 4))
        v = inverse(m) * (m * Vec2(4, 9))
        @test v.x ≈ 4 && v.y ≈ 9
    end

    @testset "Gradient masks match separate sampling and compositing" begin
        shapes = ((Vellum.LinearGradientPaint,[Vec2(1,1),Vec2(7,1)]),
                  (Vellum.LinearGradientPaint,[Vec2(1,1),Vec2(1,8)]),
                  (Vellum.LinearGradientPaint,[Vec2(1,1),Vec2(7,8)]),
                  (Vellum.RadialGradientPaint,[Vec2(3,3),Vec2(7,3),Vec2(3,5)]),
                  (Vellum.AngularGradientPaint,[Vec2(2.5,2.5),Vec2(7,3),Vec2(3,5)]))
        path = parse_path("M1 1 L8 2 L6 9 Z")
        mask = Image(10,10)
        fillPath(mask,path,Paint("white"))
        for (kind,handles) in shapes, mode in (NormalBlend,OverwriteBlend,MultiplyBlend), alpha in (1f0,0.4f0)
            paint = new_paint(kind)
            paint.gradientHandlePositions = handles
            paint.gradientStops = [color_stop(rgba(255,0,0,255),0f0),color_stop(rgba(0,0,255,128),1f0)]
            samples = Image(10,10)
            Vellum.fillGradient(samples,paint)
            @test length(unique(collect(samples))) > 2
            cut = copy(mask)
            apply_opacity!(cut,alpha)
            draw(samples,cut;blendMode=MaskBlend)
            expected = Image(10,10)
            fill!(expected,rgba(30,48,60,255))
            actual = copy(expected)
            draw(expected,samples;blendMode=mode)
            paint.opacity,paint.blendMode = alpha,mode
            fillPath(actual,path,paint)
            @test actual.data == expected.data
            @test paint.opacity == alpha
        end
    end

    @testset "Codecs and file dispatch" begin
        C = ImageCodecs
        registry = C.CodecRegistry(C.CodecProvider[])
        calls = Int[]
        probe = prefix -> begin
            push!(calls,length(prefix))
            return prefix == UInt8[0x56,0x31]
        end
        header = (io,limits,cancelled) -> C.ImageHeader(1,1,:sample,:rgba,8,:straight,:srgb,:declared,1)
        decoder = (data,header,limits,cancelled) -> Image(1,1,copy(data[3:6]))
        provider = C.CodecProvider(:example,:sample,Returns(true),header,decoder,nothing;probe,probe_bytes=2)
        C.register_provider!(registry,provider)
        data = UInt8[0x56,0x31,4,3,2,255]
        @test C.inspect_image(data;registry).format == :sample
        decoded = C.decode_image(IOBuffer(data);registry)
        try
            @test decoded.buffer.owner.bytes == data[3:6]
        finally
            close(decoded)
        end
        @test calls == [2,2]
        @test_throws C.CodecError C.detect_format(data;registry,limits=C.CodecLimits(header_bytes=1))
        @test last(calls) == 1
        extra = C.CodecProvider(:another,:conflict,Returns(true),header,decoder,nothing;probe,probe_bytes=2)
        C.register_provider!(registry,extra)
        @test_throws C.CodecError C.detect_format(data;registry)
        @test C.inspect_image(data;registry,format=:sample).format == :sample
        @test_throws C.CodecError C.CodecProvider(:example,:invalid,Returns(true),header,decoder,nothing;probe)
        im = Image(17, 9)
        for y in 1:im.height, x in 1:im.width
            im[y, x] = rgbx(rgba(9x, 23y, x*y, mod(3x+7y, 256)))
        end
        mktempdir() do dir
            for (fmt, ext) in ((PngFormat,"png"),(QoiFormat,"qoi"),(BmpFormat,"bmp"),(PpmFormat,"ppm"),(WebpFormat,"webp"))
                original = copy(im)
                if fmt == PpmFormat
                    original.data[4:4:end] .= 255
                end
                path = joinpath(dir, "roundtrip."*ext)
                write_file!(original, path)
                @test read_image_dimensions(path) == (17, 9)
                @test read_image(path).data == original.data
                bytes = read(path)
                result = ImageCodecs.decode_image(IOBuffer(bytes))
                try
                    @test result.report.encoded_buffer_bytes == length(bytes)
                    @test result.source.format == Symbol(ext)
                    @test result.report.owned_pixel_bytes == length(original.data)
                finally
                    close(result)
                end
                @test_throws ImageCodecs.CodecError ImageCodecs.decode_image(bytes; limits=ImageCodecs.CodecLimits(pixels=1))
            end
            name = joinpath(dir, "output.png")
            @test savepng(name,im) == name
            @test decode_base64("data:image/png;base64,"*encode_base64(im)).data == im.data
            @test_throws ArgumentError decode_base64("====")
            @test_throws ArgumentError write_file!(im,joinpath(dir,"unknown.xyz"))
        end
        opaque = Image(16,16)
        fill!(opaque,rgb(64,64,64))
        jpeg = encode_jpeg(opaque)
        @test decode_jpeg_dimensions(jpeg) == (16,16)
        @test abs(Int(decode_jpeg(jpeg)[1].r)-64) <= 2
        gif = base64decode("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAkQBADs=")
        @test decode_gif_dimensions(gif) == (1,1)
        @test decode_image(gif)[1] == rgbx(0,0,0,255)
        @test isnothing(C.eachframe(gif).loop_count)
        animation = UInt8[codeunits("GIF89a")...,2,0,1,0,0x80,0,0,0,0,0,255,255,255,
                          0x21,0xff,11,codeunits("NETSCAPE2.0")...,3,1,2,0,0]
        for (x,disposal,delay) in ((0,1,3),(1,3,7),(0,2,11),(1,1,13))
            # Each 1x1 subimage contains one white pixel (GIF LZW clear, index 1, end).
            append!(animation,UInt8[0x21,0xf9,4,disposal<<2,delay,0,0,0,
                                    0x2c,x,0,0,0,1,0,1,0,0,2,2,0x4c,0x01,0])
        end
        push!(animation,0x3b)
        sequence = C.eachframe(IOBuffer(animation))
        @test length(sequence) == 4
        @test sequence.loop_count == 2
        @test [f.duration for f in sequence] == [3,7,11,13] .// 100
        @test [f.disposal for f in sequence] == [:keep,:previous,:background,:keep]
        @test [(f.image[1].r,f.image[2].r) for f in sequence] == [(255,0),(255,255),(255,0),(0,255)]
        @test_throws C.CodecError C.eachframe(animation;limits=C.CodecLimits(frames=3))
        @test_throws C.CodecError C.eachframe(animation;limits=C.CodecLimits(decoded_bytes=31))
        @test_throws C.CodecError C.eachframe(jpeg)
        @test_throws C.CodecError C.eachframe(animation;cancelled=Returns(true))
        test_webp(im)
    end
end

"""Verify lossless and lossy still images, bounded RIFF inspection, and independently composited animation frames."""
function test_webp(image)
    C = ImageCodecs
    @testset "WebP still images and composited animation" begin
        p = only(filter(p->p.format===:webp,C.providers()))
        @test p.available && p.decode && p.encode && p.sequence

        lossless = encode_webp(image)
        @test decode_webp(lossless).data == image.data
        @test C.encode_image(image;format=:webp).bytes == lossless
        @test C.inspect_image(lossless).alpha === :straight
        @test C.inspect_image(lossless).orientation == 1
        still = C.eachframe(lossless)
        @test length(still)==1 && still.loop_count===nothing && first(still).disposal===:unspecified
        @test first(still).duration == 0 && first(still).image.data == image.data
        lossy_alpha = encode_webp(image;quality=89)
        @test decode_webp(lossy_alpha).data[4:4:end] == image.data[4:4:end]
        @test_throws C.CodecError encode_webp(image;quality=101)

        # Reference pixels for an opaque 9×7 VP8 image decoded independently in ImageMagick.
        source = base64decode("UklGRj4AAABXRUJQVlA4IDIAAADQAQCdASoJAAcAAMAQJaACdLoB+AADsAD+9L7v/xlT4kL8SF/4yp/7O79O79O7+98AAA==")
        @test decode_webp_dimensions(source)==(9,7)
        @test C.inspect_image(source).alpha===:none
        raster = decode_webp(source)
        reference = [x>6 || (y==7 && x<=4) ? rgbx(48,105,193,255) : rgbx(48,104,195,255)
                     for y in 1:7, x in 1:9]
        @test all(raster[y,x] == reference[y,x] for y in 1:7, x in 1:9)
        output = decode_webp(encode_webp(decode_webp(source);quality=90))
        @test maximum(abs.(Int.(output.data).-Int.(decode_webp(source).data)))<=4
        # The header reader can stop before compressed data arrives.
        io = IOBuffer(source[1:30])
        @test C.inspect_image(io;format=:webp,limits=C.CodecLimits(header_bytes=30)).width==9
        @test isopen(io) && position(io)==30

        # webpmux assembled three independent lossless images. ImageMagick's
        # coalesced RGBA reference rounds the half-alpha green overlap to (127,128,0).
        anim = base64decode("UklGRrQAAABXRUJQVlA4WAoAAAASAAAAAwAAAQAAQU5JTQYAAAAAAAAAAwBBTk1GKAAAAAAAAAAAAAMAAAEAABMAAAJWUDhMDwAAAC8DQAAABxD9j/4HIqL/AQBBTk1GKAAAAAEAAAAAAAEAAAEAACUAAAFWUDhMDwAAAC8BQAAQB9D/iAIGIqL/AQBBTk1GKAAAAAAAAAAAAAAAAAEAACoAAAJWUDhMDwAAAC8AQAAABxDR//4HIqL/AQA=")
        seq = C.eachframe(IOBuffer(anim))
        @test length(seq)==3 && seq.loop_count==3
        @test [f.duration for f in seq] == [19,37,42] .// 1000
        @test [f.disposal for f in seq] == [:keep,:background,:keep]
        red,blue,clear = rgbx(255,0,0,255),rgbx(0,0,255,255),rgbx(0,0,0,0)
        a,b,c = (f.image for f in seq)
        @test all(==(red),a)
        @test decode_image(anim).data == a.data
        decoded = C.decode_image(anim)
        try
            @test decoded.buffer.owner.bytes == a.data
            @test :first_frame in decoded.report.conversions
        finally
            close(decoded)
        end
        for y in 1:2
            @test all(x->b[y,x]==red,1:2)
            pixel = b[y,3]
            @test pixel==b[y,4] && pixel.b==0 && pixel.a==255
            @test abs(Int(pixel.r)-127)<=1 && abs(Int(pixel.g)-128)<=1
            @test [c[y,x] for x in 1:4] == [blue,red,clear,clear]
        end
        c[1] = clear
        @test a[1] == b[1] == red
        @test_throws C.CodecError C.eachframe(anim;limits=C.CodecLimits(frames=2))
        @test_throws C.CodecError C.eachframe(anim;limits=C.CodecLimits(decoded_bytes=95))
        @test_throws C.CodecError C.decode_image(source;limits=C.CodecLimits(encoded_bytes=length(source)-1))
        @test_throws C.CodecError C.inspect_image(source;limits=C.CodecLimits(header_bytes=29))
        @test_throws C.CodecError C.eachframe(anim;cancelled=Returns(true))
        for data in (anim[1:end-1],vcat(source,0x00),source[1:20])
            @test_throws C.CodecError C.decode_image(data)
        end
        flagged = copy(anim)
        flagged[21] |= 0x20
        @test_throws C.CodecError C.inspect_image(flagged)
        wrong_type = copy(source)
        wrong_type[13:16] .= codeunits("JUNK")
        @test_throws C.CodecError C.inspect_image(wrong_type)
        extra_metadata = vcat(source,codeunits("EXIF"),zeros(UInt8,4))
        extra_metadata[5:8] .= reinterpret(UInt8,[htol(UInt32(length(extra_metadata)-8))])
        @test_throws C.CodecError C.decode_image(extra_metadata)
    end
end
