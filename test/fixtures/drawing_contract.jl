"""Construct the portable conformance scene used by the CPU and interactive browser tests."""
function drawing_contract_frame()
    storage = Vellum.ImageStorage
    # Two rows of red and blue pixels, with padding before, between, and after them.
    descriptor = storage.PixelDescriptor(2,2;offset=1,row_stride=10)
    bytes = UInt8[17,255,0,0,255,255,0,0,255,17,17,0,0,255,255,0,0,255,255,17]
    source = storage.wrap_buffer(bytes,descriptor)
    try
        return drawing(size=(96,40)) do edit
            rectangle!(edit,0,0,96,40;fill=Solid(1,1,1))
            with_group(edit;opacity=0.5) do child
                paint = Solid(1,0,0,0.5)
                rectangle!(child,2,2,14,14;fill=paint)
                rectangle!(child,8,8,14,14;fill=paint)
            end
            with_state(edit;fill=Solid(0,1,0)) do child
                clip(child,rectangle_path(28,0,10,24))
                curve = PathData(((:move,24,20),(:line,24,10),(:quad,34,-5,44,10),
                                  (:line,44,20),(:close,)))
                draw(child,curve)
            end
            configure!(edit;sampling=:nearest)
            draw_image!(edit,resource!(edit,source),(48,2,16,16))
            font = resource!(edit,:font,FontData("Liberation Sans",read(joinpath(@__DIR__,"LiberationSans-Regular.ttf"))))
            configure!(edit;font,font_size=16,fill=Solid(0,0,0))
            Vellum.capture_text!(edit,"AV",(66,22))
        end
    finally
        close(source)
    end
end

"""Return interior reference pixels in zero-based physical coordinates at unit scale."""
drawing_contract_probes() = (
    (4,4,rgbx(255,191,191,255)), (10,10,rgbx(255,159,159,255)),
    (26,14,rgbx(255,255,255,255)), (32,14,rgbx(0,255,0,255)),
    (54,5,rgbx(255,0,0,255)), (54,15,rgbx(0,0,255,255)),
)
