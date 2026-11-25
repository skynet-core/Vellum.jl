# libwayland's generated inline requests ultimately use this array ABI. Each
# wl_argument occupies one pointer-sized union, with integers in its first 4 bytes.
wl_argument(x::Ptr) = UInt(x)
function wl_argument(x::Integer)
    word = UInt(reinterpret(UInt32,Cint(x)))
    ENDIAN_BOM == 0x04030201 ? word : word << (Sys.WORD_SIZE-32)
end

"""Wayland client entry points and protocol interfaces used by the shared-memory presenter."""
const CLIENT_SYMBOLS = (:wl_proxy_get_version, :wl_display_get_error, :wl_proxy_marshal_array_flags,
                        :wl_proxy_add_listener, :wl_shm_pool_interface, :wl_buffer_interface)
"""Native pointers held for the lifetime of the Julia-packaged Wayland client."""
const ClientSymbols = NamedTuple{CLIENT_SYMBOLS,NTuple{length(CLIENT_SYMBOLS),Ptr{Cvoid}}}
"""Lazy symbol table protected by the presenter's initialization lock."""
const client_table = Ref{Union{Nothing,ClientSymbols}}(nothing)

"""Resolve the optional client once, and publish its entry points only after all symbols are available."""
function client_symbols()
    lock(shm_guard) do
        if isnothing(client_table[])
            id = Base.PkgId(Base.UUID("a2964d1f-97da-50d4-b82a-358c7fce9d89"),"Wayland_jll")
            provider = Vellum._require_provider(id)
            handle = Base.invokelatest(getproperty,provider,:libwayland_client_handle)
            client_table[] = ClientSymbols(map(name->Libdl.dlsym(handle,name),CLIENT_SYMBOLS))
        end
        return client_table[]::ClientSymbols
    end
end

wl_version(proxy) = ccall(client_symbols().wl_proxy_get_version,UInt32,(Ptr{Cvoid},),proxy)
wl_error(display) = ccall(client_symbols().wl_display_get_error,Cint,(Ptr{Cvoid},),display)
function wl_request(proxy, opcode, args...; interface=C_NULL, destroy=false)
    words = UInt[wl_argument(x) for x in args]
    ccall(client_symbols().wl_proxy_marshal_array_flags,Ptr{Cvoid},
          (Ptr{Cvoid},UInt32,Ptr{Cvoid},UInt32,UInt32,Ptr{UInt}),
          proxy,opcode,interface,wl_version(proxy),destroy,words)
end

mutable struct ShmSlot
    buffer::Ptr{Cvoid}
    size::NTuple{2,Int}
    revision::Union{UInt64,Nothing}
    busy::Bool
    releases::UInt64
end
ShmSlot() = ShmSlot(C_NULL,(0,0),nothing,false,0)

function buffer_released(user::Ptr{Cvoid},buffer::Ptr{Cvoid})::Cvoid
    slot = unsafe_pointer_to_objref(user)::ShmSlot
    if slot.buffer == buffer && slot.busy
        slot.busy = false
        slot.releases += 1
    end
    return nothing
end

mutable struct ShmPresenter <: Presenter
    display::Ptr{Cvoid}
    surface::Ptr{Cvoid}
    pool::Ptr{Cvoid}
    data::Vector{UInt32}
    limit::NTuple{2,Int}
    slots::NTuple{2,ShmSlot}
    listener::Base.RefValue{Ptr{Cvoid}}
    owner::Int
    detached::Bool
    last::Int
    commits::UInt64
    objects::UInt64
    copied::UInt64
    damage::NTuple{4,Int}
end

# Native listeners can fire between Julia calls. Keep both the slots and their
# callback pointers alive until explicit close, and reserve each surface once.
const shm_bindings = Dict{Ptr{Cvoid},ShmPresenter}()
const shm_guard = ReentrantLock()

