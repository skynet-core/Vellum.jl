using Random: MersenneTwister, rand
import LinearAlgebra

"""Call `record(name, function, input_arrays...)` with reproducible pixel and geometry inputs."""
function profile_workloads(record, n)
    color(i) = rgbx(rgba(mod(37i,256),mod(17i,256),mod(73i,256),mod(i,256)))
    a = color.(1:n)
    b = reverse(a)
    rng = MersenneTwister(157)
    random_pixel() = rgbx(rgba(rand(rng,UInt8),rand(rng,UInt8),rand(rng,UInt8),rand(rng,UInt8)))
    for i in n÷2+1:n
        a[i],b[i] = random_pixel(),random_pixel()
    end
    names = (:blendNormal,:blendDarken,:blendMultiply,:blendColorBurn,:blendLighten,:blendScreen,
             :blendColorDodge,:blendOverlay,:blendSoftLight,:blendHardLight,:blendDifference,
             :blendExclusion,:blendHue,:blendSaturation,:blendColor,:blendLuminosity,:blendMask,
             :OverwriteBlend,:blendSubtractMask,:blendExcludeMask)
    for name in names
        if name == :OverwriteBlend
            record("OverwriteBlend (source copy)", blender(OverwriteBlend), a, b)
        else
            record(string(name),getproperty(Vellum,name),a,b)
        end
    end
    u,v = map(c->c.r,a), map(c->c.a,b)
    for f in (Vellum._screenByte,Vellum.blendAlpha)
        record(string(nameof(f)),f,u,v)
    end
    record("_hardLightByte",Vellum._hardLightByte,u,map(c->c.a,a),map(c->c.r,b),v)
    straight = map(Vellum._rgbaWrap,a)
    floats = map(Vellum._toF,straight)
    for (f,inputs) in ((Vellum._rgbaWrap,(a,)),(Vellum._toF,(straight,)),(Vellum._fromF,(floats,)),
                       (Vellum._lum,(floats,)),(Vellum._sat,(floats,)),(Vellum._clipColor,(floats,)),
                       (Vellum._alphaFixByte,(straight,reverse(straight),straight)))
        record(string(nameof(f)),f,inputs...)
    end
    scalars = Float32[0.25+(i%113)/32 for i in 1:n]
    points = map(Vec2,scalars,reverse(scalars))
    boxes = map(rect,points,reverse(points))
    matrices = map(scale,points)
    for (funcs,inputs) in (((+, -, Vellum.dot, rect, Vellum.line, Vellum.segment),(points,reverse(points))),
                           ((+, -, *, /, Vellum.circle),(points,scalars)),
                           ((-, length, Vellum.lengthSq, Vellum.normalize, LinearAlgebra.norm,
                             Vellum.perpendicular, translate, scale, Vellum.angle),(points,)),
                           ((rotate,),(scalars,)),
                           ((Vellum.left,Vellum.top,Vellum.right,Vellum.bottom,Vellum.xy,Vellum.wh,
                             Vellum.snapToPixels),(boxes,)),
                           ((|, &, +),(boxes,reverse(boxes))), ((*,/),(boxes,scalars)),
                           ((transpose,Vellum.determinant,inverse),(matrices,)),
                           ((*,),(matrices,reverse(matrices))), ((*,Vellum.transform),(matrices,points)),
                           ((Vellum.transform,),(matrices,boxes)))
        for f in funcs
            name = string(nameof(f),"(",join(string.(eltype.(inputs)),", "),")")
            record(name,f,inputs...)
        end
    end
end
