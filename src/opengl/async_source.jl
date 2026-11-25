"""Owned drawing words, reusable host geometry, and source bytes for one native submission."""
struct StagedFrame
    words::Vector{Float64}
    assets::RasterPages.Resident
    shapes::FrameCurves.ShapeCache
    uploads::Vector{RasterAssets.StagedUpload}
end

"""Queued semantic snapshot and the exact resident or in-flight base it was measured against."""
struct SourceWork
    number::UInt64
    base::UInt64
    frame::Vetra.Frame
    resident::RasterPages.Resident
    shapes::FrameCurves.ShapeCache
end

"""A prepared request, including its base identity and host-owned staging memory."""
struct SourceResult
    work::SourceWork
    staged::StagedFrame
end

"""
    SourceQueue

One worker, one replaceable request and one latest staged result per initialized
surface. `changed` owns the scheduler state. `live` is the cancellation check
used outside that lock by the packing and source code.
"""
mutable struct SourceQueue
    changed::Threads.Condition
    live::Threads.Atomic{UInt64}
    number::UInt64
    revision::UInt64
    state::Symbol
    active::Bool
    pending::Union{Nothing,SourceWork}
    result::Union{Nothing,SourceResult}
    failure::Any
    worker::Union{Nothing,Task}
end

"""Opaque ticket for one request to prepare an initialized OpenGL or Vulkan surface."""
struct Preparation
    queue::SourceQueue
    number::UInt64
    revision::UInt64
end

"""
    stage_frame(plan, size, resident, registry; cancelled, shapes, blur_radius) -> StagedFrame

Pack geometry within the negotiated blur limit and stage changed source
ranges. Cancellation and provider errors propagate before any native work.
Optional exclusive `workspace` is synchronous caller-owned scratch; staged
words and source bytes are independently owned. Background jobs do not share it.
"""
function stage_frame(plan,size,resident,registry;cancelled=()->false,shapes=FrameCurves.EMPTY_SHAPES,
                     blur_radius=BoxBlurPlan.LEGACY_RADIUS,workspace=nothing)
    RasterPages.check_cancelled(cancelled)
    packet = pack_frame(plan,size,resident;shapes,blur_radius,workspace)
    uploads = RasterPages.stage_uploads(plan,resident,packet.assets,registry;cancelled)
    return StagedFrame(packet.words,packet.assets,packet.shapes,uploads)
end

"""
    prepare_source_job(work, backend, size, cancelled) -> SourceResult

Acquire exact source pins and build owned staging bytes. Always close the
prepared semantic plan before returning. A withdrawn or unavailable source
raises, leaving GPU state untouched.
"""
function prepare_source_job(work,backend,size,cancelled)
    RasterPages.check_cancelled(cancelled)
    plan = Vetra.prepare(backend,work.frame)
    try
        staged = stage_frame(plan,size,work.resident,backend.raster_registry;
                             cancelled,shapes=work.shapes,blur_radius=box_blur_radius(backend))
        return SourceResult(work,staged)
    finally
        close(plan)
    end
end

"""Wait for one queued request or shutdown. Return `nothing` on shutdown."""
function next_source!(queue::SourceQueue)
    lock(queue.changed) do
        while queue.pending === nothing && queue.state !== :closed
            wait(queue.changed)
        end
        queue.state === :closed && return nothing
        work = queue.pending::SourceWork
        queue.pending = nothing
        queue.active = true
        queue.state = :loading
        return work
    end
end

"""Publish a result or failure only while the request is current. Release worker activity in either case."""
function publish_source!(queue,work,result,failure)
    lock(queue.changed) do
        queue.active = false
        if queue.live[] == work.number
            queue.result = result
            queue.failure = failure
            queue.state = result === nothing ? :failed : :ready
        end
    end
    return nothing
end

"""
    source_loop(queue, backend, size) -> nothing

Stage requests in the worker pool until shutdown. Provider exceptions go
to the current ticket. Superseded work has no publisher or GPU access.
"""
function source_loop(queue,backend,size)
    while true
        work = next_source!(queue)
        work === nothing && return nothing
        # Each job starts in the current method world so new provider methods
        # defined by a long-running REPL or IJulia session remain available.
        number = work.number
        try
            result = Base.invokelatest(prepare_source_job,work,backend,size,()->queue.live[] != number)
            publish_source!(queue,work,result,nothing)
            result = nothing
        catch error
            publish_source!(queue,work,nothing,error)
        end
        work = nothing
    end
end

