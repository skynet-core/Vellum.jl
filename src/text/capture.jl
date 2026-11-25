"""Capture glyf text as contiguous face-homogeneous nodes in one isolated group.

Call inside transaction!. Tuple origins remain relative to the common position;
the complete original String and exact font revisions remain in every child.
"""
function capture_text!(edit::CanvasEdit,text::AbstractString,position::Tuple{Real,Real};
                       language::AbstractString="",script::Symbol=:auto,features=(),
                       fallback_fonts=())
    active_edit(edit)
    content = String(text)
    isvalid(content) && ncodeunits(content) <= 1_000_000 ||
        throw(ArgumentError("Invalid/oversized captured source text"))
    state = edit.state
    isfinite(state.font_size) && 0 < state.font_size <= floatmax(Float32) ||
        throw(ArgumentError("Invalid captured font size"))
    refs = Tuple(fallback_fonts)
    validate_text_fonts(state.font,refs,edit.resources,edit.canvas)
    tags = text_features(Tuple(features))
    run = TextRun(content,map(logical,position),state,(),String(language),script,tags,refs)
    work = _TextPreparation(128*1024*1024)
    _withTextPreparation(work) do
        faces,keys,allrefs = _textFaces(run,edit.resources,edit.canvas,UInt64(0),nothing)
        try
            layout,faces = _textLayout(run,faces,keys,UInt64(0),nothing)
            segments = Tuple{ResourceRef,Vector{Tuple{UInt32,Float64,Float64,UInt32}}}[]
            count = 0
            _foreachTextGlyph(run,layout,faces,keys) do index,gid,x,y,byte
                count += 1
                count <= 1_000_000 || throw(ArgumentError("Captured glyph budget exceeded"))
                reference = allrefs[index]
                if isempty(segments) || last(segments)[1] != reference
                    _fontWork!(2048)
                    push!(segments,(reference,Tuple{UInt32,Float64,Float64,UInt32}[]))
                end
                push!(last(segments)[2],(UInt32(gid),x,y,byte))
            end
            if isempty(segments) # Empty tuples have deferred semantics in schema 1.
                return draw_text!(edit,content,run.position;language,script,features=tags,
                    fallback_fonts=refs)
            end
            # The model stages this child edit and publishes only after all children succeed.
            return with_group(edit;opacity=state.opacity,blend=state.blend) do child
                for (reference,glyphs) in segments
                    configure!(child;font=reference,opacity=1,blend=:source_over)
                    provenance = Tuple(r for r in allrefs if r != reference)
                    draw_text!(child,content,run.position;glyphs=Tuple(glyphs),language,
                        script,features=tags,fallback_fonts=provenance)
                end
            end
        finally
            foreach(face -> _hbRetireFont!(face.opentype),faces)
        end
    end
end
