function _text_feature_metadata(features)
    seen = Set{Symbol}()
    for feature in features
        tag = if feature isa Symbol
            feature
        else
            feature isa Tuple && length(feature) == 2 && feature[1] isa Symbol &&
                feature[2] isa Integer && feature[2] in (0,1) ||
                throw(ArgumentError("Invalid text feature pair"))
            text = String(feature[1])
            ncodeunits(text) == 4 && all(c -> isascii(c) && isletter(c),text) ||
                throw(ArgumentError("Invalid text feature tag"))
            feature[1]
        end
        tag in seen && throw(ArgumentError("Duplicate text feature tag"))
        push!(seen,tag)
    end
    nothing
end

function _hbFeatures(features)
    _text_feature_metadata(features)
    records = NTuple{4,UInt32}[]
    for feature in features
        tag,value = feature isa Symbol ? (feature,1) : feature
        tag in (:kern,:liga,:clig) || throw(ArgumentError("Unsupported deferred text feature: $tag"))
        bytes = codeunits(String(tag))
        packed = foldl((n,b) -> (n<<8)|UInt32(b),bytes;init=UInt32(0))
        push!(records,(packed,UInt32(value),UInt32(0),typemax(UInt32)))
    end
    records
end
