"""
Optional FreeType outline preparation for a captured drawing on Linux x86-64.
This example uses the LP64 provider ABI.
"""
module GridFitting

import ..Vetra
using StaticArrays: SVector

"""System FreeType soname loaded by the first admitted text run."""
const FT = "libfreetype.so.6"
"""Maximum visited semantic nodes per preparation, including group children."""
const MAX_NODES = 4096
"""Maximum number of glyph occurrences per preparation."""
const MAX_GLYPHS = 4096
"""Maximum number of positioned outline commands per preparation."""
const MAX_COMMANDS = 65536
"""Maximum number of distinct memory faces per preparation."""
const MAX_FONTS = 16
"""Maximum total source font bytes per preparation."""
const MAX_BYTES = 32*1024*1024
"""Maximum physical font size in 26.6 pixel units."""
const MAX_SIZE = 4096*64
"""Maximum number of points in an individual FreeType outline."""
const MAX_POINTS = 16384
"""FreeType scalable and SFNT face flags required by this profile."""
const FACE_FLAGS = Clong((1 << 0) | (1 << 3))
"""FreeType's four-byte outline glyph format tag, `outl`."""
const OUTLINE_FORMAT = UInt32(0x6f75746c)
"""FreeType flag requesting outline data in place of embedded bitmap strikes."""
const NO_BITMAP = Cint(1 << 3)
"""FreeType flag bypassing hinting for the unhinted comparison mode."""
const NO_HINTING = Cint(1 << 1)
"""FreeType light hinting target in the glyph load-flags field."""
const LIGHT_TARGET = Cint(1 << 16)
"""One physical pixel in FreeType's 26.6 coordinate units."""
const SUBPIXELS = 64
"""Maximum retained glyph keys per session, including empty outlines."""
const MAX_CACHED_GLYPHS = 4096
"""Maximum retained commands per session, across all fonts and sizes."""
const MAX_CACHED_COMMANDS = 65536
"""Serialize native misses across sessions while their FreeType faces are open."""
const NATIVE_LOCK = ReentrantLock()
"""Vetra path symbols in the order of the private packed command tags."""
const PATH_TAGS = (:move, :line, :quad, :cubic, :close)
"""Packed command tag for the first point of a contour."""
const MOVE = UInt8(1)
"""Packed command tag for a line segment."""
const LINE = UInt8(2)
"""Packed command tag for a quadratic curve."""
const QUAD = UInt8(3)
"""Packed command tag for a cubic curve."""
const CUBIC = UInt8(4)
"""Packed command tag that closes a contour."""
const CLOSE = UInt8(5)

"""One cached segment in physical pixels with unused coordinates padded by zeros."""
struct Command
    """Up to three x/y pairs, kept inline in the cached command vector."""
    coordinates::SVector{6,Float64}
    """Index in `PATH_TAGS`."""
    tag::UInt8
    """Number of coordinates used by this command."""
    count::UInt8
end

"""Pack one FreeType callback's coordinates into the fixed-width cache record."""
function Command(tag::UInt8, coordinates::NTuple{N,Float64}) where {N}
    return Command(SVector{6,Float64}(ntuple(i -> i <= N ? coordinates[i] : 0.0, 6)),
                   tag, UInt8(N))
end

"""Scoped font, horizontal and vertical 26.6 sizes, and the glyph ID."""
const GlyphKey = Tuple{Vetra.ResourceRef,Clong,Clong,UInt32}

"""Private outlines and source bytes retained between fitting calls."""
mutable struct OutlineCache
    """Rooted immutable font bytes indexed by their scoped resource reference."""
    fonts::Dict{Vetra.ResourceRef,String}
    """Owned vectors of commands in physical pixels."""
    glyphs::Dict{GlyphKey,Vector{Command}}
    """Total bytes in retained font strings."""
    bytes::Int
    """Total command records retained by the cache."""
    commands::Int
end

"""Start an empty Julia-only outline cache."""
OutlineCache() = OutlineCache(Dict(), Dict(), 0, 0)

