"""Discover the runnable Literate lessons by their opening Markdown title."""
function tutorial_names(root)
    dir = joinpath(root,"tutorials")
    return [first(splitext(file)) for file in readdir(dir) if endswith(file,".jl") &&
            startswith(open(readline,joinpath(dir,file)),"# # ")]
end
