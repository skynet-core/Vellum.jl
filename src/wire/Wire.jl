module Wire
import Vellum
using SHA
const V = Vellum

export Snapshot, encode_snapshot, decode_snapshot, encode_delta, apply_delta
export fork_canvas
export symbol_admission_usage, configure_symbol_admission!

const MAX_MESSAGE = 32*1024*1024
const MAX_BLOB = 16*1024*1024
const MAX_NODES = 1024
const MAX_RESOURCES = 128
const MAX_HISTORY = 4096
const MAX_ITEMS = 16384
const MAX_PATH = 4096
const MAX_METADATA = 4096
const PROFILE = UInt32(1)
const TEXT_PROFILE = UInt32(3)
const GRADIENT = UInt32(4)
const NAME_BYTES = UInt32(8)
const GROUP = UInt32(16)
const BLUR = UInt32(32)
const TYPED = UInt32(64)
"""VTRW 1.6 capability for separately admitted, immutable raster revisions."""
const RASTER_ASSETS = UInt32(128)
"""Capability mask available through VTRW 1.5."""
const LEGACY_CAPABILITIES = UInt32(127)
const CAPABILITIES = LEGACY_CAPABILITIES | RASTER_ASSETS
const MAX_DEPTH = 16
const MAX_STOPS = 256
const PAINT_SPACES = (:local,:canvas)
const MAX_TEXT = 8192
const MAX_GLYPHS = 4096
# Fixed wire vocabulary: never intern names supplied by an untrusted peer.
const SCRIPTS = (:auto,:Latn,:Arab,:Hebr,:Deva,:Hani,:Cyrl,:Grek,:Zyyy,:Zinh)
const FEATURES = (:kern,:liga,:clig,:calt,:rlig,:mark,:mkmk,:ccmp,:locl,:curs,
                  :dlig,:hlig,:smcp,:c2sc,:onum,:lnum,:tnum,:pnum,:frac,:zero,
                  :noliga,:nokern)
const Digest = NTuple{32,UInt8}
const Address = Tuple{UInt8,Digest}
const ResourceKey = Tuple{UInt64,UInt64,UInt64,String}
const KINDS = (:image,:font)
const PATHS = (:move,:line,:quad,:cubic,:close)
const ARITY = (2,2,4,6,0)
const BLENDS = (:source_over,:multiply)
const SPACES = (:srgb,:linear_srgb)
const PROFILES = (:portable2d,:linear_light)
const SAMPLING = (:nearest,:linear)
const CAPS = (:butt,:round,:square)
const JOINS = (:miter,:round,:bevel)
const BASELINES = (:top,:hanging,:middle,:alphabetic,:ideographic,:bottom)
const ALIGNS = (:left,:center,:right)
const DIRECTIONS = (:ltr,:rtl)
const WINDINGS = (:nonzero,:evenodd)

check(ok, message) = ok || throw(ArgumentError("wire: "*message))
include("SymbolAdmission.jl")

struct PendingText <: V.SemanticOperation
    text::String
    position::NTuple{2,Float64}
    state::V.DrawingState
    glyphs::Tuple
    language::String
    script::String
    features::Tuple
    fallback_fonts::Tuple
end
namebytes(s::Symbol) = String(s)
namebytes(s::String) = s
featuretag(f) = f isa Tuple ? f[1] : f
istext(op) = op isa Union{V.TextRun,PendingText}
function valid_name(s)
    check(ncodeunits(s) <= 256 && !any(==(0x00),codeunits(s)), "invalid name bytes")
    s
end
function valid_text_names(op)
    valid_name(namebytes(op.script))
    seen = Set{String}()
    for f in op.features
        pair = f isa Tuple
        tagtype = op isa PendingText ? String : Symbol
        check(pair ? length(f) == 2 && f[1] isa tagtype && f[2] isa Integer && f[2] in (0,1) :
                     f isa tagtype, "invalid feature representation")
        name = valid_name(namebytes(featuretag(f)))
        if pair
            check(ncodeunits(name) == 4 && all(b->0x41 <= b <= 0x5a || 0x61 <= b <= 0x7a,codeunits(name)),
                  "invalid feature pair tag")
        end
        check(!(name in seen), "duplicate feature tag")
        push!(seen,name)
    end
end
namework(op) = ncodeunits(namebytes(op.script)) +
    sum(f->ncodeunits(namebytes(featuretag(f))),op.features;init=0)
oldnames(op) = op.script in SCRIPTS && all(f->featuretag(f) in FEATURES,op.features)
fingerprint(bytes::V.FrozenBytes) = Tuple(sha256(codeunits(bytes.bytes)))::Digest
raw(payload::V.ImageData) = payload.pixels
raw(payload::V.FontData) = payload.data

"""
    AssetBinding(descriptor, root)

Identify one complete archival raster revision by its portable descriptor
and canonical manifest SHA-256 root.
"""
struct AssetBinding
    descriptor::V.RasterReference
    root::Digest
end

"""Private extension point for the owning lease on an external-resource snapshot."""
abstract type SnapshotAssetOwnership end

"""
    snapshot_bindings(previous)

Return the owned exact-binding table, or nothing for an empty or dense base.
An explicitly closed external snapshot raises ArgumentError.
"""
snapshot_bindings(::Nothing) = nothing
descriptor(p::V.ImageData, hash) = (:image,p.width,p.height,hash)
descriptor(p::V.FontData, hash) = (:font,p.family,hash)

"""
    Snapshot(frame; metadata=(), assets=nothing)

Own an immutable Frame and private transport caches. Frames publishing
external raster revisions require an open RasterAssetResolver through
`assets`. Do not mutate the caches. Close the snapshot to release its
external revisions. The Frame itself is portable and non-owning.
"""
struct Snapshot
    frame::V.Frame
    hashes::Dict{V.ResourceRef,Address}
    blobs::Dict{Address,V.FrozenBytes}
    history::Dict{V.ResourceRef,Tuple}
    nodes::Dict{UInt64,V.SemanticNode}
    max_node::UInt64
    metadata::Tuple
    assets::Union{Nothing,SnapshotAssetOwnership}
end

"""Construct a self-contained Snapshot using the legacy cache constructor."""
Snapshot(frame,hashes,blobs,history,nodes,max_node,metadata) =
    Snapshot(frame,hashes,blobs,history,nodes,max_node,metadata,nothing)

