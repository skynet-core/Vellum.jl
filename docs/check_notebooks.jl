using Base64, Pkg, SHA, Test
import JSON
include("tutorials.jl")

"""
    check_literate_sources(root, scratch, names)

Regenerate the named lessons under `scratch` and compare their Markdown and notebook cells with the checkout.
"""
function check_literate_sources(root, scratch, names)
    generated = joinpath(scratch, "literate")
    sources = mkpath(joinpath(generated, "tutorials"))
    mkpath(joinpath(generated, "docs", "src"))
    for name in names
        cp(joinpath(root, "tutorials", name * ".jl"), joinpath(sources, name * ".jl"))
    end
    generate_tutorial(generated)
    for name in names
        @testset "$name sources" begin
            markdown = joinpath("docs", "src", name * ".md")
            @test read(joinpath(generated, markdown), String) == read(joinpath(root, markdown), String)
            notebook = joinpath("tutorials", name * ".ipynb")
            authored_cells = map((generated, root)) do tree
                [(c["cell_type"], join(c["source"])) for c in JSON.parsefile(joinpath(tree, notebook))["cells"]]
            end
            @test first(authored_cells) == last(authored_cells)
        end
    end
end

"""
    lesson_kernel(directory, consumer)

Write a temporary kernel specification for the Julia project at `consumer` and return the kernel name.
"""
function lesson_kernel(directory, consumer)
    name = "vellum-qualification"
    path = mkpath(joinpath(directory,"kernels",name))
    argv = [Base.julia_cmd().exec; "--startup-file=no"; "--project=$consumer"; "-i"; "-e";
            "import IJulia; IJulia.run_kernel()"; "{connection_file}"]
    write(joinpath(path,"kernel.json"),JSON.json((;argv,display_name="Vellum qualification",language="julia")))
    return name
end

"""
    execute_lesson(client, kernel, file, environment)

Execute the temporary notebook in a fresh kernel, verify its cell counts and return its displayed MIME data.
"""
function execute_lesson(client, kernel, file, environment)
    directory = dirname(file)
    cmd = Cmd(`$client --inplace --kernel_name=$kernel --startup_timeout=180 --timeout=300 $file`;dir=directory)
    run(addenv(cmd,environment...,"VELLUM_TUTORIAL_OUTPUT"=>directory))
    cells = filter(c->c["cell_type"]=="code",JSON.parsefile(file)["cells"])
    @test !isempty(cells)
    @test [c["execution_count"] for c in cells] == collect(1:length(cells))
    outputs = [o for c in cells for o in c["outputs"]]
    @test all(o->o["output_type"]!="error",outputs)
    return [o["data"] for o in outputs if haskey(o,"data")]
end

"""
    lesson_outputs(directory)

Return the SHA-256 digest of each exported PNG, HTML and Wasm file, keyed by its basename.
"""
function lesson_outputs(directory)
    return Dict(file=>open(sha256,joinpath(directory,file)) for file in readdir(directory)
                if last(splitext(file)) in (".png",".wasm",".html"))
end