"""
    TextHinting(; mode=:normal)

Create a reusable session for fitting captured outline text to physical pixels.
`mode` is `:normal`, `:light`, or `:unhinted`. Invalid modes raise
`ArgumentError`. On Linux x86-64, pass the session as `hinting` to
[`Vetra.rasterize`](@ref), [`Vetra.savepng`](@ref), or
[`Vetra.hinted_frame`](@ref). System FreeType loads on the first outline miss.

The session serializes calls and caches only owned Julia outlines and
immutable source font bytes. The cache resets on conflicting font bytes
or before exceeding 16 fonts, 32 MiB of font bytes, 4,096 glyph keys, or
65,536 commands. Each preparation closes its native faces before returning.
"""
struct TextHinting
    """Fixed FreeType outline loading flags for this session's mode."""
    flags::Cint
    """Serializes access to the session's mutable cache."""
    lock::ReentrantLock
    """Bounded cache of provider-derived outlines."""
    cache::OutlineCache
    function TextHinting(; mode=:normal)
        mode isa Symbol && mode in (:normal, :light, :unhinted) ||
            throw(ArgumentError("invalid hint mode"))
        flags = NO_BITMAP | (mode === :light ? LIGHT_TARGET : mode === :unhinted ? NO_HINTING : Cint(0))
        return new(flags, ReentrantLock(), OutlineCache())
    end
end

"""FreeType `FT_Vector`, in signed 26.6 coordinates (Linux LP64)."""
struct Vec
    """Native horizontal component. The containing record specifies its units."""
    x::Clong
    """Native vertical component in the same units as the horizontal component."""
    y::Clong
end
"""FreeType `FT_Generic` prefix."""
struct Generic
    """Application-owned native payload pointer."""
    data::Ptr{Cvoid}
    """Native release callback for the application payload."""
    finalizer::Ptr{Cvoid}
end
"""FreeType `FT_BBox`."""
struct BBox
    """Left edge in font units."""
    xmin::Clong
    """Bottom edge in font units."""
    ymin::Clong
    """Right edge in font units."""
    xmax::Clong
    """Top edge in font units."""
    ymax::Clong
end
"""Public `FT_FaceRec` fields through `glyph` and their borrowed pointers."""
struct FacePrefix
    """Number of faces in the opened font resource."""
    num_faces::Clong
    """Selected face and instance identity in the provider."""
    face_index::Clong
    """Provider capabilities and data-format flags."""
    face_flags::Clong
    """Provider style flags included for the native layout."""
    style_flags::Clong
    """Exclusive upper bound for glyph IDs."""
    num_glyphs::Clong
    """Borrowed family name pointer."""
    family::Ptr{Cvoid}
    """Borrowed style name pointer."""
    style::Ptr{Cvoid}
    """Number of embedded bitmap strikes."""
    num_fixed::Cint
    """Borrowed bitmap strike descriptors."""
    sizes::Ptr{Cvoid}
    """Number of available character maps."""
    num_charmaps::Cint
    """Borrowed character map pointers."""
    charmaps::Ptr{Cvoid}
    """Provider application payload."""
    generic::Generic
    """Scalable font bounds."""
    bbox::BBox
    """Design units per em."""
    units::Cushort
    """Baseline-to-ascender distance in design units."""
    ascender::Cshort
    """Baseline-to-descender distance in design units."""
    descender::Cshort
    """Recommended baseline spacing in design units."""
    height::Cshort
    """Maximum horizontal advance in design units."""
    max_width::Cshort
    """Maximum vertical advance in design units."""
    max_height::Cshort
    """Underline position in design units."""
    underline_position::Cshort
    """Underline thickness in design units."""
    underline_thickness::Cshort
    """Borrowed slot updated by each glyph load on this face."""
    glyph::Ptr{Cvoid}
end
"""Public `FT_GlyphRec` fields describing the outline's owning glyph."""
struct GlyphRec
    """Native owner of this copied glyph."""
    library::Ptr{Cvoid}
    """Provider class pointer included for the native layout."""
    clazz::Ptr{Cvoid}
    """Native glyph image format tag."""
    format::UInt32
    """Advance vector in native 16.16 units."""
    advance::Vec
end
"""Public `FT_Outline` view borrowing its arrays from the glyph."""
struct Outline
    """Number of closed contours in the outline."""
    contours_count::Cshort
    """Number of vertices and control points."""
    points_count::Cshort
    """Borrowed positions in 26.6 pixel coordinates."""
    points::Ptr{Vec}
    """Borrowed FreeType point flags."""
    tags::Ptr{UInt8}
    """Borrowed indices of the last point in each contour."""
    contours::Ptr{Cshort}
    """Native outline flags."""
    flags::Cint
