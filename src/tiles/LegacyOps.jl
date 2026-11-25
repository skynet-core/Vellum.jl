# Legacy kernels retain Pixie's per-level rounding, including transparent odd edges.
const LEGACY_CACHE_SLOTS=4096
const LEGACY_ZERO=V.ColorRGBX(0x00,0x00,0x00,0x00)
const LEGACY_PAGE_BYTES=64*1024

function legacy_overlaps(dst,src)
    GC.@preserve dst src begin
        a,b=UInt128(UInt(pointer(dst.data))),UInt128(UInt(pointer(src.data)))
        a<b+length(src.data) && b<a+length(dst.data)
    end
end

mutable struct LegacyFile{I<:IO}
    width::Int
    height::Int
    io::I
    bytes::Int
    page::Vector{UInt8}
    offset::Int
    loads::Int
end

function V.getColor(source::LegacyFile,x::Int,y::Int)
    1<=x<=source.width && 1<=y<=source.height || throw(BoundsError(source,(x,y)))
    position=4*((y-1)*source.width+x-1)
    offset=position÷LEGACY_PAGE_BYTES*LEGACY_PAGE_BYTES
    if source.offset!=offset
        seek(source.io,offset)
        read!(source.io,view(source.page,1:min(LEGACY_PAGE_BYTES,source.bytes-offset)))
        source.offset=offset
        source.loads=Base.checked_add(source.loads,1)
    end
    i=position-offset
    V.ColorRGBX(source.page[i+1],source.page[i+2],source.page[i+3],source.page[i+4])
end

function with_legacy_file(f,src;opener=mktemp,remover=path->rm(path;force=true))
    path,io=opener()
    try
        for offset in 1:LEGACY_PAGE_BYTES:length(src.data)
            chunk=view(src.data,offset:min(offset+LEGACY_PAGE_BYTES-1,length(src.data)))
            write(io,chunk)==length(chunk) || throw(EOFError())
        end
        flush(io)
        position(io)==length(src.data) && filesize(path)==length(src.data) ||
            throw(ArgumentError("incomplete legacy source snapshot"))
        seekstart(io)
        f(LegacyFile(src.width,src.height,io,length(src.data),
            Vector{UInt8}(undef,LEGACY_PAGE_BYTES),-1,0))
    finally
        try
            close(io)
        finally
            remover(path)
        end
    end
end

function with_legacy_level(f,dst,src,level)
    if legacy_overlaps(dst,src)
        # Eager normalization isolated aliased input; preserve that with bounded RAM.
        return with_legacy_file(src) do source
            f(LegacyLevel(source,level))
        end
    end
    f(LegacyLevel(src,level))
end

function validate_legacy_images(dst,src,mat)
    for image in (dst,src)
        length(image.data)==V._checked_nbytes(image.width,image.height) ||
            throw(ArgumentError("legacy image storage extent changed"))
    end
    all(isfinite,mat.data) && all(isfinite,V.inverse(mat).data) ||
        throw(ArgumentError("legacy image transform must have a finite inverse"))
    nothing
end

mutable struct LegacyLevel{P}
    source::P
    width::Int
    height::Int
    level::Int
    dimensions::Vector{Tuple{Int,Int}}
    keys::Vector{Tuple{Int,Int}}
    colors::Vector{V.ColorRGBX}
    source_pixels::Int
    hits::Int
    misses::Int
end

function LegacyLevel(source,level::Int)
    # A positive finite Float32 step needs at most 149 binary rescalings.
    -149<=level<=149 || throw(ArgumentError("legacy level out of range"))
    w,h=source.width,source.height
    dimensions=Vector{Tuple{Int,Int}}(undef,abs(level)+1)
    dimensions[1]=(w,h)
    for i in 1:abs(level)
        w,h=level>0 ? (cld(w,2),cld(h,2)) :
            (Base.checked_mul(w,2),Base.checked_mul(h,2))
        V._checked_nbytes(w,h)
        dimensions[i+1]=(w,h)
    end
    LegacyLevel(source,w,h,level,dimensions,fill((-1,-1),LEGACY_CACHE_SLOTS),
        fill(LEGACY_ZERO,LEGACY_CACHE_SLOTS),0,0,0)
