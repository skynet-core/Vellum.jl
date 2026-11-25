mutable struct _HBAdmission
    active_call_limit::Int
    shape_work_budget::Int
    active_calls::Int
    peak_active_calls::Int
    shape_work_charge::Int
    peak_shape_work_charge::Int
    active_inputs::Int
    peak_active_inputs::Int
    live_buffers::Int
    peak_live_buffers::Int
    buffer_creates::Int
    buffer_destroys::Int
end
function _HBAdmission(calls::Int=4,work::Int=128*1024*1024)
    calls > 0 && work > 0 || throw(ArgumentError("Invalid native admission limits"))
    _HBAdmission(calls,work,0,0,0,0,0,0,0,0,0,0)
end
const _HB_GUARD = ReentrantLock()
const _HB_GLOBAL = _HBAdmission()
const _HB_LANGUAGES = Dict{String,Ptr{Cvoid}}()
const _HB_LANGUAGE_REJECTIONS = Ref(0)

mutable struct _HBFaceEntry
    owner::WeakRef
    owner_id::UInt
    handles::NTuple{3,Ptr{Cvoid}}
    generation::UInt64
    blob_bytes::Int
    users::Int
    retired::Threads.Atomic{Bool}
    closed::Bool
    uses::Int
    epoch::UInt64
end

mutable struct _HBFacePool
    guard::ReentrantLock
    # Scalar identity keys plus WeakRef owners avoid per-epoch owner finalizers.
    faces::Dict{UInt,_HBFaceEntry}
    order::Vector{_HBFaceEntry}
    blob_budget::Int
    face_budget::Int
    blob_bytes::Int
    peak_blob_bytes::Int
    hits::Int
    misses::Int
    evictions::Int
    closes::Int
    creates::Int
    rotations::Int
    next_epoch::UInt64
    face_use_limit::Int
    admission::_HBAdmission
end
function _HBFacePool(bytes::Int=32*1024*1024, faces::Int=64;
                     face_use_limit::Int=64,active_call_limit::Int=4,
                     shape_work_budget::Int=128*1024*1024,
                     admission=_HBAdmission(active_call_limit,shape_work_budget))
    bytes > 0 && faces > 0 && face_use_limit > 0 ||
        throw(ArgumentError("Invalid native face limits"))
    _HBFacePool(_HB_GUARD,Dict{UInt,_HBFaceEntry}(),
        _HBFaceEntry[],bytes,faces,0,0,0,0,0,0,0,0,0,face_use_limit,admission)
end
const _HB_POOL = _HBFacePool(;admission=_HB_GLOBAL)
const _HB_GENERATION = Ref(UInt64(0))

mutable struct _HBLease
    pool::_HBFacePool
    entry::_HBFaceEntry
    charge::Int
    inputs::Int
end
_hbAdmissions(pool) = pool.admission === _HB_GLOBAL ? (_HB_GLOBAL,) : (_HB_GLOBAL,pool.admission)

function _hbInitialCharge(inputs::Integer)
    0 <= inputs <= 1_000_000 || throw(ArgumentError("Native input exceeds codepoint budget"))
    Int(Int128(4096)+Int128(512)*inputs)
end

function _hbAdmit!(pool,charge,inputs)
    for policy in _hbAdmissions(pool)
        policy.active_calls < policy.active_call_limit ||
            throw(ArgumentError("HarfBuzz active native lease limit exhausted"))
        Int128(policy.shape_work_charge)+charge <= policy.shape_work_budget ||
            throw(ArgumentError("HarfBuzz concurrent shaping-work budget exhausted"))
    end
    for policy in _hbAdmissions(pool)
        policy.active_calls += 1
        policy.shape_work_charge += charge
        policy.active_inputs += inputs
        policy.peak_active_calls = max(policy.peak_active_calls,policy.active_calls)
        policy.peak_shape_work_charge = max(policy.peak_shape_work_charge,policy.shape_work_charge)
        policy.peak_active_inputs = max(policy.peak_active_inputs,policy.active_inputs)
    end
end
function _hbUnadmit!(pool,charge,inputs)
    for policy in _hbAdmissions(pool)
        policy.active_calls -= 1
        policy.shape_work_charge -= charge
        policy.active_inputs -= inputs
    end
end

