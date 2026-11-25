using Tar, TOML
include("lessons.jl")

"""
    stage_wiki(destination)

Prepare the guides, tutorial downloads and built HTML reference for the
skynet-core/Vellum.jl wiki in a fresh directory. Return the directory.
"""
function stage_wiki(destination)
    root = dirname(@__DIR__)
    build = joinpath(@__DIR__,"build")
    isfile(joinpath(build,"index.html")) || error("build the HTML reference with docs/make.jl first")
    pages = joinpath(@__DIR__,"wiki")
    version = TOML.parsefile(joinpath(root,"Project.toml"))["version"]
    base = "https://github.com/skynet-core/Vellum.jl/wiki"
    raw = "https://raw.githubusercontent.com/wiki/skynet-core/Vellum.jl/assets"
    mkpath(destination)
    isempty(readdir(destination)) || throw(ArgumentError("wiki staging directory must be empty"))
    assets = mkdir(joinpath(destination,"assets"))
    archive = "vellum-reference-$version.tar"
    Tar.create(build,joinpath(assets,archive))
    rewrites = Pair{String,String}[]
    for name in tutorial_names(root), suffix in (".jl",".ipynb")
        file = name*suffix
        cp(joinpath(root,"tutorials",file),joinpath(assets,file))
        push!(rewrites,"](../../tutorials/$file)"=>"]($raw/$file)")
    end
    guides = sort(filter(name -> endswith(name,".md"), readdir(pages)))
    for name in guides
        push!(rewrites,"]($name)"=>"]($base/$(first(splitext(name))))")
    end
    for name in guides
        page = replace(read(joinpath(pages,name),String),rewrites...)
        if name == "API-reference.md"
            page *= "\nDownload the [HTML reference for Vellum $version]($raw/$archive). Extract the archive and open `index.html` in your browser.\n"
        end
        write(joinpath(destination,name),page)
    end
    return destination
end

if abspath(PROGRAM_FILE) == @__FILE__
    println(stage_wiki(abspath(only(ARGS))))
end
