using Downloads, TOML

# Source includes are relative to the including file. Project-relative references
# appear in source comments and README links. Namespace identifiers are not URLs to fetch.
root = dirname(@__DIR__)
paths = [joinpath(dir,file) for base in ("src","ext","tools","test","tutorials","docs")
         for (dir,_,files) in walkdir(joinpath(root,base)) for file in files if endswith(file,".jl")]
urls = Set{String}()
for path in paths
    contents = read(path,String)
    for m in eachmatch(r"(?m)^\s*include\(\"([^\"\n]+\.jl)\"\)",contents)
        isfile(joinpath(dirname(path),m[1])) || error("unresolved include $(m[1]) in $path")
    end
    any(d->startswith(path,joinpath(root,d,"")),("src","ext")) || continue
    for m in eachmatch(r"\b(?:src|ext|test|docs|tools|tutorials|examples)/[\w/.-]+\.jl\b",contents)
        isfile(joinpath(root,m.match)) || error("unresolved source reference $(m.match) in $path")
    end
    for m in eachmatch(r"`((?:src|test|docs|tools|examples|native|scripts|build)/[\w/.-]+)`",contents)
        ispath(joinpath(root,m[1])) || error("unresolved project path $(m[1]) in $path")
    end
    for m in eachmatch(r"https?://[^\s`<>\"\\)]+",contents)
        url = rstrip(m.match, ('.', ','))
        url == "http://www.w3.org/2000/svg" || push!(urls,String(url))
    end
end
for artifact in values(TOML.parsefile(joinpath(root,"Artifacts.toml"))), download in artifact["download"]
    push!(urls,download["url"])
end
guides = [joinpath(root,"README.md")]
for dir in ("wiki","src")
    append!(guides,filter(path -> endswith(path,".md"),readdir(joinpath(root,"docs",dir);join=true)))
end
for page in guides
    for m in eachmatch(r"\[[^\]]+\]\(([^)]+)\)",read(page,String))
        dest = m[1]
        startswith(dest,"https://") ? push!(urls,dest) :
            isfile(joinpath(dirname(page),dest)) || error("unresolved link $dest in $page")
    end
end
for url in sort!(collect(urls))
    response = Downloads.request(url;method="HEAD",timeout=30)
    if response.status in (403,405,501)
        response = Downloads.request(url;timeout=30)
    end
    200 <= response.status < 400 || error("HTTP $(response.status) for $url")
    println(response.status," ",url)
end
println("Checked source includes and local links across ",length(paths)," Julia files.")
