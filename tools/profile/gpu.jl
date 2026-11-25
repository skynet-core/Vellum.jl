# Run with Vellum active and the CUDA environment on LOAD_PATH.
using Vellum, CUDA, Statistics, Random
import LinearAlgebra
include("../report_html.jl")

function array_kernel!(f, output, inputs)
    i = (blockIdx().x - 1) * blockDim().x + threadIdx().x
    if i <= length(output)
        args = map(a -> (@inbounds a[i]), inputs)
        @inbounds output[i] = f(args...)
    end
    return
end

# Float operations may fuse on the GPU. Integer-only geometry and private byte
# helpers must match exactly. Float-based pixel blends allow one quantization step.
same_output(a::Integer,b::Integer) = a == b
same_output(a::AbstractFloat,b::AbstractFloat) = isapprox(a,b;rtol=2f-5,atol=2f-6)
same_output(a::ColorRGBX,b::ColorRGBX) = all(i -> abs(Int(getfield(a,i))-Int(getfield(b,i)))<=1, 1:4)
same_output(a::T,b::T) where T = all(i -> same_output(getfield(a,i),getfield(b,i)), 1:fieldcount(T))

function measure(f, inputs...)
    reference = map(f,inputs...)
    device_inputs = map(CuArray,inputs)
    output = CuArray{eltype(reference)}(undef,length(reference))
    kernel = @cuda launch=false array_kernel!(f, output, device_inputs)
    launch() = kernel(f, output, device_inputs; threads=256, blocks=cld(length(output),256))
    CUDA.@sync launch()
    times = [CUDA.@elapsed(launch()) for _ in 1:51]
    mismatches = count(((a,b),) -> !same_output(a,b), zip(Array(output),reference))
    return round(1e6median(times); digits=3), mismatches
end

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
            record("OverwriteBlend (source copy)", (backdrop,source)->source, a, b)
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

function main(output_path)
    CUDA.functional(true) || error("a working CUDA device is required")
    n = 1 << 18
    mkpath(dirname(abspath(output_path)))
    failures = open(output_path, "w") do io
        println(io, "# Device: ", CUDA.name(CUDA.device()), " | Julia ", VERSION, " | CUDA.jl ", pkgversion(CUDA))
        println(io, "# Median of 51 warm CUDA event measurements per batch of ", n, " inputs. Transfers and compilation are excluded.")
        println(io, "function\tinputs\tmedian_device_us\tstatus\tmethod\tsource\tline")
        failed = 0
        profile_workloads(n) do name, f, inputs...
            method = which(f,Tuple{eltype.(inputs)...})
            location = relpath(string(method.file),Base.pkgdir(Vellum))
            try
                us,mismatches = measure(f,inputs...)
                status = iszero(mismatches) ? "measured" : "$mismatches CPU/GPU mismatches"
                failed += !iszero(mismatches)
                print(io,name,'\t',n,'\t',us,'\t',status)
            catch err
                err isa InterruptException && rethrow()
                failed += 1
                print(io,name,'\t',n,"\t\tfailed ",typeof(err))
                showerror(stderr,err)
                println(stderr)
            end
            println(io,'\t',method.sig,'\t',location,'\t',method.line)
            flush(io)
        end
        failed
    end
    gpu_html(output_path)
    failures == 0 || error("$failures GPU workloads failed")
end

main(only(ARGS))