function _hbExtend!(lease,outputs::Integer)
    0 <= outputs <= 1_000_000 || throw(ArgumentError("Shaping output exceeds glyph budget"))
    extra = Int(Int128(outputs)*256)
    lock(_HB_GUARD) do
        for policy in _hbAdmissions(lease.pool)
            Int128(policy.shape_work_charge)+extra <= policy.shape_work_budget ||
                throw(ArgumentError("HarfBuzz output shaping-work budget exhausted"))
        end
        for policy in _hbAdmissions(lease.pool)
            policy.shape_work_charge += extra
            policy.peak_shape_work_charge = max(policy.peak_shape_work_charge,policy.shape_work_charge)
        end
        lease.charge += extra
    end
end

function _hbBufferCount!(lease,change)
    lock(_HB_GUARD) do
        for policy in _hbAdmissions(lease.pool)
            policy.live_buffers += change
            policy.peak_live_buffers = max(policy.peak_live_buffers,policy.live_buffers)
            change == 1 ? (policy.buffer_creates += 1) : (policy.buffer_destroys += 1)
        end
    end
end

function _hbLanguage(lang::String)
    1 <= ncodeunits(lang) <= 63 && all(c -> 0 < Int(c) <= 0x7f,lang) ||
        throw(ArgumentError("Language must contain 1–63 ASCII bytes without NUL"))
    lock(_HB_GUARD) do
        haskey(_HB_LANGUAGES,lang) && return _HB_LANGUAGES[lang]
        if length(_HB_LANGUAGES) >= 256
            _HB_LANGUAGE_REJECTIONS[] += 1
            throw(ArgumentError("HarfBuzz provider-lifetime language quota exhausted"))
        end
        value = ccall(_HB_FUNCS[:hb_language_from_string],Ptr{Cvoid},(Cstring,Cint),lang,ncodeunits(lang))
        value !== C_NULL || throw(ErrorException("HarfBuzz rejected language tag"))
        _HB_LANGUAGES[lang] = value # Successful native interning cannot be refunded.
        value
    end
end

# Called only with the pool lock held; active native calls own explicit pins.
function _hbRetire!(pool,entry)
    entry.retired[] = true
    if get(pool.faces,entry.owner_id,nothing) === entry
        delete!(pool.faces,entry.owner_id)
    end
    if entry.users == 0 && !entry.closed
        _hbDestroyTriple(entry.handles)
        entry.closed = true
        pool.blob_bytes -= entry.blob_bytes
        pool.closes += 1
    end
end

function _hbDrain!(pool)
    for entry in pool.order
        entry.owner.value === nothing && (entry.retired[] = true)
        entry.retired[] && _hbRetire!(pool,entry)
    end
    filter!(entry -> !entry.closed,pool.order)
end

function _hbAcquire(ot,pool,inputs::Integer=0)
    charge = _hbInitialCharge(inputs)
    _requireHarfBuzz()
    lock(pool.guard) do
        _hbDrain!(pool)
        _hbAdmit!(pool,charge,Int(inputs))
        admitted = false
        try
        entry = get(pool.faces,objectid(ot),nothing)
        if entry !== nothing && (entry.owner.value !== ot || entry.generation != _HB_GENERATION[])
            _hbRetire!(pool,entry)
            _hbDrain!(pool)
            entry = nothing
        end
        if entry !== nothing && !entry.closed && entry.generation == _HB_GENERATION[]
            lease = _HBLease(pool,entry,charge,Int(inputs))
            pool.hits += 1
            entry.users += 1
            entry.uses += 1
            if entry.uses == pool.face_use_limit
                pool.rotations += 1
                _hbRetire!(pool,entry)
            end
            admitted = true
            return lease
        end
        pool.misses += 1
        bytes = length(ot.buf)
        0 < bytes <= min(16*1024*1024,pool.blob_budget,typemax(UInt32)) ||
            throw(ArgumentError("Font exceeds HarfBuzz native blob budget"))
        while Int128(pool.blob_bytes)+bytes > pool.blob_budget ||
              length(pool.order) >= pool.face_budget
            index = findfirst(entry -> entry.users == 0,pool.order)
            index === nothing &&
                throw(ArgumentError("HarfBuzz face reservation exhausted by active users"))
            _hbRetire!(pool,pool.order[index])
            pool.evictions += 1
            _hbDrain!(pool)
        end
        pool.blob_bytes += bytes # Reserve before hb_blob_create duplicates input.
        pool.peak_blob_bytes = max(pool.peak_blob_bytes,pool.blob_bytes)
        entry = nothing
        handles = nothing
        success = false
        try
            handles = _hbCreateFace(ot)
            pool.next_epoch += 1
            entry = _HBFaceEntry(WeakRef(ot),objectid(ot),handles,_HB_GENERATION[],bytes,1,
                Threads.Atomic{Bool}(false),false,1,pool.next_epoch)
            lease = _HBLease(pool,entry,charge,Int(inputs))
            push!(pool.order,entry)
            pool.faces[objectid(ot)] = entry
            pool.creates += 1
            if entry.uses == pool.face_use_limit
                pool.rotations += 1
                _hbRetire!(pool,entry)
            end
            success = true
            admitted = true
            return lease
        finally
            if !success
                if entry === nothing
                    handles === nothing || _hbDestroyTriple(handles)
                    pool.blob_bytes -= bytes
                else
                    entry.users = 0
                    _hbRetire!(pool,entry)
                    _hbDrain!(pool)
                end
            end
        end
        finally
            admitted || _hbUnadmit!(pool,charge,Int(inputs))
        end
    end
