export write_p6

function export_current(source,metadata,revision,cancelled)
    cancelled() && throw(InterruptException())
    source_revision(source)==revision ||
        throw(ArgumentError("requested export revision is no longer available"))
    S.image_metadata(source)==metadata ||
        throw(ArgumentError("source metadata changed during export"))
    nothing
end

function p6_write!(io,bytes)
    write(io,bytes)==length(bytes) || throw(ErrorException("short P6 write"))
    nothing
end

"""
Stream P6 RGB8/sRGB row segments without closing IO/source.
Alpha-bearing metadata requires a unit-sRGB matte. Failure can leave partial IO.
"""
function write_p6(io::IO,source::S.AbstractImageProvider;chunk_pixels::Integer=1024,
                  workspace_bytes::Integer=1024*1024,copy_bytes::Integer=1024*1024*1024,
                  max_pixels::Integer=128*1024*1024,max_output_bytes::Integer=512*1024*1024,
                  matte=nothing,revision=source_revision(source),cancelled=()->false)
    all(v->0<v<=typemax(Int),(chunk_pixels,workspace_bytes,copy_bytes,max_pixels,max_output_bytes)) ||
        throw(ArgumentError("P6 sizes and budgets must be positive and addressable"))
    revision isa Integer && 0<=revision<=typemax(UInt64) ||
        throw(ArgumentError("invalid export revision"))
    metadata=S.image_metadata(source)
    metadata isa S.ImageMetadata || throw(ArgumentError("provider must return ImageStorage.ImageMetadata"))
    export_current(source,metadata,revision,cancelled)
    pixels=Base.checked_mul(metadata.width,metadata.height)
    pixels<=max_pixels || throw(ArgumentError("P6 source pixel-work budget exceeded"))
    payload=Base.checked_mul(pixels,3)
    header="P6\n$(metadata.width) $(metadata.height)\n255\n"
    total=Base.checked_add(ncodeunits(header),payload)
    total<=max_output_bytes || throw(ArgumentError("P6 encoded output budget exceeded"))
    payload<=copy_bytes || throw(ArgumentError("P6 minimum conversion copy budget exceeded"))
    chunk=Int(min(chunk_pixels,metadata.width))
    n=Base.checked_mul(chunk,3)
    Base.checked_add(ncodeunits(header),n)<=workspace_bytes ||
        throw(ArgumentError("P6 workspace cannot hold header and one RGB segment"))
    metadata.alpha==:none || matte!==nothing ||
        throw(ArgumentError("P6 alpha removal requires an explicit unit-sRGB matte"))
    if matte!==nothing
        matte isa Union{Tuple,AbstractVector} && length(matte)==3 &&
            all(v->v isa Real && isfinite(v) && 0<=v<=1,matte) ||
            throw(ArgumentError("matte must contain three finite unit-sRGB channels"))
    end
    background=matte===nothing ? nothing : Tuple(Float64.(matte))
    export_current(source,metadata,revision,cancelled)
    p6_write!(io,codeunits(header))
    written=ncodeunits(header)
    copied=requests=provider_peak=0
    buffer_peak=ncodeunits(header)
    for y in 0:metadata.height-1,x in 0:chunk:metadata.width-1
        export_current(source,metadata,revision,cancelled)
        width=min(chunk,metadata.width-x)
        rgb_bytes=3width
        budget=min(Int(workspace_bytes)-ncodeunits(header),Int(copy_bytes)-copied)
        result=S.convert_buffer(source;region=(x,y,width,1),format=:rgb8,alpha=:none,
                                color_space=:srgb,matte=background,budget_bytes=budget)
        try
            requests+=1
            copied=Base.checked_add(copied,result.report.copied_bytes)
            provider_peak=max(provider_peak,result.report.copied_bytes-rgb_bytes)
            buffer_peak=max(buffer_peak,ncodeunits(header)+result.report.copied_bytes)
            export_current(source,metadata,revision,cancelled)
            S.with_pixels(result.buffer) do lease
                # The conversion owns precisely this packed segment until write returns.
                p6_write!(io,lease.buffer.owner.bytes)
            end
            written=Base.checked_add(written,rgb_bytes)
            export_current(source,metadata,revision,cancelled)
        finally
            close(result.buffer)
        end
    end
    flush(io)
    export_current(source,metadata,revision,cancelled)
    (;written_bytes=written,copied_bytes=copied,source_pixels=pixels,source_requests=requests,
      peak_buffer_bytes=buffer_peak,provider_staging_peak_bytes=provider_peak,
      workspace_budget=Int(workspace_bytes),segment_limit=chunk,revision=UInt64(revision))
end

"""Atomically replace a path only after a successful, flushed and closed same-directory temporary."""
function write_p6(path::AbstractString,source::S.AbstractImageProvider;
                  revision=source_revision(source),cancelled=()->false,kwargs...)
    metadata=S.image_metadata(source)
    export_current(source,metadata,revision,cancelled)
    destination=abspath(path)
    temporary,io=mktemp(dirname(destination))
    try
        report=write_p6(io,source;revision,cancelled,kwargs...)
        close(io)
        export_current(source,metadata,revision,cancelled)
        # Use the runtime rename primitive, never a copy/remove fallback.
        err=ccall(:jl_fs_rename,Int32,(Cstring,Cstring),temporary,destination)
        err<0 && Base.uv_error("atomic P6 rename",err)
        report
    finally
        try
            isopen(io) && close(io)
        finally
            ispath(temporary) && rm(temporary)
        end
    end
end
