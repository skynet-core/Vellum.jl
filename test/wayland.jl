using Wayland_jll: libwayland_client

function announce_global(data::Ptr{Cvoid}, registry::Ptr{Cvoid}, id::UInt32, name::Cstring, version::UInt32)::Cvoid
    globals = unsafe_pointer_to_objref(data)::Dict{String,Tuple{UInt32,UInt32}}
    globals[unsafe_string(name)] = (id,version)
    return nothing
end
removed_global(data::Ptr{Cvoid},registry::Ptr{Cvoid},id::UInt32)::Cvoid = nothing

function bind_global(registry, globals, name, interface, maximum_version)
    id, available = globals[name]
    version = min(available,UInt32(maximum_version))
    wire_name = unsafe_load(Ptr{Ptr{Cchar}}(interface))
    words = map(WaylandSHM.wl_argument,(id,wire_name,version,C_NULL)) |> collect
    ccall((:wl_proxy_marshal_array_flags,libwayland_client),Ptr{Cvoid},
          (Ptr{Cvoid},UInt32,Ptr{Cvoid},UInt32,UInt32,Ptr{UInt}),registry,0,interface,version,0,words)
end

function test_wayland()
    @testset "Wayland shared-memory presentation and buffer releases" begin
        W = WaylandSHM
        @test_throws ArgumentError W.Presenter(C_NULL,C_NULL,C_NULL;max_size=(16,16))
        has_display = haskey(ENV,"WAYLAND_DISPLAY")
        display = has_display ? ccall((:wl_display_connect,libwayland_client),Ptr{Cvoid},(Cstring,),C_NULL) : C_NULL
        if display == C_NULL
            get(ENV,"VELLUM_TEST_WAYLAND","") == "required" && error("Wayland display is unavailable")
            @test_skip display != C_NULL
            return
        end
        registry = W.wl_request(display,1,C_NULL;interface=cglobal((:wl_registry_interface,libwayland_client)))
        globals = Dict{String,Tuple{UInt32,UInt32}}()
        callbacks = [
            @cfunction(announce_global,Cvoid,(Ptr{Cvoid},Ptr{Cvoid},UInt32,Cstring,UInt32)),
            @cfunction(removed_global,Cvoid,(Ptr{Cvoid},Ptr{Cvoid},UInt32))]
        sync() = ccall((:wl_display_roundtrip,libwayland_client),Cint,(Ptr{Cvoid},),display)
        drop_proxy(proxy) = ccall((:wl_proxy_destroy,libwayland_client),Cvoid,(Ptr{Cvoid},),proxy)
        try
            GC.@preserve globals callbacks begin
                @test ccall((:wl_proxy_add_listener,libwayland_client),Cint,(Ptr{Cvoid},Ptr{Ptr{Cvoid}},Ptr{Cvoid}),
                            registry,callbacks,pointer_from_objref(globals)) == 0
                @test sync() >= 0
                compositor = bind_global(registry,globals,"wl_compositor",cglobal((:wl_compositor_interface,libwayland_client)),4)
                shm = bind_global(registry,globals,"wl_shm",cglobal((:wl_shm_interface,libwayland_client)),1)
                surface = W.wl_request(compositor,0,C_NULL;interface=cglobal((:wl_surface_interface,libwayland_client)))
                presenter = W.Presenter(display,shm,surface;max_size=(8,8))
                renderer = CPUBackend.Renderer()
                try
                    @test_throws ArgumentError W.Presenter(display,shm,surface;max_size=(8,8))
                    @test_throws ArgumentError W.capture(presenter)
                    source = render(drawing(size=(6,4)) do e
                        rectangle!(e,0,0,6,4;fill=Solid(0.5,0.25,0.75,0.8))
                    end;backend=renderer)
                    @test_throws ArgumentError present!(presenter,source,1;damage=(0,0,7,4))
                    @test present!(presenter,source,1) == :accepted
                    @test W.capture(presenter).data == source.image.data
                    @test present!(presenter,source,1) == :unchanged
                    @test_throws ArgumentError present!(presenter,source,0)
                    @test present!(presenter,source,2;damage=(1,1,1,1)) == :accepted
                    @test present!(presenter,source,3) == :busy
                    @test W.statistics(presenter).in_flight == 2
                    @test_throws ArgumentError close(presenter)
                    W.detach!(presenter)
                    @test_throws ArgumentError present!(presenter,source,3)
                    @test sync() >= 0
                    state = W.statistics(presenter)
                    @test state.releases == 2 && state.in_flight == 0
                    @test state.staged_bytes == 2*sizeof(source.image.data)
                finally
                    close(renderer)
                    W.detach!(presenter)
                    sync()
                    close(presenter)
                    close(presenter)
                    W.wl_request(surface,0;destroy=true)
                    drop_proxy(shm)
                    drop_proxy(compositor)
                end
            end
        finally
            drop_proxy(registry)
            ccall((:wl_display_disconnect,libwayland_client),Cvoid,(Ptr{Cvoid},),display)
        end
    end
end
