import JSON
include("render.jl")

"""Read a bounded Julia program and return its preview on stdout."""
function render_source()
    source = String(read(stdin,32_769))
    ncodeunits(source)<=32_768 || error("Julia source exceeds 32 KiB")
    html = redirect_stdout(devnull) do
        render_buffer(source,Symbol(only(ARGS)))
    end
    print(JSON.json((;html)))
end

try
    render_source()
catch err
    print(JSON.json((;error=first(sprint(showerror,err),4000))))
end
