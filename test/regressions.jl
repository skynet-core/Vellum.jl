function test_regressions()
    @testset "Color burn and dodge endpoints" begin
        for mode in (ColorBurnBlend,ColorDodgeBlend)
            blend = blender(mode)
            @test all(Iterators.product(0:255,0:255)) do (b,s)
                value = if mode == ColorBurnBlend
                    b == 255 ? 255 : s == 0 ? 0 : 255-min(255,255*(255-b)÷s)
                else
                    b == 0 ? 0 : s == 255 ? 255 : min(255,255*b÷(255-s))
                end
                blend(rgbx(b,b,b,255),rgbx(s,s,s,255)) == rgbx(value,value,value,255)
            end
        end
        @test blender(ColorBurnBlend)(rgbx(136,17,96,212),rgbx(23,45,38,45)).g == 24
    end
    @testset "Failed implicit layers discard their images and restore state" begin
        for clipped in (false,true), alpha in (1f0,0.5f0)
            ctx = Context(6,6)
            clipped && clip(ctx,parse_path("M0 0H3V6H0Z"))
            ctx.globalAlpha = alpha
            ctx.fillStyle = ctx.strokeStyle = "invalid paint"
            for action in (()->fillRect(ctx,0,0,6,6),()->strokeRect(ctx,0,0,6,6),
                           ()->fillText(ctx,"x",1,1),()->strokeText(ctx,"x",1,1))
                @test_throws ArgumentError action()
                @test isnothing(ctx.layer) && isempty(ctx.stateStack)
                @test all(iszero,ctx.image.data)
            end
            ctx.fillStyle = "red"
            fillRect(ctx,0,0,6,6)
            @test ctx.image[1,1].a in (127,128,255)
            @test !clipped || ctx.image[1,6].a == 0
        end
    end
    @testset "Clearing honors the recorded clip and transform" begin
        ctx, rec = Context(8,6),PictureRecorder(8,6)
        for painter in (ctx,rec.ctx)
            painter.fillStyle = "red"
            fillRect(painter,0,0,8,6)
            translate(painter,Vec2(1,0))
            clip(painter,parse_path("M1 1H5V5H1Z"))
            clip(painter,parse_path("M0 0H7V4H0Z"))
            painter.globalAlpha = 0.1f0
            clearRect(painter,2,0,8,6)
        end
        image = Image(8,6)
        drawPicture(image,finishRecording(rec))
        @test image.data == ctx.image.data
        for row in 1:6, column in 1:8
            expected = row in 2:4 && column in 4:6 ? rgbx(0,0,0,0) : rgbx(255,0,0,255)
            @test image[row,column] == expected
        end
    end
    @testset "Nested layers retain their drawing destination" begin
        ctx = Context(8,8)
        rec = PictureRecorder(8,8)
        for painter in (ctx,rec.ctx)
            saveLayer(painter)
            save(painter)
            painter.fillStyle = "red"
            fillRect(painter,0,0,4,4)
            restore(painter)
            @test ctx.image[1,1].a == 0
            painter.fillStyle = "blue"
            fillRect(painter,4,4,4,4)
            # Finish the recording in the same state as the immediate canvas.
            painter === rec.ctx && restore(painter)
        end
        restore(ctx)
        image = Image(8,8)
        drawPicture(image,finishRecording(rec))
        @test image.data == ctx.image.data
        @test image[1,1] == rgbx(255,0,0,255)
        @test image[8,8] == rgbx(0,0,255,255)
    end
    @testset "Overlapping image data is sampled before drawing" begin
        original = Image(8,6)
        for y in 1:6,x in 1:8
            original[y,x] = rgbx(10x,20y,5x,255)
        end
        for mapping in (translate(Vec2(2,1)),translate(Vec2(1.5,-0.5)),scale(Vec2(2,2))),
            painter in (draw,drawTiled)
            actual,expected = copy(original),copy(original)
            painter(actual,Image(8,6,actual.data),mapping)
            painter(expected,original,mapping)
            @test actual.data == expected.data
        end
    end
    @testset "SVG viewport origins scale with the viewport" begin
        svg = """<svg viewBox="10 20 4 2"><rect x="10" y="20" width="2" height="2" fill="red"/></svg>"""
        im = newImage(parseSvg(svg,8,4))
        @test count(p->p.a==255,im) == 16
        @test im[1,1].r == 255 && im[1,5].a == 0
    end
    @testset "SVG opacity applies once to grouped paint" begin
        source = """<svg viewBox="0 0 12 4" opacity="0.5">
            <g style="opacity:0.5">
                <rect x="0" y="0" width="4" height="4" fill="red"/>
                <rect x="1" y="0" width="3" height="4" fill="blue"/>
            </g><g opacity="0"><rect width="12" height="4"/></g>
            <rect x="6" y="1" width="4" height="2" fill="red" stroke="blue" stroke-width="2" opacity="0.5"/>
        </svg>"""
        im = newImage(parseSvg(source))
        @test im[2,1] == rgbx(64,0,0,64)
        @test im[2,3] == rgbx(0,0,64,64)
        @test im[2,7] == rgbx(0,0,64,64)
        @test im[2,5].a == 0
    end
    @testset "Nested edits protect ancestors and release only unused revisions" begin
        c = Canvas(size=(8,8))
        image = new_image(1,1)
        fill!(image,rgba(255,0,0,255))
        parent_ref, layer, child_id, child_ref = transaction!(c) do e
            parent_ref = resource!(e,image)
            draw_image!(e,parent_ref,(0,0,2,2))
            child_id, child_ref = Ref{UInt64}(), Ref{ResourceRef}()
            id = with_group(e) do child
                @test_throws ModelError rectangle!(e,0,0,4,4;fill=Solid(1,0,0))
                @test_throws ModelError release_resource!(child,parent_ref)
                child_ref[] = resource!(child,image)
                child_id[] = draw_image!(child,child_ref[],(2,2,2,2))
            end
            return parent_ref,id,child_id[],child_ref[]
        end
        before = snapshot(c)
        transaction!(c) do e
            Vellum.edit_layer!(e,layer) do child
                @test_throws ModelError remove_node!(e,layer)
                remove_node!(child,child_id)
                release_resource!(child,child_ref)
                @test_throws ModelError release_resource!(child,parent_ref)
            end
        end
        @test rasterize(before)[3,3].r == 255
        im = rasterize(snapshot(c))
        @test im[1,1].r == 255 && im[3,3].a == 0
    end
end