end
"""Public `FT_OutlineGlyphRec`."""
struct OutlineGlyph
    """Native glyph header, checked for outline format."""
    root::GlyphRec
    """Borrowed contour arrays valid until the copied glyph is released."""
    outline::Outline
end
"""FreeType decomposition callback table, with zero coordinate shift and delta."""
struct OutlineFuncs
    """Callback marking a contour start."""
    move::Ptr{Cvoid}
    """Callback for a straight segment."""
    line::Ptr{Cvoid}
    """Callback for a quadratic segment."""
    conic::Ptr{Cvoid}
    """Callback for a cubic segment."""
    cubic::Ptr{Cvoid}
    """Native coordinate shift, set to zero."""
    shift::Cint
    """Native coordinate offset, set to zero."""
    delta::Clong
end
"""Callback state owns unpositioned Julia commands and captures callback errors."""
mutable struct Builder
    """Unpositioned owned outline commands in y-down physical pixels."""
    commands::Vector{Command}
    """Whether a contour still requires a close command."""
    open::Bool
    """Exception captured for Julia-side propagation after decomposition."""
    error::Any
    """Maximum number of commands permitted for the current glyph."""
    limit::Int
end
"""Convert a borrowed FreeType point to y-down physical pixel coordinates."""
function point(p::Ptr{Vec})
    value = unsafe_load(p)
    return (value.x/SUBPIXELS, -value.y/SUBPIXELS)
end
"""Append one command with an enforced callback-local budget."""
function add!(b::Builder, tag::UInt8, coordinates=())
    length(b.commands) < b.limit || throw(ArgumentError("outline command budget exceeded"))
    push!(b.commands, Command(tag, coordinates))
end
"""Run callback work without allowing a Julia exception to cross the C ABI."""
function callback(f, u)::Cint
    b = unsafe_pointer_to_objref(u)::Builder
    try
        f(b)
        return 0
    catch err
        b.error = err
        return 1
    end
end
"""Begin an outline contour, closing the preceding contour."""
function move_cb(p::Ptr{Vec}, u::Ptr{Cvoid})::Cint
    try
        callback(u) do b
            b.open && add!(b, CLOSE)
            add!(b, MOVE, point(p))
            b.open = true
        end
    catch err
        unsafe_pointer_to_objref(u).error = err
        Cint(1)
    end
end
"""Append a straight segment."""
function line_cb(p::Ptr{Vec}, u::Ptr{Cvoid})::Cint
    try
        callback(u) do b
            add!(b, LINE, point(p))
        end
    catch err
        unsafe_pointer_to_objref(u).error = err
        Cint(1)
    end
end
"""Append a quadratic segment."""
function conic_cb(c::Ptr{Vec}, p::Ptr{Vec}, u::Ptr{Cvoid})::Cint
    try
        callback(u) do b
            add!(b, QUAD, (point(c)..., point(p)...))
        end
    catch err
        unsafe_pointer_to_objref(u).error = err
        Cint(1)
    end
end
"""Append a cubic segment."""
function cubic_cb(c::Ptr{Vec}, d::Ptr{Vec}, p::Ptr{Vec}, u::Ptr{Cvoid})::Cint
    try
        callback(u) do b
            add!(b, CUBIC, (point(c)..., point(d)..., point(p)...))
        end
    catch err
        unsafe_pointer_to_objref(u).error = err
        Cint(1)
    end
end
"""Resolve the four statically compiled callbacks in the current Julia process."""
outline_funcs() = OutlineFuncs(@cfunction(move_cb,Cint,(Ptr{Vec},Ptr{Cvoid})),
    @cfunction(line_cb,Cint,(Ptr{Vec},Ptr{Cvoid})),
    @cfunction(conic_cb,Cint,(Ptr{Vec},Ptr{Vec},Ptr{Cvoid})),
    @cfunction(cubic_cb,Cint,(Ptr{Vec},Ptr{Vec},Ptr{Vec},Ptr{Cvoid})),0,0)

"""Throw a descriptive error for a nonzero FreeType status."""
check(code, name) = code == 0 || throw(ArgumentError("$name failed ($code)"))

