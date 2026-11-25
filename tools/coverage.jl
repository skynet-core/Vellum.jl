# julia --project=tools/coverage tools/coverage.jl [--integration] [per-file-report.tsv]
using Pkg, Logging
Pkg.instantiate()
using CoverageTools
include("report_html.jl")

const root = dirname(@__DIR__)
const threshold = 95
integration = !isempty(ARGS) && first(ARGS) == "--integration"
destinations = integration ? ARGS[2:end] : ARGS
default_file = integration ? "coverage-integration.tsv" : "coverage.tsv"
report = isempty(destinations) ? joinpath(root, "reports", default_file) : abspath(only(destinations))
mkpath(dirname(report))
mktempdir() do scratch
    # Measure a fresh copy so old .cov files cannot inflate this run.
    for name in ("Project.toml", "Manifest.toml", "LICENSE", "NOTICE")
        cp(joinpath(root,name), joinpath(scratch,name))
    end
    manifest = "Manifest-v$(VERSION.major).$(VERSION.minor).toml"
    isfile(joinpath(root,manifest)) && cp(joinpath(root,manifest),joinpath(scratch,manifest))
    for dir in ("src", "ext", "test")
        for (path, _, files) in walkdir(joinpath(root,dir))
            dest = joinpath(scratch,relpath(path,root))
            mkpath(dest)
            for name in files
                endswith(name, ".cov") || cp(joinpath(path,name),joinpath(dest,name))
            end
        end
    end
    Pkg.activate(scratch)
    if integration
        Sys.islinux() || error("the desktop integration coverage workload requires Linux, X11 and Wayland")
        withenv("VELLUM_TEST_WAYLAND"=>"required","VELLUM_TEST_VULKAN"=>"required","VELLUM_TEST_OPENGL"=>"required","VELLUM_TEST_GLFW"=>"true") do
            Pkg.test(; coverage=true)
        end
    else
        withenv("WAYLAND_DISPLAY"=>nothing,"VELLUM_TEST_WAYLAND"=>nothing,
                "VELLUM_TEST_VULKAN"=>nothing,"VELLUM_TEST_VULKAN_QUEUE"=>nothing,"VELLUM_TEST_OPENGL"=>nothing,"VELLUM_TEST_GLFW"=>nothing) do
            Pkg.test(; coverage=true)
        end
    end
    files = with_logger(NullLogger()) do
        vcat((CoverageTools.process_folder(joinpath(scratch,dir)) for dir in ("src","ext"))...)
    end
    coverage_html(splitext(report)[1] * ".html", files, scratch; integration)
    local_files = [CoverageTools.FileCoverage(relpath(f.filename,scratch),f.source,f.coverage) for f in files]
    CoverageTools.LCOV.writefile(splitext(report)[1] * ".info",local_files)
    open(report,"w") do io
        println(io, "source\tcovered\texecutable")
        for file in files
            hits, lines = CoverageTools.get_summary(file)
            println(io,relpath(file.filename,scratch),'\t',hits,'\t',lines)
        end
    end
    hits, lines = CoverageTools.get_summary(files)
    println("Executable source lines covered: $hits / $lines (", round(100hits/lines; digits=2), "%)")
    integration || 100hits >= threshold*lines || error("unit coverage is below $threshold%")
end
