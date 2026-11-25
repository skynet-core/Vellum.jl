using Pkg

"""Build the C ABI used by the pinned Wasmtime.jl release on FreeBSD, which has no matching upstream binary artifact."""
function freebsd_wasmtime()
    commit = "8043c1f919a77905255eded33e4e51a6fbfd1de1"
    dir = mktempdir()
    run(`git -C $dir init -q`)
    run(`git -C $dir fetch --depth=1 https://github.com/bytecodealliance/wasmtime.git $commit`)
    run(`git -C $dir checkout -q --detach FETCH_HEAD`)
    run(`git -C $dir submodule update --init --recursive --depth=1`)
    cd(dir) do
        run(`cargo build --release --locked --no-default-features --features wat --manifest-path crates/c-api/Cargo.toml`)
    end
    lib = joinpath(dir,"target","release","libwasmtime.so")
    isfile(lib) || error("Wasmtime C API build produced no shared library at $lib")
    ENV["LIBWASMTIME_LOCATION"] = lib
end

"""Build, precompile and run the package tests on the OS and processor named by the CI matrix."""
function build_test(kernel,arch)
    @info "Build and test" julia=VERSION kernel=Sys.KERNEL arch=Sys.ARCH
    (string(Sys.KERNEL),string(Sys.ARCH))==(kernel,arch) || error("Julia is running on the wrong matrix target")
    Sys.isfreebsd() && freebsd_wasmtime()
    Pkg.instantiate()
    Pkg.build()
    Pkg.precompile(;strict=true)
    Pkg.test()
end

build_test(ARGS...)
