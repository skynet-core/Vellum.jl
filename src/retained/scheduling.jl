"""
    ViewIdentity()

Stable object identity unique to one view. Holds no owning view reference.
"""
mutable struct ViewIdentity
end

"""
    ViewWork(owner, sequence, generation, frame, time)

Immutable request with issuing owner and pinned immutable scene frame, elapsed host
seconds.
"""
struct ViewWork
    owner::ViewIdentity
    sequence::UInt64
    generation::UInt64
    frame::Frame
    time::Float64
end

"""
    CanvasView

Host-thread-owned state with one in-flight, latest completed, and previously taken
ticket, uses host cadence.
"""
mutable struct CanvasView
    canvas::Canvas
    const owner::ViewIdentity
    generation::UInt64
    sequence::UInt64
    inflight::Union{Nothing,ViewWork}
    ready::Union{Nothing,ViewWork}
    presented::Union{Nothing,ViewWork}
    invalidated::Bool
    suspended::Bool
    closed::Bool
    continuous::Bool
    rate_limit::Union{Nothing,Float64}
    last_request::Float64
    last_clock::Float64
end
"""
    CanvasView(canvas; continuous=false, rate_limit=nothing)

Create independent view on canvas. Request on changes by default, continuously with
continuous=true. Optional requests per second must be finite and positive or `ModelError`.
"""
function CanvasView(canvas::Canvas; continuous::Bool=false, rate_limit=nothing)
    limit = rate_limit === nothing ? nothing : logical(rate_limit)
    limit === nothing || limit > 0 || model_error(:invalid_input,"rate limit must be positive")
    return CanvasView(canvas, ViewIdentity(), 0, 0, nothing, nothing, nothing, true, false, false, continuous, limit, -Inf, -Inf)
end
"""
    open_view(view)

Return nothing when open or throw `ModelError` when closed.
"""
function open_view(view::CanvasView)
    view.closed && model_error(:invalid_state,"view is closed")
    return nothing
end
"""
    invalidate!(view)

Advance generation, drop ready result, return nothing. Closed view or generation
overflow throws `ModelError`.
"""
function invalidate!(view::CanvasView)
    open_view(view)
    view.generation = next_revision(view.generation)
    view.invalidated = true
    view.ready = nothing
    return nothing
end
"""
    suspend!(view)

Suspend new requests and invalidate. Returns nothing. Same errors as `invalidate!`.
"""
function suspend!(view::CanvasView)
    invalidate!(view)
    view.suspended = true
    return nothing
end
"""
    resume!(view)

Resume new requests at host opportunity and invalidate. Returns nothing. Same errors as
`invalidate!`.
"""
function resume!(view::CanvasView)
    invalidate!(view)
    view.suspended = false
    return nothing
end
"""
    Base.close(view)

Idempotently discard scheduler state, return nothing. Host owns worker and surface
shutdown.
"""
function Base.close(view::CanvasView)
    view.closed = true
    view.inflight = view.ready = view.presented = nothing
    return nothing
end

"""
    request_work!(view, time; animate=nothing)

Return view-owned work ticket or nothing when idle, suspended, busy or rate limited.
Clock must be finite nondecreasing elapsed seconds. Callback animate(edit,time) runs
transactionally before snapshot and may throw. Closed view, invalid clock or sequence
exhaustion throws `ModelError`.
"""
function request_work!(view::CanvasView, time::Real; animate=nothing)
    open_view(view)
    now = logical(time)
    now >= view.last_clock || model_error(:invalid_input,"host clock moved backwards")
    view.last_clock = now
    view.suspended && return nothing
    view.inflight === nothing || return nothing
    view.rate_limit === nothing || now-view.last_request >= 1/view.rate_limit || return nothing
    current = snapshot(view.canvas)
    previous = view.ready === nothing ? view.presented : view.ready
    needed = view.invalidated || view.continuous || previous === nothing ||
        previous.frame.revision != current.revision
    needed || return nothing
    animate === nothing || transaction!(edit -> animate(edit,now),view.canvas)
    (view.closed || view.suspended) && return nothing
    frame = snapshot(view.canvas)
    sequence = next_revision(view.sequence)
    work = ViewWork(view.owner, sequence, view.generation, frame, now)
    view.inflight = work
    view.sequence,view.last_request,view.invalidated = sequence,now,false
    return work
end
"""
    valid_work(view, work)

Return true for issuing view, open and unsuspended, matching generation, current canvas
ID and revision. Side-effect free. May validate any issued ticket on current revision.
"""
function valid_work(view::CanvasView, work::ViewWork)
    if work.owner !== view.owner || view.closed || view.suspended || work.generation !== view.generation
        return false
    end
    current = snapshot(view.canvas)
    return current.canvas === work.frame.canvas && current.revision === work.frame.revision
end
"""
    complete!(view, work; success=true)

Return true when exact current in-flight ticket succeeds and is ready. Foreign or
duplicate returns false and leaves slots alone. Stale or failed own work frees the in-
flight slot and returns false.
"""
function complete!(view::CanvasView, work::ViewWork; success::Bool=true)
    view.inflight === work || return false
    view.inflight = nothing
    if !success || !valid_work(view,work)
        view.invalidated = !view.closed
        return false
    end
    view.ready = work
    return true
end
"""
    cancel!(view)

Invalidate, leave in-flight slot occupied until acknowledged, return nothing. Same
errors as `invalidate!`.
"""
function cancel!(view::CanvasView)
    invalidate!(view)
    return nothing
end
"""
    take_ready!(view)

Consume the ready slot and return its current ticket or nothing when absent or stale.
Closed view throws `ModelError`. Host does actual presentation.
"""
function take_ready!(view::CanvasView)
    open_view(view)
    work = view.ready
    work === nothing && return nothing
    view.ready = nothing
    valid_work(view,work) || return nothing
    view.presented = work
    return work
end
