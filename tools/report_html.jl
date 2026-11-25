html_escape(s) = replace(string(s), '&'=>"&amp;", '<'=>"&lt;", '>'=>"&gt;", '"'=>"&quot;")

function report_header(io, title)
    println(io, """<!doctype html><html lang="en"><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1"><title>$(html_escape(title))</title>
    <style>
    body{font:16px system-ui,sans-serif;max-width:90rem;margin:auto;padding:2rem;color:#19242a}
    h1,h2{line-height:1.2}table{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}
    th,td{text-align:left;padding:.3rem .6rem;border-bottom:1px solid #d7dfe1}
    summary{cursor:pointer;padding:.4rem} pre{overflow:auto;line-height:1.5}
    .line{display:block}.hits,.miss,.blank{display:inline-block;width:12ch;text-align:right;
    margin-right:1em;padding:0 .5em;user-select:none}.hits{background:#d8f3dd}.miss{background:#ffdcd6}
    .blank{color:#6c7274}a{color:#075b88}meter{width:9rem}small{color:#40494b}
    </style><h1>$(html_escape(title))</h1>""")
end

"""Write source-line coverage for the selected unit or desktop integration workload."""
function coverage_html(path, files, root; integration=false)
    hits, total = CoverageTools.get_summary(files)
    open(path,"w") do io
        report_header(io,integration ? "Vellum desktop integration and unit coverage" : "Vellum unit test coverage")
        println(io,"<p><strong>",round(100hits/total;digits=2),"%</strong> of executable source lines covered (",
                hits," of ",total,"). ",integration ? "Includes live X11, OpenGL and Wayland checks." :
                "Unit-test release minimum: 95%.","</p>")
        println(io,"<p>Expand a file to inspect its source. Each numbered line shows its execution count. A dash marks a non-executable line.</p>")
        for file in sort(files;by=f->f.filename)
            c,t = CoverageTools.get_summary(file)
            name = html_escape(relpath(file.filename,root))
            ratio = t == 0 ? "—" : string(round(100c/t;digits=1), "%")
            println(io,"<details><summary><meter min=0 max=",max(t,1)," value=",c,"></meter> ",name," · ",ratio,
                    " (",c,"/",t,")</summary><pre>")
            for (n,line) in enumerate(eachline(IOBuffer(file.source)))
                count = get(file.coverage,n,nothing)
                class = isnothing(count) ? "blank" : iszero(count) ? "miss" : "hits"
                print(io,"<span class=line><span class=",class,">",n," | ",something(count,"–"),
                      "</span>",html_escape(line),"</span>")
            end
            println(io,"</pre></details>")
        end
        println(io,"</html>")
    end
end

function gpu_html(tsv)
    rows = readlines(tsv)
    open(splitext(tsv)[1]*".html","w") do io
        report_header(io,"Vellum GPU profile")
        for line in rows[1:2]
            println(io,"<p>",html_escape(chopprefix(line,"# ")),"</p>")
        end
        entries = [split(line,'\t') for line in rows[4:end]]
        peak = maximum((parse(Float64,r[3]) for r in entries if !isempty(r[3]));init=1.0)
        println(io,"<p>Each row measures one device workload. Other package methods have no device measurement in this run.</p>")
        println(io,"<table><tr><th>Function or blend mode</th><th>Inputs</th><th>Median device time (µs)</th><th>Status</th></tr>")
        for (name,n,median,status) in entries
            bar = isempty(median) ? "—" : "<meter max=$peak value=$median></meter> $median"
            println(io,"<tr><td>",html_escape(name),"</td><td>",html_escape(n),"</td><td>",bar,
                    "</td><td>",html_escape(status),"</td></tr>")
        end
        println(io,"</table>")
        cpu = joinpath(dirname(tsv),"cpu.tsv")
        if isfile(cpu)
            measured = Set((r[5],r[6],r[7]) for r in entries if !isempty(r[3]))
            missing = [r for r in (split(line,'\t') for line in Iterators.drop(readlines(cpu),1))
                       if (r[1],r[2],r[3]) ∉ measured]
            println(io,"<details><summary>",length(missing)," package methods without a device measurement</summary>",
                    "<p>This inventory includes host operations such as file I/O and window management.</p>",
                    "<table><tr><th>Method</th><th>Defined at</th></tr>")
            for (method,file,line,_) in missing
                println(io,"<tr><td>",html_escape(method),"</td><td>",html_escape(file),":",line,"</td></tr>")
            end
            println(io,"</table></details>")
        end
        println(io,"</html>")
    end
end