"""
    Presenter(display, shm, surface; max_size) -> Presenter

Present CPU images on a configured Linux Wayland surface using the packaged
Wayland client and two shared-memory buffers. Supply live pointers from the
same display and keep them alive through close. Dispatch the host's Wayland
queue on the creating thread to receive buffer releases. After `detach!`,
dispatch outstanding releases and close the presenter.
"""
function Presenter(display::Ptr{Cvoid}, shm::Ptr{Cvoid}, surface::Ptr{Cvoid}; max_size::Tuple{Integer,Integer})
    all(!=(C_NULL),(display,shm,surface)) || throw(ArgumentError("Wayland handles must be non-null"))
    all(1 .<= max_size .<= MAX_EXTENT) || throw(ArgumentError("Wayland SHM extent outside profile"))
    limit = Int.(max_size)
    bytes = 2prod(limit)*sizeof(UInt32)
    lock(shm_guard) do
        haskey(shm_bindings,surface) && throw(ArgumentError("Wayland surface already has a presenter"))
        wl_error(display)==0 || error("Wayland display connection has failed")
        mktemp() do _, io
            truncate(io,bytes)
            mapped = ccall(:mmap,Ptr{Cvoid},(Ptr{Cvoid},Csize_t,Cint,Cint,Cint,Int64),
                           C_NULL,bytes,3,1,fd(io),0) # PROT_READ|PROT_WRITE, MAP_SHARED
            mapped == Ptr{Cvoid}(typemax(UInt)) && Base.systemerror("mmap",true)
            pool = C_NULL
            try
                pool = wl_request(shm,0,C_NULL,Base.cconvert(Cint,fd(io)),bytes;interface=client_symbols().wl_shm_pool_interface)
                pool == C_NULL && error("Wayland SHM pool allocation failed")
                data = unsafe_wrap(Vector{UInt32},Ptr{UInt32}(mapped),bytes÷4)
                listener = Ref(@cfunction(buffer_released,Cvoid,(Ptr{Cvoid},Ptr{Cvoid})))
                presenter = ShmPresenter(display,surface,pool,data,limit,(ShmSlot(),ShmSlot()),listener,
                                         Threads.threadid(),false,0,0,0,0,(0,0,0,0))
                shm_bindings[surface] = presenter
                return presenter
            catch
                pool == C_NULL || wl_request(pool,1;destroy=true)
                ccall(:munmap,Cint,(Ptr{Cvoid},Csize_t),mapped,bytes)
                rethrow()
            end
        end
    end
end

function require_open(p::ShmPresenter)
    Threads.threadid()==p.owner || throw(ArgumentError("wrong Wayland SHM owner thread"))
    p.pool != C_NULL || throw(ArgumentError("Wayland SHM presenter is closed"))
end

function prepare_buffer!(p::ShmPresenter, index, size)
    slot = p.slots[index]
    slot.size == size && return
    w,h = size
    buffer = wl_request(p.pool,0,C_NULL,4(index-1)*prod(p.limit),w,h,4w,0;
                        interface=client_symbols().wl_buffer_interface)
    buffer == C_NULL && error("Wayland buffer allocation failed")
    status = ccall(client_symbols().wl_proxy_add_listener,Cint,
                   (Ptr{Cvoid},Ref{Ptr{Cvoid}},Ptr{Cvoid}),buffer,p.listener,pointer_from_objref(slot))
    if status != 0
        wl_request(buffer,0;destroy=true)
        error("Wayland buffer listener registration failed")
    end
    slot.buffer == C_NULL || wl_request(slot.buffer,0;destroy=true)
    slot.buffer,slot.size,slot.revision = buffer,size,nothing
    p.objects += 1
end