snapshot_bindings(state::Snapshot) = state.assets === nothing ? nothing : owned_bindings(state.assets)

"""
    close(snapshot::Snapshot)

Release this snapshot's external raster leases. Repeated calls and
self-contained snapshots are harmless. Archive cleanup errors propagate.
"""
Base.close(snapshot::Snapshot) = close_snapshot_assets(snapshot.assets)
close_snapshot_assets(::Nothing) = nothing

"""
    with_snapshot_assets(body, ownership)

Transfer ownership to the returned snapshot on success. Release it if body
throws, preserving both the original failure and any cleanup failure.
"""
function with_snapshot_assets(body,ownership)
    try
        body()
    catch error
        try
            close_snapshot_assets(ownership)
        catch cleanup
            throw(CompositeException(Any[error,cleanup]))
        end
        rethrow()
    end
end

function reference(ref, canvas, kind=ref.kind)
    check(ref.canvas == canvas && ref.id > 0 && ref.revision > 0 &&
          ref.kind in KINDS && ref.kind === kind, "invalid resource identity/kind")
end

function valid_payload(p)
    if p isa V.ImageData
        check(p.width > 0 && p.height > 0 && p.width <= MAX_BLOB÷4÷p.height,
              "image exceeds blob limit")
        check((p.format,p.alpha,p.color_space,p.orientation,p.row_stride) ==
              (:rgba8,:premultiplied,:srgb,:top_left,4p.width), "unsupported image layout")
        check(length(p.pixels) == 4p.width*p.height, "image byte count")
    elseif p isa V.FontData
        check(isvalid(p.family) && ncodeunits(p.family) <= 256, "invalid font family")
        check(length(p.data) <= MAX_BLOB, "font exceeds blob limit")
    elseif p isa V.PathData
        check(length(p.commands) <= MAX_PATH, "path command limit")
    elseif p isa V.RasterReference
        asset_shape(p.metadata)
    else
        throw(ArgumentError("wire: unsupported resource $(typeof(p))"))
    end
end

function valid_node(node, records, canvas)
    check(node.id > 0 && node.revision > 0, "invalid node identity")
    op = node.operation
    if op isa V.CompositeGroup
        check(isfinite(op.opacity) && 0 <= op.opacity <= 1 && op.blend in BLENDS, "invalid group")
        check(op.effect === nothing || op.effect isa V.BoxBlur &&
              all(x->isfinite(x) && x >= 0,(op.effect.radius_x,op.effect.radius_y)), "invalid group effect")
        return
    end
    check(op isa Union{V.FillPath,V.StrokePath,V.ImageRegion,V.ClearRegion,V.TextRun,PendingText},
          "unsupported required operation $(typeof(op))")
    state = op.state
    for paint in (state.fill,state.stroke)
        check(paint isa Union{V.Solid,V.LinearGradient}, "unsupported paint")
        paint isa V.LinearGradient && check(1 <= length(paint.stops) <= MAX_STOPS, "gradient stop limit")
    end
    if state.font !== nothing
        reference(state.font,canvas,:font)
        check(haskey(records,resourcekey(state.font)), "missing font revision")
    end
    if istext(op)
        check(ncodeunits(op.text) <= MAX_TEXT && isvalid(op.text) &&
              ncodeunits(op.language) <= 256 && isvalid(op.language), "text UTF-8/string limit")
        check(length(op.glyphs) <= MAX_GLYPHS && length(op.features) <= 32 &&
              length(op.fallback_fonts) <= 16, "text count limit")
        check(all(isfinite,op.position), "text position")
        V.text_glyphs(op.text,op.glyphs)
        valid_text_names(op)
        check(state.font !== nothing, "text requires primary font")
        seen = Set{V.ResourceRef}()
        for ref in (state.font,op.fallback_fonts...)
            check(ref isa V.ResourceRef, "invalid fallback reference")
            reference(ref,canvas,:font)
            check(!(ref in seen) && get(records,resourcekey(ref),nothing) isa V.FontData,
                  "duplicate/missing text font revision")
            push!(seen,ref)
        end
    elseif op isa V.FillPath
        check(op.winding in WINDINGS, "invalid winding")
    elseif op isa V.ImageRegion
        reference(op.image,canvas,:image)
        check(haskey(records,resourcekey(op.image)), "missing image revision")
        p = records[resourcekey(op.image)]
        check(p isa Union{V.ImageData,V.RasterReference}, "image consumer requires ImageData or RasterReference")
        image = p isa V.RasterReference ? p.metadata : p
        x,y,w,h = op.source
        check(all(isfinite,op.source) && x >= 0 && y >= 0 && w >= 0 && h >= 0 &&
              x+w <= image.width && y+h <= image.height, "invalid image source")
        rectangle(op.destination)
    elseif op isa V.ClearRegion
        rectangle(op.rectangle)
    end
end

function rectangle(rect)
    check(all(isfinite,rect) && rect[3] >= 0 && rect[4] >= 0, "invalid rectangle")
    rect
end

function nodework(node; names=false)
    op = node.operation
    op isa V.CompositeGroup && return 2
    check(op isa Union{V.FillPath,V.StrokePath,V.ImageRegion,V.ClearRegion,V.TextRun,PendingText},
          "unsupported required operation $(typeof(op))")
    state = op.state
    items = 2+length(state.clips)+length(state.stroke_style.dashes)
    items += sum(c->length(c.path.commands),state.clips;init=0)
    items += sum(p->p isa V.LinearGradient ? length(p.stops) : 0,(state.fill,state.stroke))
    op isa Union{V.FillPath,V.StrokePath} && (items += length(op.path.commands))
    if istext(op)
        items += ncodeunits(op.text)+ncodeunits(op.language)+length(op.glyphs)+
                  length(op.features)+length(op.fallback_fonts)
        names && (items += namework(op))
    end
    items
end

# Identity is canvas-wide; iteration order is semantic, not identifier order.
function tree_nodes(roots)
    result = V.SemanticNode[]
    seen = Set{UInt64}()
    function visit(nodes, depth)
        isempty(nodes) && return
        check(depth <= MAX_DEPTH && length(nodes) <= MAX_NODES-length(result), "tree depth/node limit")
        for node in nodes
            check(node isa V.SemanticNode && !(node.id in seen), "duplicate/invalid tree node")
            check(length(result) < MAX_NODES, "tree node limit")
            push!(seen,node.id); push!(result,node)
            node.operation isa V.CompositeGroup && visit(node.operation.nodes,depth+1)
        end
    end
    visit(roots,1)
    result