end

function _withHBFace(callback,ot;pool=_HB_POOL,input_count::Integer=0)
    lease = _hbAcquire(ot,pool,input_count)
    try
        GC.@preserve ot callback(lease)
    finally
        lock(pool.guard) do
            entry = lease.entry
            entry.users -= 1
            entry.retired[] && _hbRetire!(pool,entry)
            _hbDrain!(pool)
            _hbUnadmit!(pool,lease.charge,lease.inputs)
        end
    end
end

function _hbClear!(pool=_HB_POOL)
    lock(pool.guard) do
        foreach(entry -> _hbRetire!(pool,entry),pool.order)
        _hbDrain!(pool)
    end
    nothing
end

function _hbRetireFont!(ot,pool=_HB_POOL)
    lock(pool.guard) do
        entry = get(pool.faces,objectid(ot),nothing)
        entry !== nothing && entry.owner.value !== ot && (entry = nothing)
        entry === nothing || _hbRetire!(pool,entry)
        _hbDrain!(pool)
    end
    nothing
end

"""Exact owned duplicated-blob payload/counts, NOT opaque HarfBuzz heap or RSS."""
function _hbUsage(pool=_HB_POOL)
    lock(pool.guard) do
        _hbDrain!(pool)
        (;blob_bytes=pool.blob_bytes,peak_blob_bytes=pool.peak_blob_bytes,
          blob_budget=pool.blob_budget,faces=length(pool.order),face_budget=pool.face_budget,
          active_users=sum(e -> e.users,pool.order;init=0),hits=pool.hits,misses=pool.misses,
          evictions=pool.evictions,closes=pool.closes,creates=pool.creates,
          rotations=pool.rotations,face_use_limit=pool.face_use_limit,
          epochs=[(;epoch=e.epoch,uses=e.uses,users=e.users,retired=e.retired[]) for e in pool.order],
          active_calls=pool.admission.active_calls,active_call_limit=pool.admission.active_call_limit,
          peak_active_calls=pool.admission.peak_active_calls,
          shape_work_charge=pool.admission.shape_work_charge,
          shape_work_budget=pool.admission.shape_work_budget,
          peak_shape_work_charge=pool.admission.peak_shape_work_charge,
          active_inputs=pool.admission.active_inputs,peak_active_inputs=pool.admission.peak_active_inputs,
          live_buffers=pool.admission.live_buffers,peak_live_buffers=pool.admission.peak_live_buffers,
          buffer_creates=pool.admission.buffer_creates,buffer_destroys=pool.admission.buffer_destroys,
          global_active_calls=_HB_GLOBAL.active_calls,
          global_shape_work_charge=_HB_GLOBAL.shape_work_charge,
          language_keys=length(_HB_LANGUAGES),
          language_key_bytes=sum(ncodeunits,keys(_HB_LANGUAGES);init=0),
          language_key_limit=256,language_key_byte_limit=63,
          language_rejections=_HB_LANGUAGE_REJECTIONS[],generation=_HB_GENERATION[])
    end
end
