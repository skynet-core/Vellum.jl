function test_graphics()
    @testset "Path authoring and transform overloads agree across contexts" begin
        ctx,rec = Context(48,48),PictureRecorder(48,48)
        for dest in (ctx,rec.ctx)
            dest.fillStyle = "red"
            dest.strokeStyle = "white"
            Vellum.translate!(dest,1,2)
            Vellum.scale!(dest,Vec2(1,1))
            Vellum.rotate!(dest,0.0)
            Vellum.transform!(dest,mat3())
            begin_path!(dest)
            Vellum.move_to!(dest,Vec2(3,6))
            Vellum.line_to!(dest,14,6)
            Vellum.bezier_curve_to!(dest,Vec2(20,2),Vec2(24,14),Vec2(28,14))
            Vellum.quadratic_curve_to!(dest,32,15,28,20)
            Vellum.arc_to!(dest,Vec2(26,26),Vec2(20,25),3f0)
            Vellum.arc!(dest,Vec2(10,18),4f0,Vec2(0,Float32(pi)))
            close_path!(dest)
            fill!(dest,EvenOdd)
            stroke!(dest)
            begin_path!(dest)
            Vellum.circle!(dest,circle(Vec2(20,20),4f0))
            Vellum.rect!(dest,rect(29,27,4,4))
            fill!(dest)
            Vellum.translate!(dest,Vec2(1,0))
            Vellum.scale!(dest,1,1)
            for number in (Int,Float32)
                begin_path!(dest)
                Vellum.circle!(dest,number(6),number(8),number(3))
                Vellum.rect!(dest,number(28),number(6),number(4),number(6))
                stroke!(dest)
            end
        end
        replay = Image(48,48)
        drawPicture(replay,finishRecording(rec))
        @test replay.data == ctx.image.data
        @test count(p->p.a>0,replay) > 300
        for coords in ((3,3,9,9),(3f0,3f0,9f0,9f0))
            p = new_path()
            Vellum.rect!(p,coords...)
            Vellum.circle!(p,coords[1],coords[2],coords[3])
            Vellum.transform!(p,translate(Vec2(1,2)))
            @test Vellum.compute_bounds(p).w > 12
        end
    end
    @testset "Raster filters and alpha masks" begin
        impulse = Image(17,17)
        impulse[9,9] = rgbx(255,255,255,255)
        for radius in (1,2,3,10)
            filtered = copy(impulse)
            blur!(filtered,radius)
            @test filtered[9,9].a >= filtered[8,9].a
            @test filtered[8,9].a == filtered[10,9].a
            @test filtered[9,8].a == filtered[9,10].a
            @test all(p->p.a==p.r==p.g==p.b,filtered)
        end
        @test_throws ArgumentError blur!(copy(impulse),-1)
        grown = copy(impulse)
        spread!(grown,2)
        @test count(p->p.a==255,grown) == 25
        spread!(grown,-2)
        @test count(p->p.a==255,grown) == 1
        mask = Vellum.shadow(impulse,Vec2(2,1),1,0,rgba(255,0,0,255))
        @test mask[10,11] == rgbx(255,0,0,255)
        @test count(p->p.a==255,mask) == 9
        @test impulse[9,9] == rgbx(255,255,255,255)
        for (x,y,w,h) in ((-3,-2,18,17),(3,2,14,14),(3,-2,14,16),(-2,4,16,14))
            extracted = super_image(impulse,x,y,w,h)
            @test extracted[9-y,9-x] == impulse[9,9]
            @test count(p->p.a>0,extracted) == 1
        end
    end
    @testset "SVG primitives, transforms, and paint parsing" begin
        raster(s) = newImage(parseSvg("<svg viewBox=\"0 0 16 16\">$s</svg>"))
        for shape in ("<circle cx='5' cy='5' r='4'/>","<ellipse cx='5' cy='5' rx='4' ry='3'/>",
                      "<rect x='1' y='1' width='8' height='8' rx='2'/>",
                      "<rect x='1' y='1' width='8' height='8' ry='2'/>",
                      "<polygon points='1,1 9,1 9,9 1,9'/>","<polyline points='1 1 9 1 9 9 1 9'/>",
                      "<path d='M1 1H9V9H1Z'/>")
            svg = "<g fill='red' transform='translate(1 1) rotate(0) matrix(1 0 0 1 0 0)'>$shape</g>"
            image = raster(svg)
            @test image[7,7] == rgbx(255,0,0,255)
            @test image[1,1].a == 0
        end
        for cap in ("round","square","butt"), joinstyle in ("round","bevel","miter")
            style = "stroke:red;stroke-width:2px;stroke-linecap:$cap;stroke-linejoin:$joinstyle"
            image = raster("<line x1='1' y1='5' x2='12' y2='5' style='$style'/>")
            @test image[5,5].r > 0
        end
        for attr in ("fill-rule='invalid'","transform='unknown(1)'","stroke-linecap='unknown'","stroke-linejoin='unknown'")
            @test_throws ArgumentError raster("<path d='M1 1H8V8Z' $attr/>")
        end
    end
end