end

function optional_metadata(values)
    check(length(values) <= 16, "too many metadata fields")
    seen = Set{UInt16}()
    total = 0
    Tuple(map(values) do item
        check(item isa Tuple && length(item) == 2 && item[1] isa UInt16 &&
              item[1] & 0x8000 != 0 && !(item[1] in seen), "invalid optional metadata tag")
        data = item[2]
        check(data isa Union{V.FrozenBytes,AbstractVector{UInt8}}, "metadata must be opaque bytes")
        total += length(data)
        check(total <= MAX_METADATA, "metadata byte limit")
        push!(seen,item[1])
        (item[1],data isa V.FrozenBytes ? data : V.FrozenBytes(data))
    end)
end

include("Resources.jl")

function build_snapshot(frame, previous, metadata; assets=nothing)
    check(frame.schema_version == 1 && frame.canvas > 0 &&
          all(x->isfinite(x) && x>0,frame.size), "invalid Frame schema/canvas/size")
    check(length(frame.nodes) <= MAX_NODES && length(frame.resources) <= MAX_RESOURCES,
          "frame complexity limit")
    check(all(r->r isa V.ResourceRecord,frame.resources), "invalid resource record")
    required = requirements(frame) | (previous === nothing ? PROFILE : requirements(previous))
    records = [(resourcekey(r.reference),r.payload) for r in frame.resources]
    snapshot_bindings(previous)
    ownership = required & RASTER_ASSETS == 0 ? nothing : admit_snapshot_assets(assets,records,nothing)
    with_snapshot_assets(ownership) do
        bindings = ownership === nothing ? nothing : owned_bindings(ownership)
        candidate = validate_candidate(frame.canvas,frame.revision,frame.size,frame.nodes,records,
                                       previous,metadata,required;bindings)
        refs = previous === nothing ? Dict{ResourceKey,V.ResourceRef}() :
            Dict(resourcekey(r)=>r for r in keys(previous.history))
        foreach(r->refs[resourcekey(r.reference)]=r.reference,frame.resources)
        materialize(candidate,refs;frame,ownership)
    end
end
Snapshot(frame::V.Frame; metadata=(), assets=nothing) = build_snapshot(frame,nothing,metadata;assets)

mutable struct Writer
    io::IOBuffer
    items::Int
    typed::Bool
end
Writer() = Writer(IOBuffer(maxsize=MAX_MESSAGE),MAX_ITEMS,false)
function charge!(w::Writer, n)
    check(0 <= n <= w.items, "complexity budget")
    w.items -= n
end
function put(w::Writer, x::Unsigned)
    check(sizeof(x) <= MAX_MESSAGE-position(w.io), "message byte limit")
    write(w.io,htol(x))
end
put(w::Writer, x::Float64) = (check(isfinite(x),"nonfinite number"); put(w,reinterpret(UInt64,x)))
function putbytes(w, bytes)
    check(length(bytes) <= MAX_MESSAGE-position(w.io), "message byte limit")
    write(w.io,bytes)
end
function enumeration(w, value, table)
    index = findfirst(==(value),table)
    check(index !== nothing, "unknown enum")
    put(w,UInt8(index))
end
function text(w, value, limit=256; charged=false)
    check(isvalid(value) && ncodeunits(value) <= limit, "UTF-8 string limit")
    charged && charge!(w,ncodeunits(value))
    put(w,UInt16(ncodeunits(value)))
    putbytes(w,codeunits(value))
end
function refwrite(w, ref)
    put(w,ref.canvas); put(w,ref.id); put(w,ref.revision)
    if w.typed
        name = valid_name(namebytes(ref.kind))
        charge!(w,ncodeunits(name))
        tag = ref.kind === :image ? 1 : ref.kind === :font ? 2 : 3
        put(w,UInt8(tag))
        if tag == 3
            put(w,UInt16(ncodeunits(name))); putbytes(w,codeunits(name))
        end
    else
        enumeration(w,ref.kind,KINDS)
    end
end
function pathwrite(w, path)
    check(length(path.commands) <= MAX_PATH, "path command limit")
    charge!(w,length(path.commands))
    put(w,UInt32(length(path.commands)))
    for command in path.commands
        enumeration(w,command[1],PATHS)
        foreach(x->put(w,Float64(x)),Base.tail(command))
    end
end
function colorwrite(w, color)
    foreach(x->put(w,x),color.channels)
    enumeration(w,color.space,SPACES)
end
function statewrite(w, s, gradients)
    for paint in (s.fill,s.stroke)
        gradients && put(w,UInt8(paint isa V.Solid ? 1 : 2))
        if paint isa V.Solid
            colorwrite(w,paint.color)
        else
            check(gradients && paint isa V.LinearGradient, "unnegotiated paint")
            foreach(x->put(w,x),(paint.start...,paint.stop...))
            enumeration(w,paint.space,PAINT_SPACES)
            foreach(x->put(w,x),paint.transform.coefficients)
            charge!(w,length(paint.stops))
            put(w,UInt32(length(paint.stops)))
            for stop in paint.stops
                put(w,stop.position); colorwrite(w,stop.color)
            end
        end
    end
    foreach(x->put(w,x),s.transform.coefficients)
    check(length(s.clips) <= 64, "clip limit")
    charge!(w,length(s.clips))
    put(w,UInt32(length(s.clips)))
    for clip in s.clips
        pathwrite(w,clip.path)
        foreach(x->put(w,x),clip.transform.coefficients)
        enumeration(w,clip.winding,WINDINGS)
    end
    put(w,s.opacity)
    enumeration(w,s.blend,BLENDS); enumeration(w,s.profile,PROFILES); enumeration(w,s.sampling,SAMPLING)
    st = s.stroke_style
    put(w,st.width); enumeration(w,st.cap,CAPS); enumeration(w,st.join,JOINS); put(w,st.miter_limit)
    check(length(st.dashes) <= 1024, "dash limit")
    charge!(w,length(st.dashes))
    put(w,UInt32(length(st.dashes)))
    foreach(x->put(w,x),st.dashes)
    put(w,st.dash_offset)
    put(w,UInt8(s.font !== nothing))
    s.font === nothing || refwrite(w,s.font)
    put(w,s.font_size)
    enumeration(w,s.baseline,BASELINES); enumeration(w,s.alignment,ALIGNS); enumeration(w,s.direction,DIRECTIONS)
