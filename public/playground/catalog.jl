import Vellum
include(joinpath(pkgdir(Vellum),"docs","lessons.jl"))

"""Read every runnable lesson and its teaching comments from the installed checkout."""
function playground_lessons()
    dir = joinpath(pkgdir(Vellum),"tutorials")
    return map(tutorial_names(pkgdir(Vellum))) do id
        source = read(joinpath(dir,id*".jl"),String)
        (;id,title=chopprefix(first(split(source,'\n';limit=2)),"# # "),source)
    end
end

"""Default storage for the prebuilt, unedited tutorial previews."""
preview_dir() = get(ENV,"VELLUM_PREVIEW_DIR",joinpath(@__DIR__,"previews"))
