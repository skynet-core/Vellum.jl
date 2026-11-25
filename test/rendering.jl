import ColorTypes

function test_rendering()
    @testset "Recorded drawing matches immediate drawing" begin
        font = read_font(fontfile)
        tile = new_image(4,4)
        fill!(tile,rgba(128,220,24,255))
        function paint_scene(ctx)
            ctx.font = fontfile
            ctx.fontSize = 11
            for (index,spec) in enumerate((
                "M1 2L12 2l0 6h-6v3z", "m2,2 q4,8 8,0 t8,0",
                "M1 8 C1 1 8 1 9 8 s8 8 9 0", "M1 6 A6 4 25 0 1 12 6 a4 3 0 1 0 8 0"))
                save(ctx)
                translate(ctx,Vec2(2,index*10-9))
                ctx.fillStyle = "#6a4"
                ctx.strokeStyle = "rgb(255,0,0)"
                path = parse_path(spec)
                fill(ctx,path,index%2==1 ? EvenOdd : NonZero)
                ctx.lineWidth = 1.5
                setLineDash(ctx,Float32[2,1])
                stroke(ctx,path)
                restore(ctx)
            end
            saveLayer(ctx)
            beginPath(ctx)
            rect(ctx,1,1,44,44)
            clip(ctx)
            ctx.globalAlpha = 0.6
            Vellum.drawImage(ctx,tile,30,9,8,7)
            ctx.fillStyle = "navy"
            fillText(ctx,"ab",26,28)
            strokeText(ctx,"c",38,36)
            restore(ctx)
            for shape in (c->ellipse(c,39,6,3,2), c->circle(c,47,6,2),
                          c->roundedRect(c,27,38,9,6,1,2,1,2), c->polygon(c,45,40,4,5))
                beginPath(ctx)
                shape(ctx)
                ctx.fillStyle="lime"
                fill(ctx)
            end
        end
        ctx, rec = Context(55,50), PictureRecorder(55,50)
        paint_scene(ctx)
        paint_scene(rec.ctx)
        picture = finishRecording(rec)
        image = new_image(55,50)
        drawPicture(image,picture)
        @test image.data == ctx.image.data
        @test count(p -> p.a > 0, image) > 150
        @test_throws ArgumentError finishRecording(rec)
        @test_throws ArgumentError fillRect(rec.ctx,1,1,2,2)
        mktempdir() do dir
            @test occursin("stroke-dasharray",writeSvg(joinpath(dir,"recording.svg"),picture))
            @test occursin("/Type /Page",writePdf(joinpath(dir,"recording.pdf"),picture))
        end
        for case in (NormalCase,UpperCase,LowerCase,TitleCase), align in (LeftAlign,CenterAlign,RightAlign)
            font.textCase = case
            a = typeset(font,"Vienna äE\nsecond line";bounds=Vec2(65,80),hAlign=align,vAlign=MiddleAlign)
            @test length(a.runes) == length(a.positions) > 10
            img = new_image(65,80)
            fillText(img,a)
            @test any(p->p.a>0,img)
        end
        matrix = Vellum.toColors(image)
        @test Vellum.fromColors(matrix).data == image.data
        @test size(Vellum.fromColors(permutedims(matrix))) == reverse(size(image))
        red = ColorTypes.RGB{Float32}(1,0,0)
        @test Vellum.fromColors(fill(red,2,3))[1] == rgbx(255,0,0,255)
        @test_throws ArgumentError Vellum.fromColors(zeros(2,2))
    end
    @testset "Portable strokes and GPU command preparation" begin
        for cap in (:butt,:round,:square), join_style in (:miter,:round,:bevel)
            frame = drawing(size=(40,40)) do e
                configure!(e; stroke=Solid(1,0,0),stroke_style=StrokeStyle(width=3,cap=cap,join=join_style))
                draw(e,rectangle_path(2,2,32,29);mode=:stroke)
            end
            im = rasterize(frame)
            @test im[2,10].a > 0 && im[10,10].a == 0
            packet = Vellum.OpenGLBackend.pack_frame(frame,(40,40))
            @test all(isfinite, packet.words)
            @test packet.words[2:3] == [40,40]
            @test packet.words[5] > 0
        end
    end
end
