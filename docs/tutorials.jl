import Literate
include("lessons.jl")

"""Generate a Markdown lesson and an editable IJulia notebook for each runnable tutorial."""
function generate_tutorial(root)
    for name in tutorial_names(root)
        source = joinpath(root,"tutorials",name*".jl")
        Literate.notebook(source, dirname(source); execute=false, credit=false)
        Literate.markdown(source, joinpath(root, "docs", "src"); execute=false, credit=false,
                          postprocess=text->rstrip(text)*"\n")
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    generate_tutorial(dirname(@__DIR__))
end
