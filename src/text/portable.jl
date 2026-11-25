function _text_script(script::Symbol, node)
    script === :auto && return nothing
    tag = String(script)
    ncodeunits(tag) == 4 && all(c -> isascii(c) && isletter(c),tag) ||
        throw(CapabilityError(node,:text_script_tag))
    foldl((value,byte) -> (value<<8)|UInt32(byte),codeunits(tag);init=UInt32(0))
end

function _textFaces(run,resources,canvas,node,cache)
    refs = (run.state.font,run.fallback_fonts...)
    length(refs) <= 64 || throw(ArgumentError("CPU text exceeds 64 declared faces"))
    seen = Set{ResourceRef}()
    faces,keys = Typeface[],Any[]
    for reference in refs
        reference isa ResourceRef && reference.canvas == canvas && reference.kind === :font &&
            reference.id > 0 && reference.revision > 0 ||
            throw(ArgumentError("Text font reference must identify this canvas's exact font revision"))
        reference in seen && throw(ArgumentError("Duplicate text font reference"))
        push!(seen,reference)
        data = resolve_resource(resources,reference)
        data isa FontData || throw(CapabilityError(node,:text_font))
        length(data.data) <= 16*1024*1024 ||
            throw(ArgumentError("CPU text font exceeds 16 MiB profile limit"))
        key = (reference,data.data.bytes)
        _reserveTextFont!(key,length(data.data))
        build = () -> begin
            _fontWork!(length(data.data))
            parseTtf(collect(codeunits(data.data.bytes)))
        end
        face = cache === nothing ? build() : _captured_cached!(build,cache,(:face,key))
        16 <= face.opentype.head.unitsPerEm <= 16384 &&
            0 < face.opentype.hhea.numberOfHMetrics <= face.opentype.maxp.numGlyphs ||
            throw(ArgumentError("Invalid text font metrics"))
        push!(faces,face)
        push!(keys,key)
    end
    faces,keys,refs
end

function _textLayout(run,faces,keys,node,cache)
    _checkTextPresentation((run.text,))
    _hbFeatures(run.features)
    script = _text_script(run.script,node)
    language = isempty(run.language) ? nothing : run.language
    _requireHarfBuzz()
    bidi = _bidiProvider()
    key = (:layout,Tuple(keys),run.text,run.state.font_size,run.state.direction,
        script,language,run.features,_HB_GENERATION[],bidi.path,bidi.unicode)
    build = () -> begin
        _fontWork!(Int128(ncodeunits(run.text))*8192+4096)
        face = Typeface(faces[1].opentype,"",faces[2:end]) # Flat ordered list, no hidden lookup.
        font = newFont(face)
        font.size = run.state.font_size
        direction = run.state.direction === :rtl ? RightToLeft : LeftToRight
        layout = layoutParagraph(newParagraph(run.text,font;dir=direction,script,language,features=run.features))
        (layout,faces)
    end
    cache === nothing ? build() : _captured_cached!(build,cache,key)
end

function _foreachTextGlyph(callback,run,layout,faces,keys)
    _fontWork!(Int128(ncodeunits(run.text))*16+4096)
    starts = _charStarts(run.text)
    indices = IdDict(face.opentype => i for (i,face) in enumerate(faces))
    baseline = first(layout.shapedPos).baselineY
    firstline = first(layout.lines)
    ascent,descent = max(0f0,firstline.ascent),max(0f0,firstline.descent)
    factor = run.state.font_size/Float64(scale(faces[1]))
    shift = run.state.baseline === :top ? ascent :
        run.state.baseline === :middle ? (ascent-descent)/2 :
        run.state.baseline in (:bottom,:ideographic) ? -descent :
        run.state.baseline === :hanging ? 0.8*max(0,faces[1].opentype.hhea.ascender)*factor : 0.0
    for (lineIndex,line) in enumerate(layout.shapedPos)
        width = layout.lines[lineIndex].width
        alignment = run.state.alignment === :center ? -width/2 :
                    run.state.alignment === :right ? -width : 0
        for (slot,position) in enumerate(line.pos)
            font = layout.shapedFonts[line.spans[slot]]
            index = indices[font.typeface.opentype]
            cluster = layout.clusters[line.order[slot]]
            byte = UInt32(starts[cluster.first]-1)
            for (gid,xpos,ypos,advance) in position.glyphs
                _fontWork!(256)
                callback(index,gid,logical(alignment+xpos),
                    logical(shift+(line.baselineY-baseline)+ypos),byte)
            end
        end
    end
    nothing
end

