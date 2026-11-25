"""Renderer-owned parsed-face/outline/layout cache; no native handles in values."""
mutable struct _CapturedTextCache
    entries::Dict{Any,Any}
    order::Vector{Any}
    budget::Int
    bytes::Int
    hits::Int
    misses::Int
    evictions::Int
end
_CapturedTextCache(budget::Int) = _CapturedTextCache(Dict{Any,Any}(),Any[],budget,0,0,0,0)

function _releaseTextValue!(value)
    if value isa Typeface
        _hbRetireFont!(value.opentype)
    elseif value isa ParagraphLayout
        for font in value.shapedFonts
            _hbRetireFont!(font.typeface.opentype)
        end
    elseif value isa Tuple{ParagraphLayout,Vector{Typeface}}
        _releaseTextValue!(value[1])
    end
end

function _captured_cached!(build, cache::_CapturedTextCache, key)
    if haskey(cache.entries,key)
        cache.hits += 1
        return cache.entries[key]
    end
    cache.misses += 1
    Base.summarysize(key) <= cache.budget ||
        throw(ArgumentError("Text cache key exceeds text_cache_bytes before construction"))
    value = build()
    # Admission accounts for the complete owned Julia graph, including keys,
    # raw font bytes and dictionary capacity, not only the number of entries.
    if Base.summarysize((key,value)) > cache.budget
        _releaseTextValue!(value)
        throw(ArgumentError("Captured text cache entry exceeds text_cache_bytes"))
    end
    cache.entries[key] = value
    push!(cache.order,key)
    cache.bytes = Base.summarysize((cache.entries,cache.order))
    while cache.bytes > cache.budget && !isempty(cache.order)
        oldest = popfirst!(cache.order)
        _releaseTextValue!(pop!(cache.entries,oldest))
        cache.evictions += 1
        cache.bytes = Base.summarysize((cache.entries,cache.order))
    end
    # Empty dictionaries keep their grown capacity; release it when necessary.
    if isempty(cache.entries)
        empty!(cache.order)
        cache.entries = Dict{Any,Any}()
        cache.bytes = 0
    end
    return value
end
