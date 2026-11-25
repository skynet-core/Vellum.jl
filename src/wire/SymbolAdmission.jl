# The exemption is frozen to the P2 literal union, never observed application names.
const BASELINE_NAMES = Dict(String(s)=>s for s in (SCRIPTS...,FEATURES...))
mutable struct SymbolAdmission
    lock::ReentrantLock
    entries::Dict{String,Union{Nothing,Symbol}}
    max_names::Int
    max_bytes::Int
    max_decodes::Int
    charged_names::Int
    charged_bytes::Int
    admitted_names::Int
    admitted_bytes::Int
    active::Int
    high_water::Int
    frozen::Bool
    terminal::Bool
end
const ADMISSION = Ref{SymbolAdmission}()
function __init__()
    ADMISSION[] = SymbolAdmission(ReentrantLock(),Dict{String,Union{Nothing,Symbol}}(),
        4096,1048576,4,0,0,0,0,0,0,false,false)
end

function symbol_admission_usage()
    g = ADMISSION[]
    lock(g.lock) do
        (;max_names=g.max_names,max_bytes=g.max_bytes,max_decodes=g.max_decodes,
          admitted_names=g.admitted_names,admitted_bytes=g.admitted_bytes,
          reserved_names=g.charged_names-g.admitted_names,
          reserved_bytes=g.charged_bytes-g.admitted_bytes,
          active_decodes=g.active,high_water_decodes=g.high_water,
          configuration_frozen=g.frozen,terminal_failure=g.terminal)
    end
end
function configure_symbol_admission!(; max_names=nothing,max_bytes=nothing,max_decodes=nothing)
    g = ADMISSION[]
    lock(g.lock) do
        check(!g.frozen, "symbol configuration frozen")
        max_names = max_names === nothing ? g.max_names : max_names
        max_bytes = max_bytes === nothing ? g.max_bytes : max_bytes
        max_decodes = max_decodes === nothing ? g.max_decodes : max_decodes
        check(max_names isa Integer && 0 <= max_names <= g.max_names &&
              max_bytes isa Integer && 0 <= max_bytes <= g.max_bytes &&
              max_decodes isa Integer && 1 <= max_decodes <= g.max_decodes,
              "symbol configuration must tighten")
        g.max_names,g.max_bytes,g.max_decodes = Int(max_names),Int(max_bytes),Int(max_decodes)
    end
    symbol_admission_usage()
end
function begin_candidate!()
    g = ADMISSION[]
    lock(g.lock) do
        g.frozen = true
        check(g.active < g.max_decodes, "decoder_busy")
        g.active += 1
        g.high_water = max(g.high_water,g.active)
    end
end
function end_candidate!()
    g = ADMISSION[]
    lock(g.lock) do
        g.active -= 1
    end
end

# Sole conversion of incoming bytes to a permanent Julia Symbol.
admit_symbol(name::String) = Symbol(name)
function byte_less(a,b)
    for (x,y) in zip(codeunits(a),codeunits(b))
        x == y || return x < y
    end
    ncodeunits(a) < ncodeunits(b)
end
function admit_names!(finish, names::Set{String})
    g = ADMISSION[]
    lock(g.lock) do
        fresh = sort!([n for n in names if !haskey(BASELINE_NAMES,n) && !haskey(g.entries,n)];lt=byte_less)
        bytes = sum(ncodeunits,fresh;init=0)
        check(isempty(fresh) || !g.terminal, "symbol admission terminal")
        check(length(fresh) <= g.max_names-g.charged_names &&
              bytes <= g.max_bytes-g.charged_bytes, "symbol admission exhausted")
        # Allocate complete reservation/lookup tables before the first conversion.
        reserved = copy(g.entries)
        resolved = Dict{String,Union{Nothing,Symbol}}()
        for n in names
            value = get(BASELINE_NAMES,n,get(g.entries,n,nothing))
            check(!haskey(g.entries,n) || value !== nothing, "symbol reservation incomplete")
            resolved[n] = value
        end
        for n in fresh
            reserved[n] = nothing
        end
        g.entries = reserved
        g.charged_names += length(fresh)
        g.charged_bytes += bytes
        started = false
        try
            for n in fresh
                started = true
                resolved[n] = admit_symbol(n)
            end
            result = finish(resolved)
            completed = copy(g.entries)
            for n in fresh
                completed[n] = resolved[n]::Symbol
            end
            g.entries = completed
            g.admitted_names += length(fresh)
            g.admitted_bytes += bytes
            result
        catch
            started && (g.terminal = true)
            rethrow()
        end
    end
end