end
function namewrite(w, value)
    bytes = valid_name(namebytes(value))
    charge!(w,ncodeunits(bytes))
    put(w,UInt16(ncodeunits(bytes))); putbytes(w,codeunits(bytes))
end
function nodewrite(w, node, expected, gradients, names, previous=nothing)
    put(w,expected); put(w,node.id); put(w,node.revision)
    op = node.operation
    tag = op isa V.FillPath ? 1 : op isa V.StrokePath ? 2 : op isa V.ImageRegion ? 3 :
          op isa V.ClearRegion ? 4 : op isa V.CompositeGroup ? 6 : 5
    put(w,UInt8(tag))
    if op isa V.CompositeGroup
        put(w,op.opacity); enumeration(w,op.blend,BLENDS)
        put(w,UInt8(op.effect === nothing ? 0 : 1))
        if op.effect !== nothing
            put(w,op.effect.radius_x); put(w,op.effect.radius_y)
        end
        charge!(w,length(op.nodes))
        put(w,UInt32(length(op.nodes)))
        for child in op.nodes
            old = previous === nothing ? nothing : get(previous.nodes,child.id,nothing)
            retained = child === old
            put(w,UInt8(retained ? 0 : 1))
            if retained
                charge!(w,sum(n->nodework(n;names),tree_nodes((child,))))
                put(w,child.id); put(w,child.revision)
            else
                nodewrite(w,child,old === nothing ? UInt64(0) : old.revision,gradients,names,previous)
            end
        end
        return
    end
    statewrite(w,op.state,gradients)
    if op isa Union{V.FillPath,V.StrokePath}
        pathwrite(w,op.path)
        op isa V.FillPath && enumeration(w,op.winding,WINDINGS)
    elseif op isa V.ImageRegion
        refwrite(w,op.image)
        foreach(x->put(w,x),(op.source...,op.destination...))
    elseif op isa V.TextRun
        text(w,op.text,MAX_TEXT;charged=true)
        foreach(x->put(w,x),op.position)
        text(w,op.language;charged=true)
        names ? namewrite(w,op.script) : enumeration(w,op.script,SCRIPTS)
        charge!(w,length(op.features)+length(op.fallback_fonts)+length(op.glyphs))
        put(w,UInt32(length(op.features)))
        for feature in op.features
            pair = feature isa Tuple
            put(w,UInt8(pair ? 2 : 1))
            names ? namewrite(w,featuretag(feature)) : enumeration(w,featuretag(feature),FEATURES)
            pair && put(w,UInt8(feature[2]))
        end
        put(w,UInt32(length(op.fallback_fonts)))
        foreach(ref->refwrite(w,ref),op.fallback_fonts)
        put(w,UInt32(length(op.glyphs)))
        for (id,x,y,cluster) in op.glyphs
            put(w,UInt32(id)); put(w,Float64(x)); put(w,Float64(y)); put(w,UInt32(cluster))
        end
    else
        foreach(x->put(w,x),op.rectangle)
    end
end

requirements(s::Snapshot) = requirements(s.frame)
function requirements(frame::V.Frame)
    requirements_nodes(frame.nodes) | resource_requirements((resourcekey(r.reference),r.payload) for r in frame.resources)
end
function requirements_nodes(nodes)
    mask = PROFILE
    for node in tree_nodes(nodes)
        op = node.operation
        if op isa V.CompositeGroup
            mask |= GROUP
            op.effect !== nothing && (mask |= BLUR)
            continue
        end
        check(op isa Union{V.FillPath,V.StrokePath,V.ImageRegion,V.ClearRegion,V.TextRun,PendingText},
              "unsupported required operation")
        if istext(op)
            valid_text_names(op)
            mask |= UInt32(2)
            (op isa PendingText || !oldnames(op)) && (mask |= NAME_BYTES)
        end
        state = node.operation.state
        (state.fill isa V.LinearGradient || state.stroke isa V.LinearGradient) && (mask |= GRADIENT)
    end
    mask
end
function encode(previous, next; capabilities::UInt32=CAPABILITIES)
    required = requirements(next) | (previous === nothing ? PROFILE : requirements(previous))
    gradients = required & GRADIENT != 0
    check(required & ~capabilities == 0, "receiver lacks required capabilities")
    w = Writer()
    w.typed = required & TYPED != 0
    putbytes(w,codeunits("VTRW"))
    names = required & NAME_BYTES != 0
    external = required & RASTER_ASSETS != 0
    bindings = snapshot_bindings(next)
    old_bindings = snapshot_bindings(previous)
    minor = external ? 6 : w.typed ? 5 : required & GROUP != 0 ? 4 :
        names ? 3 : gradients ? 2 : required == TEXT_PROFILE ? 1 : 0
    put(w,UInt16(1)); put(w,UInt16(minor)); put(w,required)
    put(w,UInt8(previous === nothing ? 1 : 2)); put(w,UInt8(0)); put(w,UInt16(0))
    f = next.frame
    put(w,f.canvas); put(w,previous === nothing ? UInt64(0) : previous.frame.revision); put(w,f.revision)
    foreach(x->put(w,x),f.size)
    transferred = sort!([hash for hash in keys(next.blobs) if previous === nothing || !haskey(previous.blobs,hash)])
    charge!(w,length(transferred))
    put(w,UInt32(length(transferred)))
    for hash in transferred
        addresswrite(w,hash)
        bytes = next.blobs[hash]
        put(w,UInt32(length(bytes)))
        putbytes(w,codeunits(bytes.bytes))
    end
    declarations = [r for r in f.resources if previous === nothing ||
        !(haskey(previous.hashes,r.reference) || old_bindings !== nothing &&
          haskey(old_bindings,resourcekey(r.reference)))]
    charge!(w,length(declarations))
    put(w,UInt32(length(declarations)))
    for r in declarations
        refwrite(w,r.reference)
        p = r.payload
        w.typed && put(w,UInt8(payloadtag(p)))
        if p isa V.RasterReference
            key = resourcekey(r.reference)
            check(external && bindings !== nothing && haskey(bindings,key), "missing owned raster binding")
            put(w,UInt8(2))
            putbytes(w,asset_body(io->binding_write(io,bindings[key])))
            continue
        elseif p isa V.ImageData
            external && put(w,UInt8(1))
            put(w,UInt32(p.width)); put(w,UInt32(p.height))
        elseif p isa V.FontData
            text(w,p.family)
        else
            check(w.typed && p isa V.PathData, "unnegotiated path resource")
            charge!(w,length(p.commands))
        end
        addresswrite(w,next.hashes[r.reference])
    end
    charge!(w,length(f.resources))
    put(w,UInt32(length(f.resources)))
    foreach(r->refwrite(w,r.reference),f.resources)
    changed = [node for node in f.nodes if previous === nothing || get(previous.nodes,node.id,nothing) !== node]
    charge!(w,length(changed))
    put(w,UInt32(length(changed)))
    for node in changed
        old = previous === nothing ? nothing : get(previous.nodes,node.id,nothing)
        nodewrite(w,node,old === nothing ? UInt64(0) : old.revision,gradients,names,previous)
    end
    charge!(w,length(f.nodes))
    put(w,UInt32(length(f.nodes)))
    foreach(node->put(w,node.id),f.nodes)
    put(w,UInt16(length(next.metadata)))
    for (tag,bytes) in next.metadata
        put(w,tag); put(w,UInt32(length(bytes))); putbytes(w,codeunits(bytes.bytes))
    end
    take!(w.io)
