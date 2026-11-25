"""CPU-executable Julia drawing kernel and its generated Vulkan shader functions."""
module QueueKernel

using StaticArrays: SVector, MVector
include("queue_shader_lowering.jl")

"""Device pixel or texel coordinates, with two integer components."""
const PointI = SVector{2,Int}
"""Physical coordinates carried at the packet's Float64 precision."""
const PointD = SVector{2,Float64}
"""Premultiplied red, green, blue and alpha in normalized device units."""
const Pixel = SVector{4,Float32}
"""One accumulator for the root and each of the two admitted isolated groups."""
const LayerStack = MVector{3,Pixel}

"""Zero-based word offsets of the geometry, paint and image tables in a compact frame packet."""
struct PacketTables
    shape::Int
    contour::Int
    point::Int
    stop::Int
    raster::Int
    page::Int
end

"""
    at_offset(buffer,i)

Read the word at the GPU packet's zero-based offset from a Julia vector.
"""
at_offset(buffer,i) = buffer[i+1]
"""
    floor_point(p)

Return the texel at or below each component of a fractional coordinate.
"""
floor_point(p) = PointI(floor.(Int,p))
"""
    unpack_color(p)

Normalize the four little-endian channels of a packed Vulkan texel.
"""
unpack_color(p) = Pixel(ntuple(i -> Float32((p >> (8(i-1))) & 0xff)/255f0,4))
"""
    pack_color(p)

Quantize premultiplied color for the top-down RGBA8 output buffer.
"""
pack_color(p) = sum(i -> round(UInt32,255*clamp(p[i],0,1)) << (8(i-1)),1:4)

