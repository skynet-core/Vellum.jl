
function test_storage()
    @testset "Pixel leases and converted buffers" begin
        S = Vellum.ImageStorage
        buffer = S.allocate_buffer(4,2;row_stride=20)
        try
            S.with_pixels(buffer;access=:write) do lease
                S.write_channel!(lease,255,2,3,1)
                S.write_channel!(lease,255,2,3,4)
            end
            view = S.buffer_view(buffer,(2,1,1,1);readonly=true)
            @test S.with_pixels(l->S.read_channel(l,1,1,1),view) == 255
            @test_throws ArgumentError S.borrow_pixels(view;access=:write)
            @test_throws ArgumentError S.buffer_view(buffer,(4,0,1,1))
            packed = S.convert_buffer(buffer;format=:bgra8)
            try
                @test S.with_pixels(l->S.read_channel(l,2,3,3),packed.buffer) == 255
            finally
                close(packed.buffer)
            end
        finally
            close(buffer)
        end
        @test_throws ArgumentError S.borrow_pixels(buffer)
    end

    @testset "Brush preview, history and tiles" begin
        B = Brushes
        layer = B.PaintLayer(16,16;tile_size=4)
        brush = B.RoundBrush(diameter=3,color=(255,0,0))
        id = B.begin_stroke!(layer,brush,B.PointerSample(4,4,0,1))
        B.append_samples!(layer,id,[B.PointerSample(10,4,1,1)])
        @test B.paint_usage(layer).active_tiles > 0
        @test B.commit_stroke!(layer,id).tiles > 0
        rev = B.paint_revision(layer)
        try
            @test Vellum.ImageStorage.with_pixels(l->Vellum.ImageStorage.read_channel(l,1,1,1),rev,(4,4,1,1);copy_policy=:allow) > 0
        finally
            close(rev)
        end
        @test B.undo!(layer) == id
        @test B.paint_usage(layer).committed_tiles == 0
        @test B.redo!(layer) == id
    end
end

function test_opencv()
    @testset "Packaged OpenCV and scoped matrix lifetimes" begin
        S = Vellum.ImageStorage
        @test VersionNumber(opencv_version()).major == 4
        if Sys.islinux()
            cv = Vellum._packaged_opencv()
            native = Vellum._system_opencv(Vellum.Libdl.dlpath(cv.core),Vellum.Libdl.dlpath(cv.imgproc))
            try
                @test VersionNumber(native.version).major==4
            finally
                Vellum.Libdl.dlclose(native.imgproc)
                Vellum.Libdl.dlclose(native.core)
            end
        end
        buffer = S.allocate_buffer(4,3;format=:bgr8,alpha=:none)
        try
            # Red in BGR order, then invert a 2x1 cyan region.
            S.with_pixels(buffer;access=:write) do lease
                for y in 1:3, x in 1:4
                    S.write_channel!(lease,255,y,x,3)
                end
            end
            opencv_invert!(buffer;roi=(1,1,2,1))
            gray = opencv_gray(buffer)
            try
                S.with_pixels(gray.buffer) do lease
                    @test S.read_channel(lease,1,1,1) == 76
                    @test S.read_channel(lease,2,2,1) == 179
                end
                @test gray.report.copied_bytes == 12
            finally
                close(gray.buffer)
            end
            expired = with_opencv(identity,buffer)
            @test_throws ArgumentError opencv_gray(expired)
            @test_throws ArgumentError with_opencv(opencv_invert!,buffer)
        finally
            close(buffer)
        end
        rgbimage = new_image(2,2)
        fill!(rgbimage,rgba(255,0,0,255))
        converted = opencv_gray(rgbimage;copy_policy=:allow,matte=(0,0,0))
        try
            @test S.with_pixels(l->S.read_channel(l,1,1,1),converted.buffer) == 76
        finally
            close(converted.buffer)
        end
        @test_throws ArgumentError opencv_version(library="unavailable-test-provider")
    end
end
