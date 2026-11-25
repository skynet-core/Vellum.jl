# Private byte identities keep untrusted resource names out of public model keys.
resourcekey(ref::V.ResourceRef) = (ref.canvas,ref.id,ref.revision,valid_name(namebytes(ref.kind)))
const PATH_PREFIX = codeunits("VTRW\0PathData\0v1\0")
payloadtag(p) = p isa Union{V.ImageData,V.RasterReference} ? 1 : p isa V.FontData ? 2 : p isa V.PathData ? 3 : 0
descriptor(p::V.PathData, address) = (:path,address)
function raw(p::V.PathData)
    writer = Writer()
    pathwrite(writer,p)
    V.FrozenBytes(take!(writer.io))
end
blobdigest(domain,bytes) = domain == 0 ? Tuple(sha256(bytes))::Digest :
    Tuple(sha256(vcat(PATH_PREFIX,bytes)))::Digest
payloadaddress(p,data) = (UInt8(p isa V.PathData ? 1 : 0),
    p isa V.PathData ? blobdigest(1,codeunits(data.bytes)) : fingerprint(data))
function addresswrite(w,address)
    w.typed && put(w,address[1])
    check(w.typed || address[1] == 0, "unnegotiated blob domain")
    putbytes(w,collect(address[2]))
end
function addressread(r)
    domain = r.typed ? number(r,UInt8) : UInt8(0)
    check(domain in (0,1), "unknown blob domain")
    (domain,hashread(r))
end
function keyread(r,canvas)
    keycanvas,id,revision = number(r,UInt64),number(r,UInt64),number(r,UInt64)
    tag = number(r,UInt8)
    check(tag in (1,2) || tag == 3 && r.typed, "unknown resource kind tag")
    name = tag == 1 ? "image" : tag == 2 ? "font" : nameread(r)
    check(tag != 3 || !(name in ("image","font")), "noncanonical literal resource kind")
    if r.typed && tag != 3
        check(ncodeunits(name) <= r.items, "kind byte work limit")
        r.items -= ncodeunits(name)
    end
    check(keycanvas == canvas && id > 0 && revision > 0, "invalid resource identity")
    (keycanvas,id,revision,name)
end
function resource_requirements(resources)
    mask = PROFILE
    for (key,p) in resources
        check(payloadtag(p) != 0, "unsupported resource payload")
        if p isa V.RasterReference
            check(key[4] == "image", "external raster requires image kind")
            mask |= RASTER_ASSETS
        end
        (p isa V.PathData || p isa V.ImageData && key[4] != "image" ||
         p isa V.FontData && key[4] != "font") && (mask |= TYPED)
    end
    mask
end
function resource_work(resources,typed)
    items = 2length(resources)
    for (key,p) in resources
        items += (p isa V.PathData ? length(p.commands) : 0) + (typed ? ncodeunits(key[4]) : 0)
        check(items <= MAX_ITEMS, "reconstructed resource work limit")
    end
    items
end
"""
    validate_history!(history, known, key, desc, previous)

Preserve immutable resource identity, kind, payload and revision across a
candidate. Reject stale or conflicting resources before growing history.
"""
function validate_history!(history,known,key,desc,previous)
    for (old,description) in history
        if old[2] == key[2]
            check(old[4] == key[4], "resource ID changed kind")
            check(description[1] == desc[1], "resource ID changed payload type")
        end
    end
    if haskey(history,key)
        check(history[key] == desc, "immutable resource revision conflict")
    elseif previous !== nothing
        check(all(old->old[2] != key[2] || old[3] < key[3],keys(known)), "missing/retired resource revision")
    end
    history[key] = desc
    check(length(history) <= MAX_HISTORY, "resource history limit; start a new snapshot")
    return nothing
end

struct PendingSnapshot
    canvas::UInt64
    revision::UInt64
    size::NTuple{2,Float64}
    roots::Tuple
    resources::Vector{Tuple{ResourceKey,V.ResourcePayload}}
    hashes::Dict{ResourceKey,Address}
    blobs::Dict{Address,V.FrozenBytes}
    history::Dict{ResourceKey,Tuple}
    known_refs::Dict{ResourceKey,V.ResourceRef}
    nodes::Dict{UInt64,V.SemanticNode}
    max_node::UInt64
    metadata::Tuple
