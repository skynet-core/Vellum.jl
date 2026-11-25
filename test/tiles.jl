function test_tiles()
    T, S = Vellum.ImageTiles, Vellum.ImageStorage
    @testset "Tiled views, previews and streamed export" begin
        image = new_image(17,13)
        fill!(image,rgba(255,0,0,255))
        desc = S.PixelDescriptor(17,13)
        source = S.wrap_buffer(image.data,desc;owner=image)
        cache = T.cached(source;tile_size=4,cache_bytes=256)
        pyramid = T.pyramid(source;tile_size=4,chunk_size=4)
        try
            @test length(collect(T.visible_tiles(source,(3,3,2,2);tile_size=4))) == 4
            for region in ((3,3,2,2),(3,3,2,2),(6,5,10,5))
                @test S.with_pixels(l->S.read_channel(l,1,1,1),cache,region;copy_policy=:allow) == 255
            end
            @test T.cache_stats(cache).hits > 0
            for zoom in (1,0.5,0.25)
                view = T.view_request(pyramid,(0,0,17,13);zoom)
                lease = T.prepare_region(pyramid,view)
                try
                    @test S.read_channel(lease,1,1,1) == 255
                finally
                    close(lease)
                end
            end
            worker = T.Previewer(pyramid)
            try
                T.request!(worker,(0,0,17,13);zoom=0.5,preview=false)
                result = T.take_ready!(worker;wait=true)
                try
                    @test isnothing(result.error)
                    @test S.read_channel(result.pixels,1,1,1) == 255
                finally
                    close(result)
                end
                @test isnothing(T.take_ready!(worker))
                T.cancel!(worker)
            finally
                close(worker)
            end
            io = IOBuffer()
            report = T.write_p6(io,source;chunk_pixels=3,matte=(0,0,0))
            data = take!(io)
            @test length(data) == report.written_bytes
            @test decodePPM(data).data == image.data
            @test_throws ArgumentError T.write_p6(IOBuffer(),source;max_pixels=4)
            @test_throws InterruptException T.write_p6(IOBuffer(),source;cancelled=()->true)
        finally
            close(cache)
            close(pyramid)
            close(source)
        end
    end
    @testset "Portable raster assets and offline bundles" begin
        mktempdir() do dir
            registry = T.RasterRegistry(namespace=31, source_bytes=65536, max_assets=4, max_revisions=4,max_leases=16)
            tile = repeat(UInt8[255,0,0,255],16)
            revision = T.OwnedTileRevision(4,4,[((0,0),tile)];tile_size=4)
            descriptor,pin = T.publish_revision!(registry,revision)
            store = Wire.RasterAssetStore(joinpath(dir,"assets"))
            resolver = Wire.RasterAssetResolver(store)
            try
                publication, binding = Wire.export_asset!(store,registry,descriptor)
                try
                    @test Wire.asset_binding(publication) == binding == Wire.asset_binding(store,descriptor)
                    received = Wire.RasterAssetStore(joinpath(dir,"transferred"))
                    service = Wire.AssetService(store; session=7, namespaces=[descriptor.namespace])
                    requests, replies = Base.BufferStream(), Base.BufferStream()
                    client = Wire.AssetClient(replies,requests; session=7)
                    server = @async try
                        while !eof(requests)
                            Wire.serve_asset!(service,requests,replies)
                        end
                    finally
                        close(replies)
                    end
                    try
                        for _ in 1:2
                            remote = Wire.import_asset!(received,client,binding)
                            try
                                @test Wire.asset_binding(remote) == binding
                            finally
                                close(remote)
                            end
                        end
                        @test Wire.asset_binding(received,descriptor) == binding
                        @test isempty(service.leases)
                    finally
                        close(client)
                        close(requests)
                        try
                            wait(server)
                        finally
                            close(service)
                            close(received)
                        end
                    end
                    frame = drawing(size=(8,8)) do e
                        ref = resource!(e,:image,descriptor)
                        draw_image!(e,ref,(0,0,8,8))
                    end
                    renderer = CPUBackend.Renderer(raster_registry=registry)
                    try
                        @test rasterize(frame;backend=renderer)[4,4] == rgbx(255,0,0,255)
                        plan = prepare(renderer,frame)
                        try
                            gl = Vellum.OpenGLBackend
                            pages = gl.RasterPages
                            for streamed in (false,true)
                                packet = gl.pack_frame(plan,(8,8);streamed)
                                staged = pages.stage_uploads(plan,pages.EMPTY,packet.assets,registry)
                                @test only(staged).bytes == tile
                                @test only(gl.RasterAssets.describe(staged)).bytes == length(tile)
                                @test isempty(pages.stage_uploads(plan,packet.assets,packet.assets,registry))
                                slot = only(values(packet.assets.pages))
                                @test_throws ErrorException pages.forget_slots(packet.assets,BitSet([slot]))
                            end
                        finally
                            close(plan)
                        end
                    finally
                        close(renderer)
                    end
                    bytes = Wire.encode_snapshot(frame;assets=resolver)
                    state = Wire.decode_snapshot(bytes;assets=resolver)
                    bundle = joinpath(dir,"scene.bundle")
                    try
                        Wire.export_bundle(bundle,state;assets=resolver)
                    finally
                        close(state)
                    end
                    dest = joinpath(dir,"receiver")
                    for loaded in (()->Wire.import_bundle(bundle,dest),()->Wire.open_bundle_store(dest))
                        recovered = loaded()
                        try
                            @test Wire.encode_snapshot(recovered.snapshot;assets=recovered.resolver) == bytes
                            lease = T.acquire_revision(recovered.resolver,descriptor)
                            try
                                @test S.with_pixels(l->S.read_channel(l,1,1,1),lease,(0,0,1,1);copy_policy=:allow) == 255
                            finally
                                close(lease)
                            end
                        finally
                            close(recovered.snapshot)
                            close(recovered.resolver)
                            close(recovered.store)
                        end
                    end
                finally
                    close(publication)
                end
            finally
                close(resolver)
                close(store)
                close(pin)
                close(registry)
            end
        end
    end
end
