"""Previous pointer, keyboard and focus state for interpreting one native window's inputs."""
Base.@kwdef mutable struct InputState
    focus::Int = 0
    keyboard::Bool = false
    pressed::Int = 0
    keypress::Int = 0
    previous_mouse::Bool = false
    previous_keys::Set{Int} = Set{Int}()
    feedback::Int = 0
end

"""Map a logical pointer coordinate into one of a control's activation columns."""
function control_action(controls,index,x)
    c = controls[index]
    stop = if c.kind === :segments
        clamp(1+floor(Int,(x-c.rect[1])*c.steps/c.rect[3]),1,c.steps)
    else
        1+round(Int,clamp((x-c.rect[1])/c.rect[3],0,1)*(c.steps-1))
    end
    return sum(a.steps for a in @view(controls[1:index-1]);init=stop)
end

"""Emit visual feedback and activation actions in order. A button commits on release inside its hit area."""
function input_actions!(input,app,state,x,y,mouse,keys;focused=true)
    controls = app.controls
    hit = focused ? something(findfirst(controls) do c
        l,t,w,h = c.rect
        l <= x < l+w && t <= y < t+h
    end,0) : 0
    actions = Int[]
    commit = 0
    if !focused
        input.pressed = input.keypress = input.focus = 0
        input.keyboard = false
    elseif mouse && !input.previous_mouse
        input.pressed = input.focus = hit
        input.keyboard = false
        input.keypress = 0
    elseif !mouse && input.previous_mouse
        if input.pressed != 0 && hit == input.pressed && controls[hit].kind !== :range
            commit = control_action(controls,hit,x)
        end
        input.pressed = 0
    end
    if mouse && input.pressed > 0 && controls[input.pressed].kind === :range
        commit = control_action(controls,input.pressed,x)
    end
    if focused
        if 258 in keys && !(258 in input.previous_keys)
            backwards = 340 in keys || 344 in keys
            input.focus = input.focus == 0 ? (backwards ? length(controls) : 1) :
                mod1(input.focus+(backwards ? -1 : 1),length(controls))
            input.keyboard = true
            input.keypress = 0
        elseif input.focus > 0
            c = controls[input.focus]
            for k in (262,263,32,257)
                if k in keys && !(k in input.previous_keys)
                    input.keyboard = true
                    if c.kind in (:range,:segments) && k in (262,263)
                        stop = clamp(app.values[state,input.focus]+(k==262 ? 1 : -1),1,c.steps)
                        commit = sum(a.steps for a in @view(controls[1:input.focus-1]);init=stop)
                    elseif c.kind in (:button,:switch) && k in (32,257)
                        input.keypress = k
                    end
                end
            end
            if input.keypress != 0 && !(input.keypress in keys)
                commit = control_action(controls,input.focus,c.rect[1])
                input.keypress = 0
            end
        end
    end
    if app.feedback
        control,phase = if input.keypress != 0
            (input.focus,:press)
        elseif input.pressed != 0 && hit == input.pressed
            (hit,:press)
        elseif input.keyboard && input.focus != 0
            (input.focus,:focus)
        elseif hit != 0
            (hit,:hover)
        else
            (0,:idle)
        end
        feedback = Vellum.feedback_action(controls,control,phase)
        if feedback != input.feedback
            push!(actions,feedback)
            input.feedback = feedback
        end
    end
    commit > 0 && push!(actions,commit)
    input.previous_mouse,input.previous_keys = mouse,keys
    return actions
end

"""
    run_interactive(app; platform=nothing, target=:cpu, reduced_motion=false, before_swap)

Open a desktop window for an interactive Vellum drawing. Set `platform` to
`:wayland` or `:x11` on Linux, or leave it unset for the system default.
Pointer, keyboard and clock actions use the same transition table as browser Wasm.
`before_swap(window, state, image)` receives each completed presentation.
"""
function run_interactive(app;platform=nothing,target=:cpu,reduced_motion=false,before_swap=nothing)
    width,height = Int.(first(app.frames).size)
    with_frame_window(width,height,app.title;platform,target) do window,present
        state = 1
        input = InputState()
        delay = app.timers[state][1]
        deadline = delay == 0 ? Inf : time_ns()/1e6+delay
        previous = nothing
        while !should_close(window)
            poll_events(window)
            extent = framebuffer_size(window)
            win = window_size(window)
            if minimum((extent...,win...)) <= 0
                wait_events(window,0.05)
                continue
            end
            cx,cy = cursor_position(window)
            keys = Set(k for k in (32,256,257,258,262,263,340,344) if key_state(window,k) != 0)
            256 in keys && break
            focused = ccall(symbol(window.library,:glfwGetWindowAttrib),Cint,(Ptr{Cvoid},Cint),window.handle,0x00020001) != 0
            actions = input_actions!(input,app,state,cx*width/win[1],cy*height/win[2],
                mouse_button_state(window,0) != 0,keys;focused)
            now = time_ns()/1e6
            isempty(actions) && now >= deadline && push!(actions,app.timers[state][2])
            if !isempty(actions)
                for action in actions
                    state = app.transitions[state,action]
                end
                if reduced_motion && app.feedback
                    seen = Set{Int}()
                    while app.timers[state][1] > 0 && !(state in seen)
                        push!(seen,state)
                        state = app.transitions[state,app.timers[state][2]]
                    end
                end
                delay = app.timers[state][1]
                deadline = delay == 0 ? Inf : now+delay
            end
            if (state,extent) != previous
                present(app.frames[state];before_swap=isnothing(before_swap) ? nothing : image->before_swap(window,state,image))
                previous = (state,extent)
            end
            wait_events(window,0.012)
        end
    end
end
