"""Maximum combined output and filter scratch per unpublished Vulkan buffer, in bytes."""
const MAX_FILTER_BUFFER_BYTES = 128*1024*1024

"""
    filtered_group_ends(words)

Map group entry commands to their matching exit when the group or a descendant
needs a spatial pass. Ordinary isolated groups can stay inside a geometry dispatch.
Command numbers are zero-based in draw packets.
"""
function filtered_group_ends(words)
    count = Int(words[5])
    ends = Dict{Int,Int}()
    stack = Int[]
    for i in 0:count-1
        c = 11+14*i
        if words[c] == 1
            push!(stack,i)
        elseif words[c] == 2
            first = pop!(stack)
            if haskey(ends,first) || words[c+3]>0 || words[c+4]>0
                ends[first] = i
                isempty(stack) || (ends[last(stack)] = -1)
            end
        end
    end
    return ends
end

"""
    queue_layer!(passes, ends, words, first, stop, width, height, x, y, dst)

Schedule geometry and separable filters for one isolated layer. Children expand
their physical bounds by their filter radius. Siblings reuse the same scratch
after composition. Return the peak output size in 32-bit words.
"""
function queue_layer!(passes,ends,words,first,stop,width,height,x,y,dst)
    next = dst + 4*width*height
    peak = next
    next <= MAX_FILTER_BUFFER_BYTES÷4 || throw(ArgumentError("Vulkan filter scratch exceeds 128 MiB"))
    segment = first
    src = -1
    i = first
    while i < stop
        last = get(ends,i,-1)
        if last < 0
            i += 1
            continue
        end
        push!(passes,QueueKernel.DrawPass(1,width,height,x,y,segment,i,src,dst,0,0,0))
        c = 11+14*last
        rx,ry = Int(words[c+3]),Int(words[c+4])
        cw,ch = width+2rx,height+2ry
        child_peak = queue_layer!(passes,ends,words,i+1,last,cw,ch,x-rx,y-ry,next)
        peak = max(peak,child_peak)
        filtered = next
        if rx > 0
            filtered = next + 4*cw*ch
            peak = max(peak,filtered+4*width*ch)
            peak <= MAX_FILTER_BUFFER_BYTES÷4 || throw(ArgumentError("Vulkan filter scratch exceeds 128 MiB"))
            push!(passes,QueueKernel.DrawPass(2,width,ch,0,0,0,0,next,filtered,cw,rx,0))
        end
        push!(passes,QueueKernel.DrawPass(3,width,height,0,0,last,0,filtered,dst,width,rx,ry))
        i = last+1
        segment = i
        src = dst
    end
    if segment < stop || src < 0
        push!(passes,QueueKernel.DrawPass(1,width,height,x,y,segment,stop,src,dst,0,0,0))
    end
    return peak
end

"""
    queue_dispatches(words, size)

Plan a single draw for effect-free frames. For filtered frames, allocate float
scratch above the final RGBA8 pixels and return the dispatches and bounded byte
requirement. The published buffer remains independent of this candidate.
"""
function queue_dispatches(words,size)
    width,height = size
    count = Int(words[5])
    result = width*height
    ends = filtered_group_ends(words)
    passes = QueueKernel.DrawPass[]
    if isempty(ends)
        push!(passes,QueueKernel.DrawPass(0,width,height,0,0,0,count,-1,0,0,0,0))
        return passes,4*result
    end
    peak = queue_layer!(passes,ends,words,0,count,width,height,0,0,result)
    push!(passes,QueueKernel.DrawPass(4,width,height,0,0,0,0,result,0,0,0,0))
    return passes,4*peak
end