end
"""
    encode_snapshot(state::Snapshot; capabilities=CAPABILITIES, assets=nothing)

Encode a snapshot canonically. External resources require an explicit open
resolver with bindings matching the snapshot's owned leases.
"""
function encode_snapshot(state::Snapshot; capabilities::UInt32=CAPABILITIES, assets=nothing)
    if requirements(state) & RASTER_ASSETS != 0
        bindings = snapshot_bindings(state)
        check(bindings !== nothing,"snapshot lacks external raster ownership")
        verify_snapshot_assets(assets,bindings)
    end
    encode(nothing,state;capabilities)
end

"""
    encode_snapshot(frame::Frame; capabilities=CAPABILITIES, assets=nothing)

Encode a Frame with a temporary lease when it refers to external rasters.
The explicit resolver must already contain every complete revision.
"""
function encode_snapshot(frame::V.Frame; capabilities::UInt32=CAPABILITIES, assets=nothing)
    state = Snapshot(frame;assets)
    try
        encode(nothing,state;capabilities)
    finally
        close(state)
    end
end

"""
    encode_delta(previous, frame; metadata=(), capabilities=CAPABILITIES, assets=nothing)

Return the encoded delta and its independently owned successor Snapshot.
Use an explicit resolver for a delta involving external assets. Failure
does not change the previous snapshot or leak successor leases.
"""
function encode_delta(previous::Snapshot, frame::V.Frame; metadata=(), capabilities::UInt32=CAPABILITIES,
                      assets=nothing)
    next = build_snapshot(frame,previous,metadata;assets)
    with_snapshot_assets(next.assets) do
        (encode(previous,next;capabilities),next)
    end
end

mutable struct Reader
    bytes::Vector{UInt8}
    position::Int
    items::Int
    nodes::Int
    ids::Set{UInt64}
    typed::Bool
end
function Reader(bytes::Vector{UInt8})
    check(length(bytes) <= MAX_MESSAGE, "message byte limit")
    Reader(bytes,1,MAX_ITEMS,0,Set{UInt64}(),false)
end
remaining(r) = length(r.bytes)-r.position+1
function bytesread(r, n)
    check(0 <= n <= remaining(r), "truncated bytes")
    first = r.position
    r.position += n
    view(r.bytes,first:r.position-1)
end
function number(r, ::Type{T}) where T<:Unsigned
    bytes = bytesread(r,sizeof(T))
    value = zero(T)
    for (i,byte) in enumerate(bytes)
        value |= T(byte) << (8(i-1))
    end
    value
end
function realread(r)
    value = reinterpret(Float64,number(r,UInt64))
    check(isfinite(value), "nonfinite number")
    value
end
function enumread(r, table)
    index = number(r,UInt8)
    check(1 <= index <= length(table), "unknown required enum/tag")
    table[index]
end
function countread(r, limit, minimum)
    n = number(r,UInt32)
    check(n <= limit && n <= r.items && n <= remaining(r)÷minimum, "count/complexity/truncation limit")
    r.items -= Int(n)
    Int(n)
end
function stringread(r, limit=256; charged=false)
    n = number(r,UInt16)
    check(n <= limit, "UTF-8 string limit")
    if charged
        check(n <= r.items, "text byte complexity budget")
        r.items -= Int(n)
    end
    value = String(bytesread(r,Int(n)))
    check(isvalid(value), "invalid UTF-8")
    value
end
function nameread(r)
    n = number(r,UInt16)
    check(n <= 256 && n <= r.items, "name byte budget")
    r.items -= Int(n)
    valid_name(String(bytesread(r,Int(n))))
end
hashread(r) = Tuple(bytesread(r,32))::Digest
function refread(r, canvas, expected)
    key = keyread(r,canvas)
    kind = key[4] == "image" ? :image : key[4] == "font" ? :font : nothing
    check(kind !== nothing && kind === expected, "unsupported operation resource kind")
    ref = V.ResourceRef(key[1],key[2],key[3],kind)
    reference(ref,canvas)
    ref
end
function pathread(r)
    count = countread(r,MAX_PATH,1)
    commands = Tuple[]
    for _ in 1:count
        index = number(r,UInt8)
        check(1 <= index <= length(PATHS), "unknown path opcode")
        values = ntuple(_->realread(r),ARITY[index])
        push!(commands,(PATHS[index],values...))
    end
    V.PathData(commands)
end
transformread(r) = V.Transform2D(ntuple(_->realread(r),6)...)
function colorread(r)
    channels = ntuple(_->realread(r),4)
    V.Color(channels...;space=enumread(r,SPACES))
end
function paintread(r, gradients)
    tag = gradients ? number(r,UInt8) : UInt8(1)
    check(tag in (1,2), "unknown paint tag")
    tag == 1 && return V.Solid(colorread(r))
    start,stop = ntuple(_->realread(r),2),ntuple(_->realread(r),2)
    space = enumread(r,PAINT_SPACES)
    transform = transformread(r)
    count = countread(r,MAX_STOPS,41)
    check(count > 0, "empty gradient stops")
    stops = ntuple(_->V.GradientStop(realread(r),colorread(r)),count)
    V.LinearGradient(start,stop,stops;space,transform)
