pushfirst!(LOAD_PATH,@__DIR__)
include("catalog.jl")
include("render.jl")

"""
    build_lessons(; check=false)

Render every lesson on Canvas, WebGL2 and WebGPU. With `check=true`, compare
each export with its published file and report missing, stale or extra previews.
"""
function build_lessons(; check=false)
    destination = preview_dir()
    check || mkpath(destination)
    expected = Set{String}()
    for lesson in playground_lessons(), target in (:canvas,:webgl2,:webgpu)
        filename = lesson.id*"-"*string(target)*".html"
        push!(expected,filename)
        @info "Rendering tutorial" filename
        html = render_buffer(lesson.source,target)
        path = joinpath(destination,filename)
        if check
            isfile(path) || error("Missing tutorial preview: $filename")
            read(path,String) == html || error("Outdated tutorial preview: $filename")
        else
            mktemp(destination) do tmp,io
                write(io,html)
                close(io)
                chmod(tmp,0o644)
                Base.Filesystem.rename(tmp,path)
            end
        end
        GC.gc()
    end
    if check
        extra = setdiff(filter(f->endswith(f,".html"),readdir(destination)),expected)
        isempty(extra) || error("Unexpected tutorial previews: $(join(extra,", "))")
        println("Verified ",length(expected)," tutorial previews.")
    end
end
if abspath(PROGRAM_FILE)==@__FILE__
    isempty(ARGS) || ARGS == ["--check"] || error("Usage: build_lessons.jl [--check]")
    build_lessons(;check=!isempty(ARGS))
end
