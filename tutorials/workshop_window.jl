"""Open a workshop on the chosen host and forward its Vellum frames and shared input table."""
function show_window(app,platform;target=:cpu,before_swap=nothing)
    Vellum.GLHost.run_interactive(app;platform=platform===:desktop ? nothing : platform,target,before_swap,
                                 reduced_motion=get(ENV,"VELLUM_REDUCED_MOTION","0")=="1")
end