end
function stateread(r, canvas, gradients)
    fill,stroke = paintread(r,gradients),paintread(r,gradients)
    transform = transformread(r)
    clips = Tuple(V.CapturedClip(pathread(r),transformread(r),enumread(r,WINDINGS))
                  for _ in 1:countread(r,64,53))
    opacity = realread(r)
    blend,profile,sampling = enumread(r,BLENDS),enumread(r,PROFILES),enumread(r,SAMPLING)
    width,cap,join,miter = realread(r),enumread(r,CAPS),enumread(r,JOINS),realread(r)
    dashes = ntuple(_->realread(r),countread(r,1024,8))
    offset = realread(r)
    hasfont = number(r,UInt8)
    check(hasfont in (0,1), "invalid font flag")
    font = hasfont == 0 ? nothing : refread(r,canvas,:font)
    size = realread(r)
    baseline,alignment,direction = enumread(r,BASELINES),enumread(r,ALIGNS),enumread(r,DIRECTIONS)
    style = V.StrokeStyle(;width,cap,join,miter_limit=miter,dashes,dash_offset=offset)
    V.DrawingState(;fill,stroke,transform,clips,opacity,blend,profile,sampling,stroke_style=style,
                   font,font_size=size,baseline,alignment,direction)
end
function read_identity!(r,id,revision,depth)
    check(depth <= MAX_DEPTH && r.nodes < MAX_NODES, "tree depth/node limit")
    check(id > 0 && revision > 0 && !(id in r.ids), "duplicate/invalid tree identity")
    r.nodes += 1
    push!(r.ids,id)
end
function retained_tree!(r,node,depth,required)
    read_identity!(r,node.id,node.revision,depth)
    work = nodework(node;names=required & NAME_BYTES != 0)
    check(work <= r.items, "retained tree work limit")
    r.items -= work
    if node.operation isa V.CompositeGroup
        for child in node.operation.nodes
            retained_tree!(r,child,depth+1,required)
        end
    end
    node
end
function noderead(r, canvas, required, previous=nothing, depth=1)
    expected,id,revision = number(r,UInt64),number(r,UInt64),number(r,UInt64)
    read_identity!(r,id,revision,depth)
    tag = number(r,UInt8)
    if tag == 6
        check(required & GROUP != 0, "unnegotiated group")
        opacity,blend = realread(r),enumread(r,BLENDS)
        check(0 <= opacity <= 1, "invalid group opacity")
        effecttag = number(r,UInt8)
        check(effecttag == 0 || effecttag == 1 && required & BLUR != 0, "unsupported/unnegotiated effect")
        effect = effecttag == 0 ? nothing : V.BoxBlur(realread(r),realread(r))
        count = countread(r,MAX_NODES-r.nodes,17)
        check(count == 0 || depth < MAX_DEPTH, "tree depth limit")
        children = V.SemanticNode[]
        for _ in 1:count
            form = number(r,UInt8)
            check(form in (0,1), "unknown child form")
            if form == 0
                childid,childrev = number(r,UInt64),number(r,UInt64)
                old = previous === nothing ? nothing : get(previous.nodes,childid,nothing)
                check(old !== nothing && old.revision == childrev, "retained child revision conflict")
                push!(children,retained_tree!(r,old,depth+1,required))
            else
                childexpected,child = noderead(r,canvas,required,previous,depth+1)
                old = previous === nothing ? nothing : get(previous.nodes,child.id,nothing)
                check(old === nothing ? childexpected == 0 :
                      childexpected == old.revision && child.revision > childexpected, "child expected revision conflict")
                push!(children,child)
            end
        end
        return expected,V.SemanticNode(id,revision,V.CompositeGroup(Tuple(children),opacity,blend,effect))
    end
    check(tag in 1:4 || tag == 5 && required & UInt32(2) != 0, "unknown/unnegotiated required operation")
    state = stateread(r,canvas,required & GRADIENT != 0)
    op = if tag in (1,2)
        path = pathread(r)
        tag == 1 ? V.FillPath(path,state,enumread(r,WINDINGS)) : V.StrokePath(path,state)
    elseif tag == 3
        ref = refread(r,canvas,:image)
        source = ntuple(_->realread(r),4)
        V.ImageRegion(ref,source,ntuple(_->realread(r),4),state)
    elseif tag == 5
        content = stringread(r,MAX_TEXT;charged=true)
        position = ntuple(_->realread(r),2)
        language = stringread(r;charged=true)
        names = required & NAME_BYTES != 0
        script = names ? nameread(r) : enumread(r,SCRIPTS)
        features = ntuple(countread(r,32,2)) do _
            form = number(r,UInt8)
            check(form in (1,2), "unknown feature representation")
            tag = names ? nameread(r) : enumread(r,FEATURES)
            if form == 1
                tag
            else
                value = number(r,UInt8)
                check(value in (0,1), "invalid feature value")
                (tag,Int(value))
            end
        end
        fallbacks = ntuple(_->refread(r,canvas,:font),countread(r,16,25))
        glyphs = ntuple(countread(r,MAX_GLYPHS,24)) do _
            (number(r,UInt32),realread(r),realread(r),number(r,UInt32))
        end
        V.text_glyphs(content,glyphs)
        names ? PendingText(content,position,state,glyphs,language,script,features,fallbacks) :
                V.TextRun(content,position,state,glyphs,language,script,features,fallbacks)
    else
        V.ClearRegion(ntuple(_->realread(r),4),state)
    end
    expected,V.SemanticNode(id,revision,op)
end

"""
    decode(previous, bytes; capabilities, assets, validate_assets)

Check the VTRW envelope and hold one decoder slot when required. The optional
bundle validator checks the live declared bindings before lease and name admission.
"""
function decode(previous, bytes; capabilities::UInt32=CAPABILITIES, assets=nothing,
                validate_assets=nothing)
    r = Reader(bytes)
    check(bytesread(r,4) == codeunits("VTRW"), "bad magic")
    major,minor = number(r,UInt16),number(r,UInt16)
    check(major == 1 && minor <= 6, "unnegotiated wire version")
    if minor == 6
        required = number(r,UInt32)
        check((required & (PROFILE | RASTER_ASSETS)) == (PROFILE | RASTER_ASSETS) &&
              required & ~CAPABILITIES == 0 && required & ~capabilities == 0 &&
              (required & BLUR == 0 || required & GROUP != 0) &&
              (required & NAME_BYTES == 0 || required & UInt32(2) != 0),
              "unsupported required capabilities")
        begin_candidate!()
        try
            return decode_body(previous,r,minor;capabilities,assets,required,validate_assets)
        finally
            end_candidate!()
        end
    end
    names = minor in (3,4,5)
    names && begin_candidate!()
    try
        decode_body(previous,r,minor;capabilities,validate_assets)
    finally
        names && end_candidate!()
    end
