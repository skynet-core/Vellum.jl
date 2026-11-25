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

"""Install this checkout as a dependency of an empty project, then test it in an isolated process."""
function headless_test()
    root = dirname(@__DIR__)
    previous = Base.active_project()
    mktempdir() do consumer
        try
            Pkg.activate(consumer)
            Pkg.develop(path=root)
            cmd = `$(Base.julia_cmd()) --startup-file=no --project=$consumer $(joinpath(root,"test","headless.jl"))`
            load_path = Sys.iswindows() ? "@;@stdlib" : "@:@stdlib"
            run(addenv(cmd,"JULIA_LOAD_PATH"=>load_path,"DISPLAY"=>nothing,"WAYLAND_DISPLAY"=>nothing,
                       "VELLUM_GLFW_LIBRARY"=>nothing))
        finally
            Pkg.activate(dirname(previous))
        end
    end
end

ARGS == ["--headless"] ? headless_test() : build_test(ARGS...)