"""
    start_sources(backend, size) -> SourceQueue

Start one sleeping worker in the Julia pool opposite the current thread.
Throw `ArgumentError` when no separate pool is available.
"""
function start_sources(backend,size)
    pool = Threads.threadpool() === :interactive ? :default : :interactive
    Threads.nthreads(pool) > 0 || throw(ArgumentError("start Julia with --threads=2,1 for asynchronous GPU preparation"))
    queue = SourceQueue(Threads.Condition(),Threads.Atomic{UInt64}(0),0,0,:idle,false,nothing,nothing,nothing,nothing)
    queue.worker = Threads.@spawn pool source_loop(queue,backend,size)
    return queue
end

"""
    request_source!(queue, base, frame, resident, shapes) -> Preparation

Retain only the newest unsubmitted snapshot and discard older staged data.
An identical current revision returns the existing ticket. Stale revisions
and exhausted ticket identities throw before altering the queue.
"""
function request_source!(queue,base,frame,resident,shapes)
    lock(queue.changed) do
        if queue.state in (:queued,:loading,:ready)
            frame.revision < queue.revision && throw(ArgumentError("request is older than the current preparation"))
            frame.revision == queue.revision && return Preparation(queue,queue.number,queue.revision)
        end
        number = Base.checked_add(queue.number,UInt64(1))
        queue.live[] = number
        queue.number = number
        queue.revision = frame.revision
        queue.state = :queued
        queue.pending = SourceWork(number,base,frame,resident,shapes)
        queue.result = nothing
        queue.failure = nothing
        notify(queue.changed)
        return Preparation(queue,number,frame.revision)
    end
end

"""
    preparation_status(ticket::Preparation) -> Symbol

Report `:queued`, `:loading`, `:ready`, `:failed`, `:cancelled`, `:submitted`,
`:superseded` or `:closed`. A concurrent upload claim reports `:submitting`.
This query uses no driver calls and is safe from any Julia thread.
"""
function preparation_status(ticket::Preparation)
    queue = ticket.queue
    lock(queue.changed) do
        queue.state === :closed && return :closed
        return ticket.number == queue.number ? queue.state : :superseded
    end
end

"""Drop obsolete queue state under its lock and invalidate any current worker generation."""
function clear_source!(queue::SourceQueue,state)
    queue.live[] = 0
    queue.pending = nothing
    queue.result = nothing
    queue.failure = nothing
    queue.state = state
    notify(queue.changed)
    return nothing
end

"""A surface without a worker has no preparations to invalidate."""
invalidate_sources!(::Nothing) = nothing

"""Discard any current ticket after the surface changes independently."""
function invalidate_sources!(queue::SourceQueue)
    lock(queue.changed) do
        clear_source!(queue,:superseded)
    end
end

"""Tear down an unused source queue without creating a worker."""
stop_sources!(::Nothing) = nothing

"""Cancel remaining work and join the worker after any active provider callback returns."""
function stop_sources!(queue::SourceQueue)
    lock(queue.changed) do
        clear_source!(queue,:closed)
    end
    wait(queue.worker::Task)
    return nothing
end

"""
    claim_source!(ticket, base) -> Union{Nothing,SourceResult}

Claim ready staging bytes for a single owner-thread submission. An active
source job returns `nothing`. Stale or consumed tickets throw, as does
the original error from a failed source job.
"""
function claim_source!(ticket,base)
    queue = ticket.queue
    lock(queue.changed) do
        ticket.number == queue.number || throw(ArgumentError("preparation was superseded"))
        state = queue.state
        state in (:queued,:loading) && return nothing
        state === :failed && throw(queue.failure)
        state === :ready || throw(ArgumentError("preparation is $state"))
        result = queue.result::SourceResult
        result.work.base == base || throw(ArgumentError("preparation has a stale GPU base"))
        queue.state = :submitting
        return result
    end
end

"""Finish the claim, dropping staged bytes after success or preserving them for retry."""
function finish_source!(ticket,submitted)
    queue = ticket.queue
    lock(queue.changed) do
        if submitted
            clear_source!(queue,:submitted)
        else
            queue.state = :ready
        end
    end
end

"""
    cancel!(ticket::Preparation) -> nothing

Withdraw a queued, loading or ready request. Cancellation is idempotent
and may be called from any Julia thread. A claimed upload and its native
fence belong to the owner thread. An active provider call can finish.
"""
function Vetra.cancel!(ticket::Preparation)
    queue = ticket.queue
    lock(queue.changed) do
        ticket.number == queue.number && queue.state in (:queued,:loading,:ready) &&
            clear_source!(queue,:cancelled)
    end
    return nothing
end
