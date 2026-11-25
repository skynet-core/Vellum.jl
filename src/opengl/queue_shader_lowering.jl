"""GLSL spellings for Julia types used in the Vulkan draw kernel."""
const shader_types = Dict(:Int=>"int",:UInt32=>"uint",:Bool=>"bool",:Float32=>"float",:Float64=>"double",
    :PointI=>"ivec2",:PointD=>"dvec2",:Pixel=>"vec4",:PacketTables=>"PacketTables",:DrawPass=>"DrawPass",
    :Nothing=>"void",:word_float=>"uintBitsToFloat",:float_word=>"floatBitsToUint",
    :write_scratch! => "write_scratch", :execute_pass! => "execute_pass")

"""
    shader_expr(ex)

Lower one scalar, vector or buffer access from the typed Julia kernel.
"""
function shader_expr(ex)
    ex isa QuoteNode && return String(ex.value)
    ex isa Symbol && return get(shader_types,ex,String(ex))
    ex isa Bool && return string(ex)
    ex isa Integer && return string(ex)
    ex isa Float32 && return string(Float64(ex),"f")
    ex isa Float64 && return string(ex,"lf")
    args = ex.args
    ex.head === :block && return shader_expr(only(filter(x -> !(x isa LineNumberNode),args)))
    if ex.head === :.
        return args[1] === :data ? String(args[2].value) : shader_expr(args[1])*"."*shader_expr(args[2])
    elseif ex.head === :ref
        return shader_expr(args[1])*"[("*shader_expr(args[2])*")-1]"
    elseif ex.head in (:&&,:||)
        return "("*join(shader_expr.(args),String(ex.head))*")"
    elseif ex.head === :if
        return "("*shader_expr(args[1])*" ? "*shader_expr(args[2])*" : "*shader_expr(args[3])*")"
    elseif ex.head === :call
        op = first(args)
        a = args[2:end]
        if op in (:+,:-,:*,:/,:÷,:%,:<,:>,:<=,:>=,:(==),:(!=),:&,:!)
            token = op === :÷ ? "/" : String(op)
            return "("* (length(a)==1 ? token*shader_expr(only(a)) : join(shader_expr.(a)," "*token*" ")) *")"
        elseif op === :at_offset
            return shader_expr(a[1])*"["*shader_expr(a[2])*"]"
        elseif op === :floor_point
            return "ivec2(floor("*shader_expr(only(a))*"))"
        elseif op === :unpack_color || op === :pack_color
            return (op === :unpack_color ? "unpackUnorm4x8" : "packUnorm4x8")*"("*shader_expr(only(a))*")"
        end
        return shader_expr(op)*"("*join((shader_expr(x) for x in a if x !== :data),", ")*")"
    end
    throw(ArgumentError("unsupported Vulkan shader expression $ex"))
end

"""
    shader_stmt(ex)

Lower the structured control flow of a kernel function. Julia ranges include their final endpoint.
"""
function shader_stmt(ex)
    ex isa LineNumberNode && return ""
    ex isa Expr || return shader_expr(ex)*";\n"
    a = ex.args
    if ex.head === :block
        return join(shader_stmt.(a))
    elseif ex.head === :if || ex.head === :elseif
        tail = length(a)==3 ? "else {\n"*shader_stmt(a[3])*"}\n" : ""
        return "if ("*shader_expr(a[1])*") {\n"*shader_stmt(a[2])*"}\n"*tail
    elseif ex.head === :for
        var,range = a[1].args
        Meta.isexpr(range,:call,3) && range.args[1] === :(:) || error("expected an inclusive kernel range")
        first,last = shader_expr.(range.args[2:3])
        return "for (int $var=$first; $var<=$last; ++$var) {\n"*shader_stmt(a[2])*"}\n"
    elseif ex.head === :while
        return "while ("*shader_expr(a[1])*") {\n"*shader_stmt(a[2])*"}\n"
    elseif ex.head === :return
        (isempty(a) || only(a) === :nothing) && return "return;\n"
        return "return "*shader_expr(only(a))*";\n"
    elseif ex.head in (:continue,:break)
        return String(ex.head)*";\n"
    elseif ex.head === :(=) && Meta.isexpr(a[1],:(::))
        name,type = a[1].args
        if type === :LayerStack
            a[2] == :(LayerStack(undef)) || error("expected an uninitialized layer stack")
            return "vec4 $name[$(QUEUE_LIMITS.depth+1)];\n"
        end
        return shader_expr(type)*" "*String(name)*" = "*shader_expr(a[2])*";\n"
    elseif ex.head in (:(=),:+=,:-=,:*=)
        return shader_expr(a[1])*" "*String(ex.head)*" "*shader_expr(a[2])*";\n"
    end
    return shader_expr(ex)*";\n"
end

"""
    @draw_kernel(block)

Define executable Julia kernel functions and generate their GLSL function bodies from the same expressions.
"""
macro draw_kernel(block)
    chunks = String[]
    for expression in block.args
        expression isa LineNumberNode && continue
        fn = Meta.isexpr(expression,:macrocall) ? last(expression.args) : expression
        Meta.isexpr(fn,:function) || error("expected a Julia kernel function")
        signature,body = fn.args
        call,ret = signature.args
        params = [shader_expr(arg.args[2])*" "*String(arg.args[1]) for arg in call.args[2:end] if arg !== :data]
        push!(chunks,shader_expr(ret)*" "*shader_expr(call.args[1])*"("*join(params,", ")*") {\n"*shader_stmt(body)*"}\n")
    end
    return quote
        $(esc(block))
        @doc "Shader functions generated from the Julia draw kernel." const $(esc(:KERNEL_FUNCTIONS)) = $(join(chunks))
    end
end