"""
    check_lesson(client, kernel, environment, consumer, root, scratch, name)

Run one published script and notebook separately and compare their saved files and the inline drawing.
"""
function check_lesson(client,kernel,environment,consumer,root,scratch,name)
    scriptdir = mkpath(joinpath(scratch,name,"script"))
    bookdir = mkpath(joinpath(scratch,name,"notebook"))
    file = joinpath(root,"tutorials",name*".jl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --project=$consumer $file`;dir=scriptdir)
    loadpath = join(("@","@stdlib"),Sys.iswindows() ? ';' : ':')
    run(addenv(cmd,"JULIA_LOAD_PATH"=>loadpath,"VELLUM_TUTORIAL_OUTPUT"=>scriptdir,
               "VELLUM_TUTORIAL_HOST"=>"browser","VELLUM_TUTORIAL_RENDERER"=>"webgl2"))
    notebook = joinpath(bookdir,name*".ipynb")
    cp(joinpath(root,"tutorials",basename(notebook)),notebook)
    displays = execute_lesson(client,kernel,notebook,environment)
    expected = lesson_outputs(scriptdir)
    @test !isempty(expected)
    @test lesson_outputs(bookdir) == expected
    if name == "route"
        png = only(d["image/png"] for d in displays if haskey(d,"image/png"))
        @test sha256(base64decode(join(png))) == expected["route.png"]
    else
        html = only(file for file in keys(expected) if endswith(file,".html"))
        @test haskey(expected,first(splitext(html))*".wasm")
        inline = only(join(d["text/html"]) for d in displays if haskey(d,"text/html") && occursin("<iframe",join(d["text/html"])))
        src = only(match(r"src=\"data:text/html;base64,([^\"]+)\"",inline).captures)
        @test sha256(base64decode(src)) == expected[html]
    end
end

"""
    check_route_edit(client, kernel, environment, consumer, root, scratch)

Edit the route height in a fresh notebook and verify the station and park pixels against the original PNG.
"""
function check_route_edit(client,kernel,environment,consumer,root,scratch)
    directory = mkpath(joinpath(scratch,"changed"))
    file = joinpath(directory,"route.ipynb")
    notebook = JSON.parsefile(joinpath(root,"tutorials","route.ipynb"))
    cell = only(c for c in notebook["cells"] if c["cell_type"]=="code" && occursin(r"(?m)^route_y = 32$",join(c["source"])))
    cell["source"] = [replace(join(cell["source"]),"route_y = 32"=>"route_y = 64")]
    write(file,JSON.json(notebook))
    displays = execute_lesson(client,kernel,file,environment)
    png = only(d["image/png"] for d in displays if haskey(d,"image/png"))
    changed = joinpath(directory,"route.png")
    @test sha256(base64decode(join(png))) == open(sha256,changed)
    original = joinpath(scratch,"route","script","route.png")
    check = """
        using Vellum, Test
        before, after = read_image.(ARGS)
        @test size(before) == size(after) == (192,320)
        @test before[65,73] == after[129,73] == rgbx(255,255,255,255)
        @test before[65,67] == after[129,67] == rgbx(31,64,140,255)
        @test before[129,67] == after[65,67] == rgbx(245,240,224,255)
        @test before[50,150] == after[50,150] == rgbx(158,199,148,255)
        """
    run(addenv(`$(Base.julia_cmd()) --startup-file=no --project=$consumer -e $check $original $changed`,
               "JULIA_LOAD_PATH"=>join(("@","@stdlib"),Sys.iswindows() ? ';' : ':')))
end

"""
    check_notebooks()

Qualify every published lesson in temporary drawing and kernel projects, with each kernel started by Jupyter.
Set `JUPYTER_EXECUTE` to select a particular `jupyter-execute` executable.
"""
function check_notebooks()
    client = get(ENV,"JUPYTER_EXECUTE","jupyter-execute")
    isnothing(Sys.which(client)) && error("install Jupyter nbclient or set JUPYTER_EXECUTE to its jupyter-execute command")
    root = dirname(@__DIR__)
    previous = Base.active_project()
    mktempdir() do scratch
        consumer = joinpath(scratch,"consumer")
        kerneltools = joinpath(scratch,"kernel-tools")
        try
            names = tutorial_names(root)
            @testset "Literate source parity" check_literate_sources(root,scratch,names)
            Pkg.activate(consumer)
            Pkg.develop(path=root)
            Pkg.add(["JSON","HarfBuzz_jll"])
            Pkg.activate(kerneltools)
            withenv("IJULIA_NODEFAULTKERNEL"=>"1") do
                Pkg.add("IJulia")
            end
            data = joinpath(scratch,"jupyter")
            kernel = lesson_kernel(data,consumer)
            environment = ["JUPYTER_PATH"=>data,"JUPYTER_RUNTIME_DIR"=>mkpath(joinpath(scratch,"runtime")),
                "JULIA_LOAD_PATH"=>join(("@",kerneltools,"@stdlib"),Sys.iswindows() ? ';' : ':'),
                "VELLUM_TUTORIAL_HOST"=>"browser","VELLUM_TUTORIAL_RENDERER"=>"webgl2"]
            @testset "Julia and IJulia tutorial outputs" begin
                for name in names
                    @testset "$name" check_lesson(client,kernel,environment,consumer,root,scratch,name)
                end
                @testset "Edited route" check_route_edit(client,kernel,environment,consumer,root,scratch)
            end
        finally
            Pkg.activate(dirname(previous))
        end
    end
end

if abspath(PROGRAM_FILE) == @__FILE__
    check_notebooks()
end