function _text_outline!(commands,face,gid,x,y,factor,max_commands;cache=nothing,key=nothing)
    0 < gid < face.opentype.maxp.numGlyphs ||
        throw(ArgumentError("Missing or out-of-face captured text glyph"))
    path = if cache === nothing
        glyphPathByGid(face,Int(gid))
    else
        _captured_cached!(cache,(:outline,key,gid)) do
            glyphPathByGid(face,Int(gid))
        end
    end # Unscaled, y-down font units.
    i = 1
    while i <= length(path.commands)
        _fontWork!(256)
        kind = PathCommandKind(Int(path.commands[i]))
        tag = kind === Move ? :move : kind === LineTo ? :line :
              kind === Quad ? :quad : kind === Cubic ? :cubic :
              kind === Close ? :close : nothing
        tag === nothing && throw(ArgumentError("Unsupported text outline command"))
        count = parameterCount(kind)
        length(commands) < max_commands ||
            throw(ArgumentError("CPU text outline exceeds command budget"))
        coordinates = ntuple(count) do k
            origin = isodd(k) ? x : y
            logical(origin + factor*Float64(path.commands[i+k]))
        end
        push!(commands,(tag,coordinates...))
        i += count+1
    end
end

"""Preserve TextRun semantics; derive CPU outlines without altering the Frame."""
function _portable_text_path(run::TextRun, frame::Frame, node::UInt64;
                             max_commands::Int,cache=nothing,preparation=_TextPreparation(128*1024*1024))
    _withTextPreparation(preparation) do
        _portable_text_path_impl(run,frame,node;max_commands,cache)
    end
end

function _portable_text_path_impl(run::TextRun, frame::Frame, node::UInt64;
                                  max_commands::Int,cache)
    state = run.state
    all(isfinite,run.position) || throw(ArgumentError("Text position must be finite"))
    paint = state.fill
    supported = paint isa Solid ? paint.color.space === :srgb :
        paint isa LinearGradient && all(stop -> stop.color.space === :srgb,paint.stops)
    supported || throw(CapabilityError(node,:text_single_face_unicode_v1))
    state.font !== nothing && isfinite(state.font_size) &&
        0 < state.font_size <= floatmax(Float32) ||
        throw(CapabilityError(node,:text_font))
    state.font.canvas == frame.canvas && state.font.kind === :font ||
        throw(ArgumentError("Text font reference must belong to this canvas and have kind :font"))
    isvalid(run.text) || throw(ArgumentError("Text must be valid UTF-8"))
    ncodeunits(run.text) <= max_commands ||
        throw(ArgumentError("CPU text input exceeds command budget"))
    _text_feature_metadata(run.features)
    faces,keys,refs = _textFaces(run,frame.resources,frame.canvas,node,cache)
    captured = !isempty(run.glyphs)
    face,key = faces[1],keys[1]
    factor = state.font_size / Float64(scale(face))
    isfinite(factor) && factor > 0 || throw(ArgumentError("Invalid text font scale"))
    commands = Tuple[]
    if captured
        length(run.glyphs) <= max_commands ||
            throw(ArgumentError("CPU captured glyph count exceeds command budget"))
        for glyph in run.glyphs
            glyph isa Tuple && length(glyph) == 4 ||
                throw(ArgumentError("Invalid captured glyph tuple"))
            gid,x,y,cluster = glyph
            gid isa Integer && 0 <= gid <= typemax(UInt32) &&
                cluster isa Integer && 0 <= cluster <= typemax(UInt32) &&
                cluster < ncodeunits(run.text) && isvalid(run.text,Int(cluster)+1) &&
                x isa Real && y isa Real && isfinite(x) && isfinite(y) ||
                throw(ArgumentError("Invalid captured glyph/UTF-8 cluster"))
            _text_outline!(commands,face,gid,logical(run.position[1]+x),
                logical(run.position[2]+y),factor,max_commands;cache,key)
        end
        return PathData(commands)
    end
    layout,faces = _textLayout(run,faces,keys,node,cache)
    count = 0
    _foreachTextGlyph(run,layout,faces,keys) do index,gid,x,y,byte
        count += 1
        count <= max_commands || throw(ArgumentError("CPU shaped glyph count exceeds command budget"))
        face = faces[index]
        factor = state.font_size/Float64(scale(face))
        _text_outline!(commands,face,gid,logical(run.position[1]+x),
            logical(run.position[2]+y),factor,max_commands;cache,key=keys[index])
    end
    return PathData(commands)
end
include("cache.jl")
include("capture.jl")
