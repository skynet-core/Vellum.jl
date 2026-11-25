# Run with Vellum active and the CUDA environment on LOAD_PATH.
using Vellum, CUDA, Statistics
include("workloads.jl")
include("../report_html.jl")

"""Evaluate one production method on each tuple of device inputs and retain its output."""
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

"""Measure warm device batches with CUDA events and compare every output to its CPU reference."""
function measure(f, inputs...)
    reference = map(f,inputs...)
    device_inputs = map(CuArray,inputs)
    output = CuArray{eltype(reference)}(undef,length(reference))
    kernel = @cuda launch=false array_kernel!(f, output, device_inputs)
    launch() = kernel(f, output, device_inputs; threads=256, blocks=cld(length(output),256))
    CUDA.@sync launch()
    times = [CUDA.@elapsed(launch()) for _ in 1:51]
    mismatches = count(((a,b),) -> !same_output(a,b), zip(Array(output),reference))
    return round(1e6median(times); digits=3), round(1e6quantile(times,0.95); digits=3), mismatches
end

"""Write the per-workload timing table and visual comparison for the active CUDA device."""
function main(output_path)
    CUDA.functional(true) || error("a working CUDA device is required")
    n = 1 << 18
    mkpath(dirname(abspath(output_path)))
    failures = open(output_path, "w") do io
        println(io, "# Device: ", CUDA.name(CUDA.device()), " | Julia ", VERSION, " | CUDA.jl ", pkgversion(CUDA), " | Vellum ", profile_revision())
        println(io, "# 51 warm CUDA event measurements per batch of ", n, " inputs. Transfers and compilation are excluded.")
        println(io, "function\tinputs\tmedian_device_us\tstatus\tmethod\tsource\tline\tp95_device_us")
        failed = 0
        profile_workloads(n) do name, f, inputs...
            method = which(f,Tuple{eltype.(inputs)...})
            location = relpath(string(method.file),Base.pkgdir(Vellum))
            p95 = ""
            try
                us,p95,mismatches = measure(f,inputs...)
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
            println(io,'\t',method.sig,'\t',location,'\t',method.line,'\t',p95)
            flush(io)
        end
        failed
    end
    gpu_html(output_path)
    failures == 0 || error("$failures GPU workloads failed")
end

main(only(ARGS))
