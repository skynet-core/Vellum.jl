# Lower the small set of Julia expressions used by the viewer to browser calls.
# All scene data is serialized separately. Only package-authored expressions enter here.
function _browser_stmt(ex, returns=false)
    if Meta.isexpr(ex,:block)
        body = filter(x -> !(x isa LineNumberNode), ex.args)
        return join((_browser_stmt(line,returns && i==length(body)) for (i,line) in enumerate(body)),";")
    elseif Meta.isexpr(ex,:return)
        return "return " * (isempty(ex.args) ? "" : _browser_expr(ex.args[1]))
    elseif Meta.isexpr(ex,:if) || Meta.isexpr(ex,:elseif)
        cond, yes = ex.args
        no = length(ex.args)==3 ? "else{" * _browser_stmt(ex.args[3],returns) * "}" : ""
        return "if(" * _browser_expr(cond) * "){" * _browser_stmt(yes,returns) * "}" * no
    elseif Meta.isexpr(ex,:macrocall) && ex.args[1] === Symbol("@var")
        return "let " * _browser_expr(last(ex.args))
    end
    return (returns ? "return " : "") * _browser_expr(ex)
end

_browser_expr(x::QuoteNode) = _browser_expr(x.value)
_browser_expr(::Nothing) = "null"
_browser_expr(x::Symbol) = x === :nothing ? "null" : String(x)
_browser_expr(x::Union{String,Number}) = JSON.json(x)

function _browser_expr(ex::Expr)
    arg = ex.args
    if ex.head === :call
        op = arg[1]
        if op === :d
            return "{" * join((JSON.json(String(p.args[1])) * ":" * _browser_expr(p.args[2]) for p in arg[2:end]),",") * "}"
        elseif length(arg)==2 && op in (:+,:-)
            return "(" * String(op) * _browser_expr(arg[2]) * ")"
        elseif op in (:+,:-,:*, :/, :<,:>,:<=,:>=,:(===),:(!==))
            return "(" * join(_browser_expr.(arg[2:end]),String(op)) * ")"
        end
        return _browser_expr(op) * "(" * join(_browser_expr.(arg[2:end]),",") * ")"
    elseif ex.head === :->
        params = arg[1] isa Symbol ? String(arg[1]) : join(string.(arg[1].args),",")
        return "((" * params * ")=>{" * _browser_stmt(arg[2],true) * "})"
    elseif ex.head === :.
        return _browser_expr(arg[1]) * "." * String(arg[2].value)
    elseif ex.head === :ref
        return _browser_expr(arg[1]) * "[" * _browser_expr(arg[2]) * "]"
    elseif ex.head === :vect
        return "[" * join(_browser_expr.(arg),",") * "]"
    elseif ex.head === :(=)
        return _browser_expr(arg[1]) * "=" * _browser_expr(arg[2])
    elseif ex.head in (:&&,:||)
        return "(" * join(_browser_expr.(arg),String(ex.head)) * ")"
    elseif ex.head === :macrocall && arg[1] === Symbol("@new")
        return "new " * _browser_expr(last(arg))
    elseif ex.head === :if
        return "(" * _browser_expr(arg[1]) * "?" * _browser_expr(arg[2]) * ":" * _browser_expr(arg[3]) * ")"
    elseif ex.head === :block
        return "(()=>{" * _browser_stmt(ex,true) * "})()"
    end
    throw(ArgumentError("unsupported browser binding expression $(ex.head)"))
end

macro browser(ex)
    return _browser_expr(ex)
end
