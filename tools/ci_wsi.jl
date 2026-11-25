using Random

"""
    with_display_process(f,cmd,log,ready)

Run a test-owned display process until its socket is ready, execute the test and
reap the display on success, failure or interruption. Surface its log on failure.
"""
function with_display_process(f,cmd,log,ready;output=devnull)
    open(log,"w") do err
        process = run(pipeline(cmd;stdout=output,stderr=err);wait=false)
        try
            status = timedwait(() -> !process_running(process) || ready(),30;pollint=0.05)
            status === :ok && process_running(process) || error("display did not start")
            return f()
        catch
            flush(err)
            println(stderr,read(log,String))
            rethrow()
        finally
            process_running(process) && kill(process)
            timedwait(() -> !process_running(process),5) === :ok || kill(process,Base.SIGKILL)
            wait(process)
        end
    end
end

"""
    virtual_window_tests(cmd,root)

Check X11 window lifecycle and capture the final output of a private Wayland compositor.
Xvfb allocates a fresh display number and uses a private MIT cookie. Weston owns the
single 320 × 200 output. Only the test clients receive these display credentials.
"""
function virtual_window_tests(cmd,root)
    mktempdir() do dir
        auth = joinpath(dir,"authority")
        open(auth,"w";lock=false) do io
            # Xauthority FamilyWild matches the fresh display number announced by Xvfb.
            write(io,hton(typemax(UInt16)))
            for field in (UInt8[],UInt8[],codeunits("MIT-MAGIC-COOKIE-1"),rand(RandomDevice(),UInt8,16))
                write(io,hton(UInt16(length(field))),field)
            end
        end
        chmod(auth,0o600)
        number = joinpath(dir,"display")
        open(number,"w") do out
            xvfb = `Xvfb -displayfd 1 -nolisten tcp -auth $auth -screen 0 320x200x24`
            with_display_process(xvfb,joinpath(dir,"xvfb.log"),() -> occursin('\n',read(number,String));output=out) do
                display = ":"*string(parse(Int,strip(read(number,String))))
                private = ("DISPLAY"=>display,"XAUTHORITY"=>auth,"XDG_RUNTIME_DIR"=>dir)
                x11 = addenv(cmd,private...,"WAYLAND_DISPLAY"=>nothing,"GDK_BACKEND"=>"x11",
                    "VELLUM_TEST_VULKAN_WINDOW"=>"required","VELLUM_VULKAN_LIBRARY"=>nothing)
                run(`$x11 $(joinpath(root,"test","gdk_window.jl"))`)
                run(`$x11 $(joinpath(root,"test","vulkan_window.jl")) x11`)
                socket = "wayland-vellum"
                weston = addenv(`weston --backend=x11-backend.so --use-pixman --shell=kiosk-shell.so --width=320 --height=200 --no-input --idle-time=0 --no-config --socket=$socket`,
                    private...,"WAYLAND_DISPLAY"=>nothing)
                with_display_process(weston,joinpath(dir,"weston.log"),() -> ispath(joinpath(dir,socket))) do
                    child = addenv(cmd,private...,"WAYLAND_DISPLAY"=>socket,"VELLUM_VULKAN_LIBRARY"=>nothing)
                    run(`$child $(joinpath(root,"test","compositor_pixels.jl")) $display`)
                end
            end
        end
    end
end
