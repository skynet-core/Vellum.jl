"""Cumulative conservative owned-allocation/work reservations for one CPU plan."""
mutable struct _TextPreparation
    budget::Int
    charged::Int
    fonts::Set{Any}
end
_TextPreparation(budget::Int) = _TextPreparation(budget,0,Set{Any}())
const _TEXT_PREPARATION_KEY = :vetra_text_preparation

function _fontWork!(bytes::Integer)
    bytes >= 0 || throw(ArgumentError("Invalid font allocation count"))
    work = get(task_local_storage(),_TEXT_PREPARATION_KEY,nothing)
    if work !== nothing
        value = Int128(work.charged)+bytes
        value <= work.budget || throw(ArgumentError("CPU cumulative text preparation budget exceeded"))
        work.charged = Int(value)
    end
    nothing
end

function _withTextPreparation(callback,work)
    storage = task_local_storage()
    previous = get(storage,_TEXT_PREPARATION_KEY,nothing)
    storage[_TEXT_PREPARATION_KEY] = work
    try
        callback()
    finally
        if previous === nothing
            delete!(storage,_TEXT_PREPARATION_KEY)
        else
            storage[_TEXT_PREPARATION_KEY] = previous
        end
    end
end

function _reserveTextFont!(key,bytes)
    work = get(task_local_storage(),_TEXT_PREPARATION_KEY,nothing)
    if work !== nothing && !(key in work.fonts)
        _fontWork!(Int128(bytes)+256)
        push!(work.fonts,key)
    end
end
