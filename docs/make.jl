import Documenter
pushfirst!(LOAD_PATH, dirname(@__DIR__))
using Vellum
include("tutorials.jl")

"""Modules whose authored API is included in the generated reference."""
const reference_modules = Module[Vellum]
if Sys.islinux() || Sys.isfreebsd()
    const VellumGLXExt = Vellum.OpenGLBackend.glx_extension()
    push!(reference_modules,VellumGLXExt)
end

"""
    reference_pages(source)

Write one reference page per documented Julia source file. Return the page list
for the navigation sidebar, in repository path order.
"""
function reference_pages(source)
    package = pkgdir(Vellum)
    files = Dict{String,Set{Module}}()
    for mod in Base.Docs.modules
        any(root -> first(Base.fullname(mod)) === nameof(root),reference_modules) || continue
        for multidoc in values(Base.Docs.meta(mod)), doc in values(multidoc.docs)
            path = relpath(string(doc.data[:path]), package)
            first(splitpath(path)) in ("src","ext") || continue
            push!(get!(Set{Module}, files, path), mod)
        end
    end
    pages = Pair{String,String}[]
    for path in sort!(collect(keys(files)))
        label = startswith(path,"src/") ? path[5:end] : path
        page = "reference/" * first(splitext(label)) * ".md"
        mkpath(dirname(joinpath(source, page)))
        modules = sort!(string.(collect(files[path])))
        open(joinpath(source, page), "w") do io
            println(io, "# `", label, "`\n\n```@autodocs")
            println(io, "Modules = [", join(modules, ", "), "]")
            println(io, "Pages = [", repr(path), "]\n```")
        end
        push!(pages, label => page)
    end
    return pages
end

mktempdir() do scratch
    source = joinpath(scratch, "src")
    cp(joinpath(@__DIR__, "src"), source)
    for name in ("LICENSE","NOTICE")
        cp(joinpath(pkgdir(Vellum),name),joinpath(source,name))
    end
    pages = reference_pages(source)
    withenv("VELLUM_TUTORIAL_OUTPUT"=>"apps","VELLUM_TUTORIAL_HOST"=>"browser") do
        Documenter.makedocs(
        root=@__DIR__, source=source, sitename="Vellum.jl", modules=reference_modules,
        remotes=nothing,
        format=Documenter.HTML(prettyurls=false, edit_link=nothing, repolink=nothing),
        pages=["Home" => "index.md", "Tutorials" => ["route.md"; [s*".md" for s in tutorial_names(pkgdir(Vellum)) if s!="route"]],
               "API reference" => pages],
        )
    end
end
