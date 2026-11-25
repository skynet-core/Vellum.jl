export Previewer, request!, take_ready!, cancel!, preview_stats

struct PreviewRequest
    ticket::UInt64
    refined::ViewRequest
    preview::ViewRequest
    cancelled::Threads.Atomic{Bool}
    host_time::Float64
    submitted_ns::UInt64
end

"""Owned completed pixels (or explicit failure); close the lease when no longer needed."""
struct PreparedRegion
    ticket::UInt64
    phase::Symbol
    view::ViewRequest
    pixels::Union{Nothing,S.PixelLease}
    error::Any
    host_time::Float64
    submitted_ns::UInt64
    completed_ns::UInt64
end
Base.close(result::PreparedRegion)=(result.pixels===nothing || close(result.pixels);nothing)

mutable struct Previewer{P}
    pyramid::P
    guard::ReentrantLock
    changed::Threads.Condition
    pending::Union{Nothing,PreviewRequest}
    active::Union{Nothing,PreviewRequest}
    ready::Union{Nothing,PreparedRegion}
    generation::UInt64
    closed::Bool
    task::Union{Nothing,Task}
    replaced::Int
    completed::Int
    discarded::Int
    pending_peak::Int
    active_peak::Int
    output_peak::Int
    working_bytes::Int
end

"""One worker, one latest pending viewport and one completion slot; explicit close is required."""
function Previewer(p::Pyramid)
    p.closed && throw(ArgumentError("pyramid is closed"))
    guard=ReentrantLock()
    worker=Previewer(p,guard,Threads.Condition(guard),nothing,nothing,nothing,UInt64(0),
                     false,nothing,0,0,0,0,0,0,0)
    worker.task=Threads.@spawn preview_loop(worker)
    worker
end

function release_ready!(worker)
    worker.ready===nothing || close(worker.ready)
    worker.ready=nothing
end

"""Latest-wins by default; replace=false rejects saturation without mutating current work."""
function request!(worker::Previewer,region;zoom=1,dpi=1,halo=0,revision=S.storage_revision(worker.pyramid),
                  preview::Bool=true,replace::Bool=true,host_time::Real=0)
    isfinite(host_time) && isfinite(Float64(host_time)) ||
        throw(ArgumentError("host_time must be finite"))
    p=worker.pyramid
    refined=view_request(p,region;zoom,dpi,halo,revision)
    coarse=preview && refined.level<max_level(p) ?
        view_request(p,region;zoom,dpi,halo,revision,level=refined.level+1) : refined
    validate_view(p,refined)
    validate_view(p,coarse)
    # Admission never takes the pyramid/provider lock held by blocking preparation.
    lock(worker.guard) do
        worker.closed && throw(ArgumentError("previewer is closed"))
        !replace && (worker.pending!==nothing || worker.active!==nothing || worker.ready!==nothing) &&
            throw(ArgumentError("preview queue is full"))
        ticket=Base.checked_add(worker.generation,UInt64(1))
        for request in (worker.pending,worker.active)
            if request!==nothing
                request.cancelled[]=true
                worker.replaced+=1
            end
        end
        release_ready!(worker)
        worker.generation=ticket
        worker.pending=PreviewRequest(ticket,refined,coarse,Threads.Atomic{Bool}(false),
                                      Float64(host_time),time_ns())
        worker.pending_peak=1
        notify(worker.changed;all=true)
        ticket
    end
end

function current_request(worker,request)
    !worker.closed && !request.cancelled[] && worker.generation==request.ticket
end
function publish!(worker,request,result)
    lock(worker.guard) do
        worker.working_bytes=0
        valid=current_request(worker,request)
        stale=false
        if valid && result.error===nothing
            stale=!try
                source_revision(worker.pyramid.source)==result.view.revision
            catch
                false
            end
        end
        if !valid
            close(result)
            worker.discarded+=1
            return false
        end
        if stale
            close(result)
            request.cancelled[]=true
            worker.discarded+=1
            result=PreparedRegion(result.ticket,:failed,result.view,nothing,
                ArgumentError("completed source revision is no longer current"),
                result.host_time,result.submitted_ns,result.completed_ns)
        end
        release_ready!(worker)
        worker.ready=result
        worker.output_peak=max(worker.output_peak,result.pixels===nothing ? 0 :
            S.descriptor_extent(result.pixels.buffer.descriptor))
        worker.completed+=1
        notify(worker.changed;all=true)
        !stale
    end