"""Per-call native faces and resource admission, with a borrowed session cache."""
mutable struct Preparation
    """Private native library handle, created on the first text run."""
    library::Ptr{Cvoid}
    """Native faces backed by bytes in `fonts` until the call ends."""
    faces::Dict{Vetra.ResourceRef,Ptr{Cvoid}}
    """Exact font bytes resolved and admitted from this call's source frame."""
    fonts::Dict{Vetra.ResourceRef,String}
    """Borrowed Julia-only cache, locked by the session."""
    cache::OutlineCache
    """Total input font bytes admitted during this preparation."""
    bytes::Int
    """Semantic nodes visited, including nested groups."""
    nodes::Int
    """All glyph occurrences encountered, including cache hits."""
    glyphs::Int
    """Total positioned output commands admitted so far."""
    commands::Int
    """Native loading flags fixed by the session."""
    flags::Cint
    """True after acquiring the process-wide native fitting lock."""
    native_locked::Bool
end

"""Resolve and admit the exact font bytes from this frame, even on cache hits."""
function font_bytes!(p::Preparation, frame::Vetra.Frame, ref)
    ref isa Vetra.ResourceRef && ref.canvas == frame.canvas && ref.kind === :font &&
        ref.id > 0 && ref.revision > 0 || throw(ArgumentError("invalid scoped font reference"))
    bytes = get(p.fonts, ref, nothing)
    bytes === nothing || return bytes
    length(p.fonts) < MAX_FONTS || throw(ArgumentError("font count exceeded"))
    data = Vetra.resolve_resource(frame.resources,ref)
    data isa Vetra.FontData || throw(ArgumentError("not a font resource"))
    n = length(data.data)
    0 < n <= 16*1024*1024 && p.bytes+n <= MAX_BYTES || throw(ArgumentError("font byte budget exceeded"))
    p.fonts[ref] = data.data.bytes
    p.bytes += n
    return data.data.bytes
end

"""Reset cached outlines and release the retained references to font bytes."""
function reset!(cache::OutlineCache)
    empty!(cache.fonts)
    empty!(cache.glyphs)
    cache.bytes = 0
    cache.commands = 0
    return nothing
end

"""Bind a reference to identical bytes before searching or adding a cached glyph."""
function cache_font!(cache::OutlineCache, ref::Vetra.ResourceRef, bytes::String)
    previous = get(cache.fonts, ref, nothing)
    previous === bytes && return nothing
    n = ncodeunits(bytes)
    if previous !== nothing || length(cache.fonts) == MAX_FONTS || cache.bytes + n > MAX_BYTES
        reset!(cache)
    end
    cache.fonts[ref] = bytes
    cache.bytes += n
    return nothing
end

"""Open a scalable memory face lazily, with this call's exact rooted bytes."""
function face!(p::Preparation, ref::Vetra.ResourceRef, bytes::String)
    ptr = get(p.faces, ref, C_NULL)
    ptr != C_NULL && return ptr
    if p.library == C_NULL
        lock(NATIVE_LOCK)
        p.native_locked = true
        lib = Ref{Ptr{Cvoid}}(C_NULL)
        check(ccall((:FT_Init_FreeType,FT),Cint,(Ref{Ptr{Cvoid}},),lib),"FT_Init_FreeType")
        lib[] != C_NULL || throw(ArgumentError("null FreeType library"))
        p.library = lib[]
    end
    face = Ref{Ptr{Cvoid}}(C_NULL)
    GC.@preserve bytes begin
        check(ccall((:FT_New_Memory_Face,FT),Cint,
            (Ptr{Cvoid},Ptr{UInt8},Clong,Clong,Ref{Ptr{Cvoid}}),
            p.library,pointer(bytes),ncodeunits(bytes),0,face),"FT_New_Memory_Face")
        try
            face[] != C_NULL || throw(ArgumentError("null face"))
            info = unsafe_load(Ptr{FacePrefix}(face[]))
            info.num_faces == 1 && info.face_index == 0 && info.num_glyphs > 0 &&
                info.face_flags & FACE_FLAGS == FACE_FLAGS ||
                throw(ArgumentError("expected a scalable single-face SFNT"))
            p.faces[ref] = face[]
            return face[]
        catch
            face[] != C_NULL && ccall((:FT_Done_Face,FT),Cint,(Ptr{Cvoid},),face[])
            rethrow()
        end
    end
end