end
"""
    decode_body(previous, reader, minor; capabilities, assets, required, validate_assets)

Validate and reconstruct a candidate from the bounded data after the version
header. Resolve exact assets, then admit names and return the owning Snapshot.
"""
function decode_body(previous,r,minor;capabilities,assets=nothing,required=number(r,UInt32),
                     validate_assets=nothing)
    check(minor == 6 || (minor == 0 ? required == PROFILE : minor == 1 ? required == TEXT_PROFILE :
           minor == 2 ? required in (UInt32(5),UInt32(7)) :
           minor == 3 ? required in (UInt32(11),UInt32(15)) :
           minor == 4 ? (required & (PROFILE | GROUP)) == (PROFILE | GROUP) &&
           required & ~UInt32(63) == 0 &&
           (required & NAME_BYTES == 0 || required & UInt32(2) != 0) :
           (required & (PROFILE | TYPED)) == (PROFILE | TYPED) &&
           required & ~LEGACY_CAPABILITIES == 0 && (required & BLUR == 0 || required & GROUP != 0) &&
           (required & NAME_BYTES == 0 || required & UInt32(2) != 0)) &&
          required & ~capabilities == 0,
           "unsupported required capabilities")
    r.typed = required & TYPED != 0
    external = required & RASTER_ASSETS != 0
    retained_bindings = snapshot_bindings(previous)
    bindings = external ? (retained_bindings === nothing ? Dict{ResourceKey,AssetBinding}() :
        copy(retained_bindings)) : nothing
    check(previous === nothing || requirements(previous) & ~required == 0,
          "retained frame requires negotiated capabilities")
    check(number(r,UInt8) == (previous === nothing ? 1 : 2), "wrong message kind")
    check(number(r,UInt8) == 0 && number(r,UInt16) == 0, "unknown required flags")
    canvas,before,revision = number(r,UInt64),number(r,UInt64),number(r,UInt64)
    if previous === nothing
        check(before == 0, "snapshot has a base revision")
    else
        check(canvas == previous.frame.canvas && before == previous.frame.revision &&
              revision > before, "canvas/base revision conflict")
    end
    size = ntuple(_->realread(r),2)
    check(canvas > 0 && all(>(0),size), "invalid canvas/size")
    blobs = previous === nothing ? Dict{Address,V.FrozenBytes}() : copy(previous.blobs)
    supplied = Set{Address}()
    for _ in 1:countread(r,MAX_RESOURCES,36)
        hash = addressread(r)
        n = number(r,UInt32)
        check(n <= MAX_BLOB && !(hash in supplied) && !haskey(blobs,hash), "blob length/duplicate conflict")
        data = bytesread(r,Int(n))
        check(blobdigest(hash[1],data) == hash[2], "content digest mismatch")
        push!(supplied,hash)
        blobs[hash] = V.FrozenBytes(data)
    end
    records = previous === nothing ? Dict{ResourceKey,V.ResourcePayload}() :
        Dict{ResourceKey,V.ResourcePayload}(resourcekey(r.reference)=>r.payload for r in previous.frame.resources)
    addresses = previous === nothing ? Dict{ResourceKey,Address}() :
        Dict{ResourceKey,Address}(resourcekey(ref)=>address for (ref,address) in previous.hashes)
    payloads = Dict{Tuple,V.ResourcePayload}()
    if previous !== nothing
        for (ref,p) in records
            p isa V.RasterReference && continue
            payloads[descriptor(p,addresses[ref])] = p
        end
    end
    declared = Set{ResourceKey}()
    needed = Set{Address}()
    imported = 0
    for _ in 1:countread(r,MAX_RESOURCES,59)
        ref = keyread(r,canvas)
        check(!haskey(records,ref) && !(ref in declared), "duplicate resource declaration")
        tag = r.typed ? number(r,UInt8) : ref[4] == "image" ? 1 : 2
        check(tag in (1,2,3) && (tag != 3 || r.typed), "unsupported payload tag")
        if external && tag == 1
            representation = number(r,UInt8)
            check(representation in (1,2), "unsupported image representation")
            if representation == 2
                check(ref[4] == "image", "external raster requires image kind")
                binding = binding_read(IOBuffer(bytesread(r,85)))
                records[ref] = binding.descriptor
                bindings[ref] = binding
                push!(declared,ref)
                continue
            end
        end
        dimensions = tag == 1 ? (number(r,UInt32),number(r,UInt32)) : nothing
        family = tag == 2 ? stringread(r) : nothing
        hash = addressread(r)
        check(hash[1] == (tag == 3 ? 1 : 0), "payload blob domain mismatch")
        check(haskey(blobs,hash), "missing resource bytes")
        push!(needed,hash)
        desc = tag == 3 ? (:path,hash) : tag == 2 ? (:font,family,hash) :
            (:image,Int64(dimensions[1]),Int64(dimensions[2]),hash)
        if tag == 3
            # Count before tuple allocation, even when another declaration shares this payload.
            check(length(blobs[hash]) <= 4+49MAX_PATH, "canonical path byte limit")
            probe = Reader(collect(codeunits(blobs[hash].bytes)))
            count = number(probe,UInt32)
            check(count <= MAX_PATH && count <= r.items && count <= remaining(probe), "path resource work limit")
            r.items -= Int(count)
            probe.position = 1
        end
        payload = get!(payloads,desc) do
            data = blobs[hash]
            imported += length(data)
            check(imported <= MAX_MESSAGE, "materialized import budget")
            if tag == 1
                w,h = Int64.(dimensions)
                check(w > 0 && h > 0 && w <= MAX_BLOB÷4÷h && length(data) == 4w*h,
                      "image dimensions/byte count")
                V.ImageData(V.Image(Int(w),Int(h),collect(codeunits(data.bytes))))
            elseif tag == 2
                V.FontData(family,codeunits(data.bytes))
            else
                path = pathread(probe)
                check(remaining(probe) == 0, "trailing path bytes")
                path
            end
        end
        records[ref] = payload
        addresses[ref] = hash
        push!(declared,ref)
    end
    check(all(hash->hash in needed,supplied), "unused blob declaration")
    resources = Tuple{ResourceKey,V.ResourcePayload}[]
    refs = Set{ResourceKey}()
    for _ in 1:countread(r,MAX_RESOURCES,25)
        ref = keyread(r,canvas)
        check(!(ref in refs) && haskey(records,ref), "duplicate/missing resource revision")
        push!(refs,ref)
        push!(resources,(ref,records[ref]))
    end
    check(issubset(declared,refs), "unpublished resource declaration")
    nodes = previous === nothing ? Dict{UInt64,V.SemanticNode}() : copy(previous.nodes)
    changed = Set{UInt64}()
    for _ in 1:countread(r,MAX_NODES,25)
        expected,node = noderead(r,canvas,required,previous)
        check(!(node.id in changed), "duplicate node update")
        old = get(nodes,node.id,nothing)
        check(old === nothing ? expected == 0 : expected == old.revision && node.revision > expected,
              "node expected revision conflict")
        nodes[node.id] = node
        push!(changed,node.id)
    end
    ordered = V.SemanticNode[]
    ids = Set{UInt64}()
    frame_items = resource_work(resources,r.typed)
    for _ in 1:countread(r,MAX_NODES,8)
        id = number(r,UInt64)
        check(!(id in ids) && haskey(nodes,id), "duplicate/missing ordered node")
        frame_items += sum(n->nodework(n;names=required & NAME_BYTES != 0),tree_nodes((nodes[id],)))
        check(frame_items <= MAX_ITEMS, "reconstructed frame complexity budget")
        push!(ids,id); push!(ordered,nodes[id])
    end
    check(issubset(changed,ids), "unpublished node update")
    metadata = Tuple{UInt16,V.FrozenBytes}[]
    count = number(r,UInt16)
    check(count <= 16, "metadata count limit")
    total = 0
    metadata_tags = Set{UInt16}()
    for _ in 1:count
        tag,n = number(r,UInt16),number(r,UInt32)
        check(tag & 0x8000 != 0 && !(tag in metadata_tags), "unknown required/duplicate metadata")
        push!(metadata_tags,tag)
        check(n <= MAX_METADATA-total, "metadata byte limit")
        total += Int(n)
        push!(metadata,(tag,V.FrozenBytes(bytesread(r,Int(n)))))
    end
    check(remaining(r) == 0, "trailing bytes")
    tree_nodes(ordered) # Bound the whole reconstructed tree, including retained roots, before Frame construction.
    candidate = validate_candidate(canvas,revision,size,Tuple(ordered),resources,previous,
                                   Tuple(metadata),required;addresses,stored=blobs,bindings)
    validate_assets === nothing || validate_assets(resources,bindings)
    ownership = external ? admit_snapshot_assets(assets,resources,bindings) : nothing
    with_snapshot_assets(ownership) do
        admit_candidate_names(candidate,resources,required,ownership)
    end