end

function preview_loop(worker)
    while true
        request=lock(worker.guard) do
            while !worker.closed && worker.pending===nothing
                wait(worker.changed)
            end
            worker.closed && return nothing
            next=worker.pending
            worker.pending=nothing
            worker.active=next
            worker.active_peak=1
            next
        end
        request===nothing && return nothing
        try
            phases=request.preview.level==request.refined.level ?
                ((:refined,request.refined),) : ((:preview,request.preview),(:refined,request.refined))
            for (phase,view) in phases
                request.cancelled[] && break
                bytes=validate_view(worker.pyramid,view)
                lock(worker.guard) do
                    worker.working_bytes=bytes
                    worker.output_peak=max(worker.output_peak,bytes)
                end
                # Long-lived workers must see provider callbacks defined after worker creation.
                cancelled=let token=request.cancelled
                    ()->token[]
                end
                pixels=Base.invokelatest(prepare_region,worker.pyramid,view;cancelled)
                result=PreparedRegion(request.ticket,phase,view,pixels,nothing,request.host_time,
                                      request.submitted_ns,time_ns())
                publish!(worker,request,result) || break
                # Refinement cannot overwrite an unconsumed preview; this is output backpressure.
                if phase==:preview
                    lock(worker.guard) do
                        while current_request(worker,request) && worker.ready===result
                            wait(worker.changed)
                        end
                    end
                end
            end
        catch error
            result=PreparedRegion(request.ticket,:failed,request.refined,nothing,error,
                                  request.host_time,request.submitted_ns,time_ns())
            publish!(worker,request,result)
        finally
            lock(worker.guard) do
                worker.active=nothing
                worker.working_bytes=0
                notify(worker.changed;all=true)
            end
        end
    end
end

"""Transfer the completed slot to its caller; wait=true blocks, and failures remain explicit results."""
function take_ready!(worker::Previewer;wait::Bool=false)
    lock(worker.guard) do
        while true
            if worker.ready!==nothing
                result=worker.ready
                worker.ready=nothing
                notify(worker.changed;all=true)
                valid=result.error!==nothing || try
                    source_revision(worker.pyramid.source)==result.view.revision
                catch
                    false
                end
                valid && return result
                close(result)
                worker.discarded+=1
                if worker.active!==nothing && worker.active.ticket==result.ticket
                    worker.active.cancelled[]=true
                end
                return PreparedRegion(result.ticket,:failed,result.view,nothing,
                    ArgumentError("completed source revision is no longer current"),
                    result.host_time,result.submitted_ns,result.completed_ns)
            end
            (!wait || worker.closed || (worker.active===nothing && worker.pending===nothing)) &&
                return nothing
            Base.wait(worker.changed)
        end
    end
end

function cancel!(worker::Previewer)
    lock(worker.guard) do
        worker.generation=Base.checked_add(worker.generation,UInt64(1))
        for request in (worker.pending,worker.active)
            request===nothing || (request.cancelled[]=true)
        end
        worker.pending=nothing
        release_ready!(worker)
        notify(worker.changed;all=true)
    end
    nothing
end
function Base.close(worker::Previewer)
    lock(worker.guard) do
        if !worker.closed
            worker.closed=true
            cancel!(worker)
        end
    end
    # A blocking provider must return before shutdown can join the worker.
    wait(worker.task)
    nothing
end
function preview_stats(worker::Previewer)
    lock(worker.guard) do
        (;pending=worker.pending===nothing ? 0 : 1,active=worker.active===nothing ? 0 : 1,
          outputs=worker.ready===nothing ? 0 : 1,pending_peak=worker.pending_peak,
          active_peak=worker.active_peak,output_peak_bytes=worker.output_peak,
          working_bytes=worker.working_bytes,
          output_payload_bound=2*Int128(worker.pyramid.output_bytes),
          replaced=worker.replaced,completed=worker.completed,discarded=worker.discarded,closed=worker.closed)
    end
end
