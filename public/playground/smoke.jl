using Test
import HTTP, JSON, Vellum
include(joinpath(pkgdir(Vellum),"docs","lessons.jl"))

"""Check the deployed editor, all stock previews, and actual isolated Julia jobs over HTTP."""
function check_deployment(url)
    names = tutorial_names(pkgdir(Vellum))
    @test !isempty(names)
    @test String(HTTP.get(url*"/health").body) == "ok"
    @test occursin("Vellum Playground",String(HTTP.get(url).body))
    for id in names
        notebook = JSON.parse(String(HTTP.get(url*"/notebook/"*id).body))
        @test notebook["metadata"]["kernelspec"]["language"] == "julia"
        for target in ("canvas","webgl2","webgpu")
            page = String(HTTP.get("$url/tutorial/$id/$target").body)
            @test occursin("application/wasm",page)
        end
    end
    sketch = "using Vellum; drawing(e->rectangle!(e,1,2,8,7;fill=Solid(1,0,0));size=(13,17))"
    for target in ("canvas","webgl2","webgpu")
        result = HTTP.post("$url/api/run/$target",["Content-Type"=>"application/julia"],sketch;retry=false)
        html = JSON.parse(String(result.body))["html"]
        config = JSON.parse(only(match(r"<script id=gallery type=application/json>(.*?)</script>",html).captures))
        @test config["sizes"] == [[13,17]]
        @test config["targets"] == [target]
        @test occursin("application/wasm",html)
    end
end

@testset "Deployed playground" check_deployment(get(ENV,"VELLUM_SMOKE_URL","http://127.0.0.1:8080"))
