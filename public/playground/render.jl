using Vellum

"""Execute a Julia buffer in a fresh module and directory. Return a Vellum export on the requested backend."""
function render_buffer(source,target)
    target in (:canvas,:webgl2) || error("Choose Canvas or WebGL2")
    mktempdir() do dir
        cd(dir) do
            withenv("VELLUM_TUTORIAL_OUTPUT"=>dir,"VELLUM_TUTORIAL_HOST"=>"browser","VELLUM_TUTORIAL_RENDERER"=>string(target)) do
                lesson = Module(gensym(:Sketch))
                Core.eval(lesson,:(include(path) = Base.include($lesson,path)))
                result = Base.include_string(lesson,source,"sketch.jl")
                if result isa Union{Frame,Canvas,InteractiveDrawing}
                    path = savehtml(joinpath(dir,"preview.html"),result;target)
                else
                    pages = filter(p->endswith(p,".html") && !islink(p) && isfile(p),readdir(dir;join=true))
                    length(pages)==1 || error("Return a Vellum Frame, Canvas or InteractiveDrawing, or export a single HTML drawing.")
                    path = only(pages)
                end
                filesize(path)<=8*1024^2 || error("Preview exceeds 8 MiB")
                read(path,String)
            end
        end
    end
end