"""Get an owned outline for validated bytes and actual rounded physical sizes."""
function outline!(p::Preparation, ref::Vetra.ResourceRef, bytes::String, sx, sy, gid)
    cache = p.cache
    cache_font!(cache, ref, bytes)
    key = (ref,Clong(sx),Clong(sy),UInt32(gid))
    result = get(cache.glyphs, key, nothing)
    result === nothing || return result
    face = face!(p,ref,bytes)
    info = unsafe_load(Ptr{FacePrefix}(face))
    0 < gid < info.num_glyphs || throw(ArgumentError("glyph ID outside face"))
    check(ccall((:FT_Set_Char_Size,FT),Cint,(Ptr{Cvoid},Clong,Clong,Cuint,Cuint),
        face,sx,sy,72,72),"FT_Set_Char_Size")
    check(ccall((:FT_Load_Glyph,FT),Cint,(Ptr{Cvoid},Cuint,Cint),face,gid,p.flags),"FT_Load_Glyph")
    slot = unsafe_load(Ptr{FacePrefix}(face)).glyph
    slot != C_NULL || throw(ArgumentError("null glyph slot"))
    glyph = Ref{Ptr{Cvoid}}(C_NULL)
    check(ccall((:FT_Get_Glyph,FT),Cint,(Ptr{Cvoid},Ref{Ptr{Cvoid}}),slot,glyph),"FT_Get_Glyph")
    try
        glyph[] != C_NULL || throw(ArgumentError("null glyph"))
        root = unsafe_load(Ptr{GlyphRec}(glyph[]))
        root.format == OUTLINE_FORMAT || throw(ArgumentError("glyph is not an outline"))
        record = unsafe_load(Ptr{OutlineGlyph}(glyph[]))
        o = record.outline
        0 <= o.points_count <= MAX_POINTS && 0 <= o.contours_count <= o.points_count ||
            throw(ArgumentError("outline point budget exceeded"))
        outline = Ref(o)
        check(ccall((:FT_Outline_Check,FT),Cint,(Ref{Outline},),outline),"FT_Outline_Check")
        b = Builder(Command[],false,nothing,MAX_COMMANDS-p.commands)
        status = GC.@preserve b begin
            ccall((:FT_Outline_Decompose,FT),Cint,(Ref{Outline},Ref{OutlineFuncs},Ptr{Cvoid}),
                outline,outline_funcs(),pointer_from_objref(b))
        end
        b.error === nothing || throw(b.error)
        check(status,"FT_Outline_Decompose")
        b.open && add!(b,CLOSE)
        if length(cache.glyphs) == MAX_CACHED_GLYPHS ||
                cache.commands + length(b.commands) > MAX_CACHED_COMMANDS
            reset!(cache)
            cache_font!(cache, ref, bytes)
        end
        cache.glyphs[key] = b.commands
        cache.commands += length(b.commands)
        return b.commands
    finally
        glyph[] != C_NULL && ccall((:FT_Done_Glyph,FT),Cvoid,(Ptr{Cvoid},),glyph[])
    end
end

"""Convert a captured run into one compound nonzero fill with its original state."""
function lower(p::Preparation, frame::Vetra.Frame, run::Vetra.TextRun, scale)
    isempty(run.glyphs) && throw(ArgumentError("deferred text is unsupported"))
    isempty(run.fallback_fonts) || throw(ArgumentError("expected a single captured face"))
    isvalid(run.text) && ncodeunits(run.text) <= MAX_GLYPHS &&
        all(isfinite,run.position) || throw(ArgumentError("invalid text or position"))
    s = run.state
    s.profile === :portable2d || throw(ArgumentError("unsupported drawing profile"))
    a,b,c,d,_,_ = s.transform.coefficients
    b == 0 && c == 0 && a > 0 && d > 0 || throw(ArgumentError("expected positive axis-aligned transform"))
    xscale,yscale = a*scale[1],d*scale[2]
    sizes = (s.font_size*xscale*SUBPIXELS,s.font_size*yscale*SUBPIXELS)
    all(x -> isfinite(x) && SUBPIXELS <= x <= MAX_SIZE, sizes) || throw(ArgumentError("font size outside profile"))
    sx,sy = round.(Int,sizes)
    bytes = font_bytes!(p, frame, s.font)
    commands = Tuple[]
    for glyph in run.glyphs
        p.glyphs += 1
        p.glyphs <= MAX_GLYPHS || throw(ArgumentError("glyph budget exceeded"))
        glyph isa Tuple && length(glyph) == 4 || throw(ArgumentError("invalid glyph tuple"))
        gid,x,y,cluster = glyph
        gid isa Integer && 0 < gid <= typemax(UInt32) &&
            cluster isa Integer && 0 <= cluster < ncodeunits(run.text) &&
            isvalid(run.text,Int(cluster)+1) &&
            x isa Real && y isa Real && isfinite(x) && isfinite(y) ||
            throw(ArgumentError("invalid captured glyph or UTF-8 anchor"))
        ox,oy = run.position[1]+x,run.position[2]+y
        all(isfinite,(ox,oy)) || throw(ArgumentError("invalid glyph position"))
        path = outline!(p,s.font,bytes,sx,sy,gid)
        length(path) <= MAX_COMMANDS-p.commands || throw(ArgumentError("outline command budget exceeded"))
        p.commands += length(path)
        for cmd in path
            coords = ntuple(i -> isodd(i) ? ox+cmd.coordinates[i]/xscale :
                oy+cmd.coordinates[i]/yscale, Int(cmd.count))
            push!(commands,(PATH_TAGS[cmd.tag],coords...))
        end
    end
    Vetra.FillPath(Vetra.PathData(commands),s,:nonzero)
