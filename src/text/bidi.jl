# FriBidi's public C ABI supplies UAX#9 resolution/reordering, not glyph shaping.
# Header/ABI reference: fribidi-{bidi,bidi-types,brackets}.h (LGPL-2.1-or-later).
struct _BidiProvider
    handle::Ptr{Cvoid}
    functions::Dict{Symbol,Ptr{Cvoid}}
    path::String
    version::String
    unicode::String
end
const _BIDI_PROVIDER = Ref{Union{Nothing,_BidiProvider}}(nothing)
const _BIDI_GUARD = ReentrantLock()

function _bidiProvider()
    lock(_BIDI_GUARD) do
        _BIDI_PROVIDER[] === nothing || return _BIDI_PROVIDER[]
        path = get(ENV,"VETRA_FRIBIDI_LIBRARY","")
        isempty(path) && (path = Libdl.find_library(["libfribidi","libfribidi.so.0","libfribidi-0"]))
        isempty(path) && throw(ErrorException("Paragraph bidi requires the optional FriBidi library"))
        handle = Libdl.dlopen(path,Libdl.RTLD_NOW)
        success = false
        try
            functions = Dict(name => Libdl.dlsym(handle,name) for name in (
                :fribidi_get_bidi_type,:fribidi_get_bidi_types,:fribidi_get_bracket_types,
                :fribidi_get_par_embedding_levels_ex,:fribidi_reorder_line))
            version = unsafe_string(unsafe_load(Ptr{Ptr{UInt8}}(Libdl.dlsym(handle,:fribidi_version_info))))
            unicode = unsafe_string(unsafe_load(Ptr{Ptr{UInt8}}(Libdl.dlsym(handle,:fribidi_unicode_version))))
            provider = _BidiProvider(handle,functions,Libdl.dlpath(handle),version,unicode)
            _BIDI_PROVIDER[] = provider
            success = true
            return provider
        finally
            success || Libdl.dlclose(handle)
        end
    end
end

_bidiControl(cp) = cp in (0x061c,0x200e,0x200f) ||
    0x202a <= cp <= 0x202e || 0x2066 <= cp <= 0x2069

struct _BidiLayout
    types::Vector{UInt32}
    levels::Vector{Int8}
    starts::Vector{Int}
    owners::Vector{Int}
    base::UInt32
end

function _bidiLayout(entries,baseDir)
    total = sum(e -> Int128(length(e.cps)),entries;init=Int128(0))
    total <= 1_000_000 || throw(ArgumentError("Bidi codepoint budget exceeded"))
    provider = _bidiProvider()
    functions = provider.functions
    cps = UInt32[]
    starts = Int[]
    owners = Int[]
    for (i,entry) in enumerate(entries)
        push!(starts,length(cps)+1)
        append!(cps,entry.cps)
        append!(owners,fill(i,length(entry.cps)))
    end
    push!(starts,length(cps)+1)
    n = length(cps)
    types,brackets = zeros(UInt32,n),zeros(UInt32,n)
    levels = zeros(Int8,n)
    base = ccall(functions[:fribidi_get_bidi_type],UInt32,(UInt32,),
        baseDir == 5 ? UInt32('א') : UInt32('A'))
    ccall(functions[:fribidi_get_bidi_types],Cvoid,(Ptr{UInt32},Int32,Ptr{UInt32}),
        cps,n,types)
    ccall(functions[:fribidi_get_bracket_types],Cvoid,
        (Ptr{UInt32},Int32,Ptr{UInt32},Ptr{UInt32}),cps,n,types,brackets)
    start = 1
    for stop in 1:n+1
        if stop == n+1 || cps[stop] == _LF_RUNE
            count = stop-start
            if count > 0
                direction = Ref(base)
                result = GC.@preserve types brackets levels ccall(
                    functions[:fribidi_get_par_embedding_levels_ex],Int8,
                    (Ptr{UInt32},Ptr{UInt32},Int32,Ref{UInt32},Ptr{Int8}),
                    pointer(types,start),pointer(brackets,start),count,direction,pointer(levels,start))
                result > 0 || throw(ErrorException("FriBidi embedding allocation failed"))
            end
            stop <= n && (levels[stop] = baseDir == 5 ? 1 : 0)
            start = stop+1
        end
    end
    _BidiLayout(types,levels,starts,owners,base)
end

function _bidiLineOrder(bidi,line)
    isempty(line) && return Int[]
    lo = bidi.starts[first(line)]
    hi = bidi.starts[last(line)+1]-1
    levels = bidi.levels[lo:hi]
    map = Int32.(lo:hi)
    types = bidi.types
    # Reorder NSMs with their base. HarfBuzz, not FriBidi, mirrors/shapes glyphs.
    result = GC.@preserve types levels map ccall(
        _bidiProvider().functions[:fribidi_reorder_line],Int8,
        (UInt32,Ptr{UInt32},Int32,Int32,UInt32,Ptr{Int8},Ptr{UInt32},Ptr{Int32}),
        0x00000002,pointer(types,lo),length(map),0,bidi.base,levels,C_NULL,map)
    result > 0 || throw(ErrorException("FriBidi line reordering failed"))
    order = Int[]
    seen = Set{Int}()
    for index in map
        lo <= index <= hi || throw(ErrorException("Invalid FriBidi position map"))
        entry = bidi.owners[index]
        if !(entry in seen)
            push!(order,entry)
            push!(seen,entry)
        end
    end
    length(order) == length(line) || throw(ErrorException("Incomplete bidi grapheme map"))
    order
end