end
function validate_candidate(canvas,revision,size,roots,resources,previous,metadata,required;
                            addresses=nothing,stored=nothing,bindings=nothing)
    check(canvas > 0 && all(x->isfinite(x) && x>0,size), "invalid canvas/size")
    check(length(resources) <= MAX_RESOURCES, "resource count limit")
    check(previous === nothing || canvas == previous.frame.canvas &&
          revision > previous.frame.revision, "canvas/revision conflict")
    allnodes = tree_nodes(roots)
    items = resource_work(resources,required & TYPED != 0)
    check((resource_requirements(resources) | requirements_nodes(roots)) & ~required == 0,
          "candidate lacks required capabilities")
    known = previous === nothing ? Dict{ResourceKey,V.ResourceRef}() :
        Dict{ResourceKey,V.ResourceRef}(resourcekey(ref)=>ref for ref in keys(previous.history))
    history = previous === nothing ? Dict{ResourceKey,Tuple}() :
        Dict{ResourceKey,Tuple}(resourcekey(ref)=>desc for (ref,desc) in previous.history)
    old_records = previous === nothing ? Dict{ResourceKey,V.ResourcePayload}() :
        Dict{ResourceKey,V.ResourcePayload}(resourcekey(r.reference)=>r.payload for r in previous.frame.resources)
    hashes = Dict{ResourceKey,Address}()
    blobs = Dict{Address,V.FrozenBytes}()
    records = Dict{ResourceKey,V.ResourcePayload}()
    descriptions = Set{Tuple}()
    materialized = resident = 0
    for (key,p) in resources
        check(key[1] == canvas && key[2] > 0 && key[3] > 0, "invalid resource identity")
        valid_name(key[4])
        check(!haskey(records,key), "duplicate resource revision")
        valid_payload(p)
        shared = previous !== nothing && get(old_records,key,nothing) === p
        if p isa V.RasterReference
            check(bindings !== nothing && haskey(bindings,key), "missing raster binding")
            binding = bindings[key]
            check(binding.descriptor == p, "raster descriptor mismatch")
            desc = (:raster,asset_key(p),p.metadata,binding.root)
            validate_history!(history,known,key,desc,previous)
            records[key] = p
            continue
        end
        if addresses !== nothing
            address = addresses[key]
            data = stored[address]
        elseif shared
            address = previous.hashes[known[key]]
            data = previous.blobs[address]
        else
            retained = previous === nothing ? nothing : findfirst(r->r.payload === p,previous.frame.resources)
            if retained === nothing
                data = raw(p)
                address = payloadaddress(p,data)
                if previous !== nothing && haskey(previous.blobs,address)
                    data = previous.blobs[address]
                end
            else
                address = previous.hashes[previous.frame.resources[retained].reference]
                data = previous.blobs[address]
            end
        end
        desc = descriptor(p,address)
        if !(desc in descriptions)
            materialized += length(data)
            check(materialized <= MAX_MESSAGE, "materialized resource budget")
            push!(descriptions,desc)
        end
        validate_history!(history,known,key,desc,previous)
        if !haskey(blobs,address)
            resident += length(data)
            check(resident <= MAX_MESSAGE, "resident blob budget")
            blobs[address] = data
        end
        hashes[key],records[key] = address,p
    end
    nodes = Dict{UInt64,V.SemanticNode}()
    max_node = previous === nothing ? UInt64(0) : previous.max_node
    for node in allnodes
        items += nodework(node;names=required & NAME_BYTES != 0)
        check(items <= MAX_ITEMS, "reconstructed frame complexity budget")
        valid_node(node,records,canvas)
        if previous !== nothing
            old = get(previous.nodes,node.id,nothing)
            check(old === nothing ? node.id > previous.max_node :
                  node === old || node.revision > old.revision, "node revision/history conflict")
        end
        nodes[node.id] = node
        max_node = max(max_node,node.id)
    end
    PendingSnapshot(canvas,revision,size,Tuple(roots),resources,hashes,blobs,history,known,nodes,
                    max_node,optional_metadata(metadata))
end
function materialize(candidate,refs;frame=nothing,ownership=nothing)
    if frame === nothing
        resources = Tuple(V.ResourceRecord(refs[key],p) for (key,p) in candidate.resources)
        frame = V.Frame(1,candidate.canvas,candidate.revision,candidate.size,candidate.roots,resources)
    end
    Snapshot(frame,Dict(refs[key]=>value for (key,value) in candidate.hashes),candidate.blobs,
        Dict(refs[key]=>value for (key,value) in candidate.history),candidate.nodes,
        candidate.max_node,candidate.metadata,ownership)
end