end

"""Recursively preserve all group and node identities while replacing text."""
function nodes(p::Preparation, frame::Vetra.Frame, list, scale, depth=0)
    depth <= 64 || throw(ArgumentError("group depth exceeded"))
    length(list) <= MAX_NODES-p.nodes || throw(ArgumentError("node budget exceeded"))
    Tuple(map(collect(list)) do node
        p.nodes += 1
        p.nodes <= MAX_NODES || throw(ArgumentError("node budget exceeded"))
        op = node.operation
        if op isa Vetra.CompositeGroup
            op = Vetra.CompositeGroup(nodes(p,frame,op.nodes,scale,depth+1),op.opacity,op.blend,op.effect)
        elseif op isa Vetra.TextRun
            op = lower(p,frame,op,scale)
        end
        Vetra.SemanticNode(node.id,node.revision,op)
    end)
end

"""
    hinted_frame(frame::Frame; size=frame.size, hinting=TextHinting()) -> Frame

Derive a one-shot drawing for the physical pixel `size`, retaining the source
logical extent, resource records, node identities, group effects and state.
The adapter lowers captured single-face SFNT glyphs to compound nonzero fills.
All other drawing operations pass through. Only Linux x86-64 FreeType LP64
and positive axis-aligned text
transforms in the `:portable2d` profile are supported. Fractional captured
positions are preserved. The x and y physical font sizes are independently
rounded to 26.6 units. Refit the source for another physical size. For consumers
that identify changes by node revision, keep one fitted size per surface.

Invalid references, glyphs, UTF-8 anchors, sizes, deferred runs, unsupported
profiles/transforms, native errors and exhausted finite preparation limits
throw an error. The source retains its semantic text. The adapter roots
font bytes through `FT_Done_Face` and closes native handles on success
and error. The first admitted text run opens the library.
"""
function hinted_frame(frame::Vetra.Frame; size=frame.size, hinting::TextHinting=TextHinting())
    Sys.islinux() && Sys.ARCH === :x86_64 || throw(ArgumentError("requires Linux x86-64"))
    size isa Tuple && length(size) == 2 && all(x -> x isa Real && isfinite(x) &&
        isinteger(x) && 0 < x <= 1_000_000,size) || throw(ArgumentError("invalid physical size"))
    all(x -> isfinite(x) && x > 0,frame.size) || throw(ArgumentError("invalid logical size"))
    return lock(hinting.lock) do
        p = Preparation(C_NULL,Dict(),Dict(),hinting.cache,0,0,0,0,hinting.flags,false)
        try
            result = nodes(p,frame,frame.nodes,(Float64(size[1])/frame.size[1],Float64(size[2])/frame.size[2]))
            Vetra.Frame(frame.schema_version,frame.canvas,frame.revision,frame.size,result,frame.resources)
        finally
            try
                for (ref,face) in p.faces
                    bytes = p.fonts[ref]
                    GC.@preserve bytes ccall((:FT_Done_Face,FT),Cint,(Ptr{Cvoid},),face)
                end
                p.library != C_NULL && ccall((:FT_Done_FreeType,FT),Cint,(Ptr{Cvoid},),p.library)
            finally
                p.native_locked && unlock(NATIVE_LOCK)
            end
        end
    end
end
end
