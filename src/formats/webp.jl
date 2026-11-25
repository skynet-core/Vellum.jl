# Static WebP compatibility entry points (retired in VTR-007).
# Earlier boundary: WebP.jl/libwebp, following pixie/fileformats/webp.nim.
# The old provider admitted native-crashing animated inputs and did not establish
# the metadata/limits contract. No WebP capability is registered or advertised.
_webpRetired() = throw(ArgumentError("WebP support is retired; use PNG/JPEG or register an explicitly qualified codec provider"))
decodeWebP(::Vector{UInt8}) = _webpRetired()
decodeWebPDimensions(::Vector{UInt8}) = _webpRetired()
encodeWebP(::Image;kwargs...) = _webpRetired()