@draw_kernel begin
    """
        intword(data,n::Int)::Int

    Read one index or command field from a Float64 drawing packet.
    """
    function intword(data,n::Int)::Int
        return Int(at_offset(data.words,n))
    end

    """
        inside_shape(data,t::PacketTables,index::Int,p::PointD)::Bool

    Test contour winding at a subpixel. Expanded strokes take the union of their component contours.
    """
    function inside_shape(data,t::PacketTables,index::Int,p::PointD)::Bool
        shape::Int = t.shape+8*index
        if p.x<at_offset(data.words,shape+3) || p.y<at_offset(data.words,shape+4) ||
                p.x>at_offset(data.words,shape+5) || p.y>at_offset(data.words,shape+6)
            return false
        end
        total::Int = 0
        mode::Int = intword(data,shape+2)
        first::Int = intword(data,shape)
        for i in first:(first+intword(data,shape+1)-1)
            c::Int = t.contour+6*i
            if p.x>at_offset(data.words,c+4) || p.y<at_offset(data.words,c+3) || p.y>=at_offset(data.words,c+5)
                continue
            end
            start::Int = t.point+2*intword(data,c)
            count::Int = intword(data,c+1)
            prev::Int = start+2*(count-1)
            a::PointD = PointD(at_offset(data.words,prev),at_offset(data.words,prev+1))
            winding::Int = 0
            for j in 0:(count-1)
                k::Int = start+2*j
                b::PointD = PointD(at_offset(data.words,k),at_offset(data.words,k+1))
                if (a.y>p.y)!=(b.y>p.y)
                    side::Float64 = (b.x-a.x)*(p.y-a.y)-(p.x-a.x)*(b.y-a.y)
                    if b.y>a.y && side>0
                        winding+=1
                    elseif b.y<a.y && side<0
                        winding-=1
                    end
                end
                a=b
            end
            if mode==2 && winding!=0
                return true
            end
            total+=winding
        end
        return mode==1 ? (total & 1)!=0 : total!=0
    end

    """
        stop_color(data,idx::Int)::Pixel

    Read a premultiplied sRGB gradient stop.
    """
    function stop_color(data,idx::Int)::Pixel
        return Pixel(at_offset(data.words,idx+1),at_offset(data.words,idx+2),at_offset(data.words,idx+3),at_offset(data.words,idx+4))
    end

    """
        paint_color(data,t::PacketTables,cmd::Int,p::PointD)::Pixel

    Evaluate the solid or gradient paint at a physical sample point.
    """
    function paint_color(data,t::PacketTables,cmd::Int,p::PointD)::Pixel
        first::Int = t.stop+5*intword(data,cmd+8)
        count::Int = intword(data,cmd+9)
        pos::Float64 = p.x*at_offset(data.words,cmd+10)+p.y*at_offset(data.words,cmd+11)+at_offset(data.words,cmd+12)
        left::Pixel = stop_color(data,first)
        if count==1 || pos<at_offset(data.words,first)
            return left
        end
        for i in 1:(count-1)
            right::Int = first+5*i
            next::Pixel = stop_color(data,right)
            if pos<at_offset(data.words,right)
                w::Float32 = Float32((pos-at_offset(data.words,right-5))/(at_offset(data.words,right)-at_offset(data.words,right-5)))
                return left*(1f0-w)+next*w
            end
            left=next
        end
        return left
    end

    """
        texel_color(data,t::PacketTables,r::Int,paged::Bool,xy::PointI)::Pixel

    Locate a dense or sparse page texel. An absent logical page samples transparent black.
    """
    function texel_color(data,t::PacketTables,r::Int,paged::Bool,xy::PointI)::Pixel
        x::Int = clamp(xy.x,intword(data,r+3),intword(data,r+5))
        y::Int = clamp(xy.y,intword(data,r+4),intword(data,r+6))
        slot::Int = intword(data,r)
        stride::Int = intword(data,r+1)
        if paged
            px::Int = x÷64
            py::Int = y÷64
            lo::Int = slot
            hi::Int = slot+stride
            while lo<hi
                mid::Int = (lo+hi)÷2
                key::Int = t.page+5*mid
                row::Int = intword(data,key+1)
                if row<py || (row==py && intword(data,key)<px)
                    lo=mid+1
                else
                    hi=mid
                end
            end
            entry::Int = t.page+5*lo
            if lo==slot+stride || intword(data,entry)!=px || intword(data,entry+1)!=py
                return Pixel(0,0,0,0)
            end
            slot=intword(data,entry+2)
            stride=intword(data,entry+3)
            x-=64*px
            y-=64*py
        end
        return unpack_color(at_offset(data.texels,Int(at_offset(data.base,slot))+y*stride+x))
    end

    """
        image_color(data,t::PacketTables,cmd::Int,paged::Bool,p::PointD)::Pixel

    Apply the physical-to-source transform and clamp the filter footprint to the declared source crop.
    """
    function image_color(data,t::PacketTables,cmd::Int,paged::Bool,p::PointD)::Pixel
        r::Int = t.raster+14*intword(data,cmd+8)
        x::Float64 = at_offset(data.words,r+8)*p.x+at_offset(data.words,r+10)*p.y+at_offset(data.words,r+12)
        y::Float64 = at_offset(data.words,r+9)*p.x+at_offset(data.words,r+11)*p.y+at_offset(data.words,r+13)
        xy::PointD = PointD(clamp(x,at_offset(data.words,r+3),at_offset(data.words,r+5)+1.0),
                            clamp(y,at_offset(data.words,r+4),at_offset(data.words,r+6)+1.0))
        if intword(data,r+7)==0
            return texel_color(data,t,r,paged,floor_point(xy))
        end
        xy=xy-PointD(0.5,0.5)
        a::PointI = floor_point(xy)
        wx::Float32 = Float32(xy.x-a.x)
        wy::Float32 = Float32(xy.y-a.y)
        upper::Pixel = texel_color(data,t,r,paged,a)*(1f0-wx)+texel_color(data,t,r,paged,a+PointI(1,0))*wx
        lower::Pixel = texel_color(data,t,r,paged,a+PointI(0,1))*(1f0-wx)+texel_color(data,t,r,paged,a+PointI(1,1))*wx
        return upper*(1f0-wy)+lower*wy
    end

    """
        composite_pixel(dst::Pixel,src::Pixel,multiply::Bool)::Pixel

    Composite premultiplied pixels with source-over or multiply blending.
    """
    function composite_pixel(dst::Pixel,src::Pixel,multiply::Bool)::Pixel
        if !multiply
            return src+dst*(1f0-src[4])
        end
        mixed::Pixel = src*(1f0-dst[4])+dst*(1f0-src[4])
        return Pixel(mixed[1]+src[1]*dst[1],mixed[2]+src[2]*dst[2],mixed[3]+src[3]*dst[3],src[4]+dst[4]*(1f0-src[4]))
    end

    """
        packet_tables(data)::PacketTables

    Resolve the geometry, paint and resident-source table offsets for one draw packet.
    """
    function packet_tables(data)::PacketTables
        shape::Int = 10+14*intword(data,4)
        contour::Int = shape+8*intword(data,5)
        point::Int = contour+6*intword(data,6)
        stop::Int = point+2*intword(data,7)
        raster::Int = stop+5*intword(data,8)
        page::Int = 0
        if intword(data,0)==20261123
            page=raster+2+14*intword(data,raster)
            raster+=2
        end
        return PacketTables(shape,contour,point,stop,raster,page)
    end

    """
        draw_pixel(data,pixel::PointI)::UInt32

    Rasterize one physical pixel with a 4 × 4 sample grid and isolated group composition.
    """
    function draw_pixel(data,pixel::PointI)::UInt32
        t::PacketTables = packet_tables(data)
        layers::LayerStack = LayerStack(undef)
        layers[1]=Pixel(0,0,0,0)
        depth::Int = 1
        for i in 0:(intword(data,4)-1)
            c::Int = 10+14*i
            op::Int = intword(data,c)
            if op==1
                depth+=1
                layers[depth]=Pixel(0,0,0,0)
                continue
            end
            opacity::Float32 = Float32(at_offset(data.words,c+6))
            multiply::Bool = intword(data,c+7)!=0
            if op==2
                top::Pixel = layers[depth]*opacity
                depth-=1
                layers[depth]=composite_pixel(layers[depth],top,multiply)
                continue
            end
            id::Int = intword(data,c+3)
            s::Int = t.shape+8*id
            if pixel.x+1<=at_offset(data.words,s+3) || pixel.y+1<=at_offset(data.words,s+4) ||
                    pixel.x>=at_offset(data.words,s+5) || pixel.y>=at_offset(data.words,s+6)
                continue
            end
            clips::Int = intword(data,c+5)
            hits::Int = 0
            color::Pixel = Pixel(0,0,0,0)
            for y in 0:3
                for x in 0:3
                    p::PointD = PointD(pixel.x+(x+0.5)/4,pixel.y+(y+0.5)/4)
                    if !inside_shape(data,t,id,p)
                        continue
                    end
                    covered::Bool = true
                    for j in 0:(clips-1)
                        if !inside_shape(data,t,intword(data,c+4)+j,p)
                            covered=false
                            break
                        end
                    end
                    if !covered
                        continue
                    end
                    hits+=1
                    if op==0
                        color+=paint_color(data,t,c,p)
                    elseif op==4 || op==5
                        color+=image_color(data,t,c,op==5,p)
                    end
                end
            end
            if op==3
                layers[depth]*=1f0-Float32(hits)/16
            else
                layers[depth]=composite_pixel(layers[depth],color*(opacity/16),multiply)
            end
        end
        return pack_color(layers[1])
    end
end

end
