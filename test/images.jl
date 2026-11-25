
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
            for (fmt, ext) in ((PngFormat,"png"),(QoiFormat,"qoi"),(BmpFormat,"bmp"),(PpmFormat,"ppm"))
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
        @test_throws ArgumentError encode_webp(im)
    end
end
