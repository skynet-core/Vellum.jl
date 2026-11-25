
function test_text()
    @testset "Shaping, layout, and captured outlines" begin
        font = read_font(fontfile)
        @test has_glyph(font.typeface,UInt32('A'))
        @test get_advance(font.typeface,UInt32('A')) > 0
        for str in ("Hello", "A\u0301", "abc אבג", "office")
            p = new_paragraph(str,font)
            layout = layout_paragraph(p)
            @test paragraph_metrics(layout).width > 0
            im = new_image(128,48)
            fill_paragraph!(im, layout, 2, 2)
            @test any(p -> p.a > 0, im)
        end
        f = drawing(size=(80,32)) do edit
            ref = resource!(edit,:font,FontData("Liberation Sans",read(fontfile)))
            configure!(edit;font=ref,font_size=16)
            draw_text!(edit,"Hello",(2,20))
        end
        @test count(p -> p.a > 0,rasterize(f)) > 100
        @test rasterize(Wire.decode_snapshot(Wire.encode_snapshot(f)).frame).data == rasterize(f).data
    end
end

function test_hinting()
    @testset "Captured glyph groups and reusable hinting sessions" begin
        frame = drawing(size=(100,40)) do e
            ref = resource!(e,:font,FontData("Liberation Sans",read(fontfile)))
            configure!(e;font=ref,font_size=15)
            Vellum.capture_text!(e,"Hello",(3,25);features=((:liga,1),))
        end
        @test !isempty(frame.nodes)
        @test rasterize(Wire.fork_canvas(Wire.decode_snapshot(Wire.encode_snapshot(frame))) |> snapshot).data == rasterize(frame).data
        if Sys.islinux() && Sys.ARCH === :x86_64
            for mode in (:normal,:light,:unhinted)
                hinting = TextHinting(;mode)
                hinted = hinted_frame(frame;size=(200,80),hinting)
                im = rasterize(hinted;size=(200,80))
                @test any(p->p.a>0, im)
                @test rasterize(frame;size=(200,80),hinting).data == im.data
                @test_throws ArgumentError hinted_frame(frame;size=(0,0),hinting)
            end
        end
        @test_throws ArgumentError TextHinting(mode=:invalid)
    end
end
