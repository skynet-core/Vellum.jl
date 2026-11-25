pushfirst!(LOAD_PATH,@__DIR__)
include("catalog.jl")
include("render.jl")

"""Build standalone Canvas, WebGL2 and WebGPU exports by executing the actual source of each lesson."""
function build_lessons()
    destination = mkpath(preview_dir())
    for lesson in playground_lessons(), target in (:canvas,:webgl2,:webgpu)
        filename = lesson.id*"-"*string(target)*".html"
        @info "Building tutorial" filename
        html = render_buffer(lesson.source,target)
        mktemp(destination) do tmp,io
            write(io,html)
            close(io)
            chmod(tmp,0o644)
            Base.Filesystem.rename(tmp,joinpath(destination,filename))
        end
        GC.gc()
    end
end
if abspath(PROGRAM_FILE)==@__FILE__
    build_lessons()
end