end

"""
    admit_candidate_names(candidate, resources, required, ownership)

Resolve the byte-keyed names only after external resources have been pinned.
Return the final immutable snapshot with its ownership attached.
"""
function admit_candidate_names(candidate,resources,required,ownership)
    required & (NAME_BYTES | TYPED) == 0 &&
        return finalize_candidate(candidate,Dict{String,Symbol}(),ownership)
    names = Set{String}()
    for (ref,_) in resources
        ref[4] in ("image","font") || push!(names,ref[4])
    end
    for node in values(candidate.nodes)
        op = node.operation
        if istext(op)
            push!(names,namebytes(op.script))
            foreach(f->push!(names,namebytes(featuretag(f))),op.features)
        end
    end
    admit_names!(names) do resolved
        finalize_candidate(candidate,resolved,ownership)
    end
end
function finalize_candidate(candidate,resolved,ownership=nothing)
    if candidate isa PendingSnapshot
        refs = copy(candidate.known_refs)
        for (key,_) in candidate.resources
            get!(refs,key) do
                kind = key[4] == "image" ? :image : key[4] == "font" ? :font : resolved[key[4]]::Symbol
                V.ResourceRef(key[1],key[2],key[3],kind)
            end
        end
        candidate = materialize(candidate,refs;ownership)
    end
    function finalize_node(node)
        op = node.operation
        if op isa V.CompositeGroup
            children = map(finalize_node,Tuple(op.nodes))
            if !all(pair->pair[1] === pair[2],zip(children,op.nodes))
                node = V.SemanticNode(node.id,node.revision,V.CompositeGroup(children,op.opacity,op.blend,op.effect))
            end
        elseif op isa PendingText
            features = map(op.features) do f
                tag = resolved[namebytes(featuretag(f))]::Symbol
                f isa Tuple ? (tag,Int(f[2])) : tag
            end
            op = V.TextRun(op.text,op.position,op.state,op.glyphs,op.language,
                resolved[op.script]::Symbol,features,op.fallback_fonts)
            node = V.SemanticNode(node.id,node.revision,op)
        end
        node
    end
    nodes = map(finalize_node,Tuple(candidate.frame.nodes))
    old = candidate.frame
    frame = V.Frame(old.schema_version,old.canvas,old.revision,old.size,Tuple(nodes),old.resources)
    Snapshot(frame,candidate.hashes,candidate.blobs,candidate.history,
        Dict(n.id=>n for n in tree_nodes(nodes)),candidate.max_node,candidate.metadata,ownership)
end

"""
    decode_snapshot(bytes; capabilities=CAPABILITIES, assets=nothing)

Validate a snapshot before publication. A minor 1.6 packet requires an open
resolver that already contains every complete bound revision. Close an
external snapshot when it is no longer needed. Invalid packets are rejected.
"""
decode_snapshot(bytes::Vector{UInt8}; capabilities::UInt32=CAPABILITIES, assets=nothing) =
    decode(nothing,bytes;capabilities,assets)

"""
    apply_delta(previous, bytes; capabilities=CAPABILITIES, assets=nothing)

Validate a delta and return an independently retained candidate snapshot.
Failure preserves the previous snapshot. Supply the complete imported
asset resolver for a minor 1.6 delta.
"""
apply_delta(previous::Snapshot, bytes::Vector{UInt8}; capabilities::UInt32=CAPABILITIES, assets=nothing) =
    decode(previous,bytes;capabilities,assets)
include("ForkCanvas.jl")
end
