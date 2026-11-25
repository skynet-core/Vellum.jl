using Pkg

"""Build the Wasmtime release used by the Julia package on FreeBSD ARM, which lacks a binary artifact."""
function freebsd_wasmtime()
    commit = "823d1b8f251494a06288194d0df746191f535ff7"
    dir = mktempdir()
    run(`git -C $dir init -q`)
    run(`git -C $dir fetch --depth=1 https://github.com/bytecodealliance/wasmtime.git $commit`)
    run(`git -C $dir checkout -q --detach FETCH_HEAD`)
    run(`git -C $dir submodule update --init --recursive --depth=1`)
    cd(dir) do
        run(`cargo build --release --locked --no-default-features -p wasmtime-c-api --features wat,cranelift`)
        run(`cargo build --release --locked --no-default-features -p wasmtime-cli --features wast,cranelift`)
    end
    lib = joinpath(dir,"target","release","libwasmtime.so")
    isfile(lib) || error("Wasmtime C API build produced no shared library at $lib")
    ENV["LIBWASMTIME_LOCATION"] = lib
    ENV["VELLUM_WASMTIME_CLI"] = joinpath(dir,"target","release","wasmtime")
end

"""Build, precompile and run the package tests on the OS and processor named by the CI matrix."""
function build_test(kernel,arch)
    @info "Build and test" julia=VERSION kernel=Sys.KERNEL arch=Sys.ARCH
    (string(Sys.KERNEL),string(Sys.ARCH))==(kernel,arch) || error("Julia is running on the wrong matrix target")
    Sys.isfreebsd() && Sys.ARCH === :aarch64 && freebsd_wasmtime()
    Pkg.instantiate()
    Pkg.build()
    Pkg.precompile(;strict=true)
    Pkg.test()
    headless_test()
end

"""Run a consumer check in a temporary project containing this checkout as a dependency."""
function with_consumer(check)
    root = dirname(@__DIR__)
    previous = Base.active_project()
    mktempdir() do consumer
        try
            Pkg.activate(consumer)
            Pkg.develop(path=root)
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$consumer`
            check(addenv(cmd,"JULIA_LOAD_PATH"=>join(("@","@stdlib"),Sys.iswindows() ? ';' : ':')),root)
        finally
            Pkg.activate(dirname(previous))
        end
    end
end

"""Verify the minimal installation and its outputs without a display or window providers."""
function headless_test()
    with_consumer() do cmd,root
        test = joinpath(root,"test","headless.jl")
        run(addenv(`$cmd $test`,"DISPLAY"=>nothing,"WAYLAND_DISPLAY"=>nothing,"VELLUM_GLFW_LIBRARY"=>nothing))
    end
end

"""Install the native providers and verify a caller-owned GPU window on both Linux display systems."""
function desktop_test()
    Sys.islinux() || error("the desktop acceptance run requires Linux, X11 and Wayland")
    with_consumer() do cmd,root
        Pkg.add(["HarfBuzz_jll","Skia","Xorg_libX11_jll"])
        test = joinpath(root,"test","gdk_window.jl")
        for host in ("x11","wayland")
            run(addenv(`$cmd $test`,"GDK_BACKEND"=>host,"VELLUM_TEST_OPENGL"=>"required",
                       "VELLUM_TEST_VULKAN"=>"required","VELLUM_OPENGL_LIBRARY"=>nothing,"VELLUM_VULKAN_LIBRARY"=>nothing))
        end
    end
end

if ARGS == ["--headless"]
    headless_test()
elseif ARGS == ["--desktop"]
    desktop_test()
else
    build_test(ARGS...)
end