function present!(p::ShmPresenter,source::CPUSurface,revision::Integer;
                  damage::Union{Nothing,Tuple{Integer,Integer,Integer,Integer}}=nothing)
    require_open(p)
    p.detached && throw(ArgumentError("Wayland SHM presenter is detached"))
    0 <= revision <= typemax(UInt64) || throw(ArgumentError("invalid Wayland revision"))
    wl_error(p.display)==0 || error("Wayland display connection has failed")
    lock(source.guard) do
        source.valid[] || throw(ArgumentError("source surface is invalid"))
        im = source.image
        w,h = im.width,im.height
        all((w,h) .<= p.limit) || throw(ArgumentError("image exceeds the mapped extent"))
        full = (0,0,w,h)
        x,y,dw,dh = isnothing(damage) ? full : damage
        0 <= x < w && 0 <= y < h && 0 < dw <= w-x && 0 < dh <= h-y ||
            throw(ArgumentError("invalid Wayland damage rectangle"))
        region = Int.((x,y,dw,dh))
        prev = p.last == 0 ? nothing : p.slots[p.last]
        if prev !== nothing
            revision == prev.revision && prev.size == (w,h) && return :unchanged
            revision > prev.revision || throw(ArgumentError("stale Wayland revision"))
        end
        # Prefer the last buffer after release so consecutive edits can copy only damage.
        index = prev !== nothing && !prev.busy ? p.last : findfirst(s->!s.busy,p.slots)
        isnothing(index) && return :busy
        incremental = prev !== nothing && revision-prev.revision == 1 && prev.size == (w,h)
        changed = incremental ? region : full
        staged = incremental && index == p.last ? changed : full
        prepare_buffer!(p,index,(w,h))
        slot = p.slots[index]
        x,y,dw,dh = staged
        base = (index-1)*prod(p.limit)
        for j in y:y+dh-1, i in x:x+dw-1
            c = im[j+1,i+1]
            p.data[base+j*w+i+1] = UInt32(c.a)<<24 | UInt32(c.r)<<16 | UInt32(c.g)<<8 | UInt32(c.b)
        end
        wl_request(p.surface,1,slot.buffer,0,0)
        if wl_version(p.surface) >= 4
            wl_request(p.surface,9,changed...)
        else
            wl_request(p.surface,2,0,0,typemax(Cint),typemax(Cint))
        end
        wl_request(p.surface,6)
        slot.busy,slot.revision = true,UInt64(revision)
        p.last,p.damage = index,changed
        p.commits += 1
        p.copied += dw*dh
        return :accepted
    end
end

function detach!(p::ShmPresenter)
    require_open(p)
    if !p.detached
        wl_request(p.surface,1,C_NULL,0,0)
        wl_request(p.surface,6)
        p.detached = true
    end
    return nothing
end

function statistics(p::ShmPresenter)
    require_open(p)
    slot = p.last == 0 ? nothing : p.slots[p.last]
    w,h = isnothing(slot) ? (0,0) : slot.size
    revision = isnothing(slot) ? 0 : slot.revision
    releases = sum(s->s.releases,p.slots)
    values = (revision,p.commits,4p.copied,releases,count(s->s.busy,p.slots),sizeof(p.data),
              p.objects,w,h,p.detached,p.damage...,p.copied,max(0,p.last-1),
              wl_error(p.display)!=0,wl_version(p.surface)>=4)
    return NamedTuple{STATS}(UInt64.(values))
end

function capture(p::ShmPresenter)
    require_open(p)
    p.last > 0 || throw(ArgumentError("no Wayland SHM buffer has been offered"))
    w,h = p.slots[p.last].size
    image = Vellum.Image(w,h)
    offset = (p.last-1)*prod(p.limit)
    for i in 1:w*h
        pixel = p.data[offset+i]
        image[i] = Vellum.ColorRGBX((pixel>>16)%UInt8,(pixel>>8)%UInt8,pixel%UInt8,(pixel>>24)%UInt8)
    end
    return image
end

function Base.close(p::ShmPresenter)
    Threads.threadid()==p.owner || throw(ArgumentError("wrong Wayland SHM owner thread"))
    p.pool == C_NULL && return nothing
    if wl_error(p.display)==0 && (!p.detached || any(s->s.busy,p.slots))
        throw(ArgumentError("detach and dispatch Wayland buffer releases before close"))
    end
    for slot in p.slots
        slot.buffer == C_NULL || wl_request(slot.buffer,0;destroy=true)
        slot.buffer = C_NULL
    end
    wl_request(p.pool,1;destroy=true)
    ccall(:munmap,Cint,(Ptr{Cvoid},Csize_t),p.data,sizeof(p.data))
    p.pool,p.data = C_NULL,UInt32[]
    lock(shm_guard) do
        delete!(shm_bindings,p.surface)
    end
    return nothing
end