end

function legacy_reduce(r,level,x,y)
    if level==0
        r.source_pixels=Base.checked_add(r.source_pixels,1)
        return V.getColor(r.source,x+1,y+1)
    end
    w,h=r.dimensions[level]
    sx,sy=2x,2y
    a=legacy_reduce(r,level-1,sx,sy)
    if sx+1<w && sy+1<h
        b=legacy_reduce(r,level-1,sx+1,sy)
        c=legacy_reduce(r,level-1,sx+1,sy+1)
        d=legacy_reduce(r,level-1,sx,sy+1)
        return V.ColorRGBX(
            UInt8((Int(a.r)+b.r+c.r+d.r+2)÷4),
            UInt8((Int(a.g)+b.g+c.g+d.g+2)÷4),
            UInt8((Int(a.b)+b.b+c.b+d.b+2)÷4),
            UInt8((Int(a.a)+b.a+c.a+d.a+2)÷4))
    elseif sx+1<w
        return V.mix(a,legacy_reduce(r,level-1,sx+1,sy),0.5f0)*0.5f0
    elseif sy+1<h
        return V.mix(a,legacy_reduce(r,level-1,sx,sy+1),0.5f0)*0.5f0
    end
    a*0.25f0
end

function V.getColor(r::LegacyLevel,x::Int,y::Int)
    1<=x<=r.width && 1<=y<=r.height || throw(BoundsError(r,(x,y)))
    x-=1;y-=1
    # Direct-mapped fixed storage: collisions cost recomputation, never growth.
    slot=Int((UInt(x)*UInt(0x9e3779b1) ⊻ UInt(y)*UInt(0x85ebca77)) % UInt(LEGACY_CACHE_SLOTS))+1
    if r.keys[slot]==(x,y)
        r.hits=Base.checked_add(r.hits,1)
        return r.colors[slot]
    end
    r.misses=Base.checked_add(r.misses,1)
    color=if r.level>0
        legacy_reduce(r,r.level,x,y)
    else
        r.source_pixels=Base.checked_add(r.source_pixels,1)
        V.getColor(r.source,(x>>(-r.level))+1,(y>>(-r.level))+1)
    end
    r.keys[slot]=(x,y);r.colors[slot]=color
    color
end
V._at(r::LegacyLevel,x::Int,y::Int)=
    1<=x<=r.width && 1<=y<=r.height ? V.getColor(r,x,y) : LEGACY_ZERO
V.getRgbaSmooth(r::LegacyLevel,x::Float32,y::Float32,wrapped::Bool=false)=
    V._getRgbaSmooth(r,x,y,wrapped)

function legacy_blit(dst,r,pos,mode)
    px,py=pos
    if px>=dst.width || Int128(px)+r.width<=0 || py>=dst.height || Int128(py)+r.height<=0
        mode===V.MaskBlend && fill!(dst.data,0x00)
        return nothing
    end
    xs,ys=max(-px,0),max(-py,0)
    xe,ye=min(r.width,dst.width-px),min(r.height,dst.height-py)
    blend=V.blender(mode)
    mode===V.MaskBlend && V._zeroRows(dst,0,ys+py)
    for y in ys:ye-1
        mode===V.MaskBlend && V._zeroRowSegment(dst,0,y+py,xs+px)
        for x in xs:xe-1
            color=V.getColor(r,x+1,y+1)
            V.set_pixel(dst,x+px+1,y+py+1,blend(V.getColor(dst,x+px+1,y+py+1),color))
        end
        mode===V.MaskBlend && V._zeroRowSegment(dst,xe+px,y+py,dst.width-xe-px)
    end
    mode===V.MaskBlend && V._zeroRows(dst,ye+py,dst.height-ye-py)
    nothing
end
