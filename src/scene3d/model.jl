"""Cartesian coordinates in finite Float64 world or camera space."""
const Vec3 = NTuple{3,Float64}
"""One opaque premultiplied sRGB pixel in RGBA order."""
const Color8 = NTuple{4,UInt8}
"""Three one-based indices into an immutable mesh."""
const Face = NTuple{3,Int}
"""Largest supported width or height of a CPU scene target, in pixels."""
const MAX_EDGE = 384
"""Largest vertex count admitted by one mesh."""
const MAX_VERTICES = 128
"""Largest triangle count admitted by one mesh."""
const MAX_FACES = 192
"""Largest object count admitted by one scene."""
const MAX_INSTANCES = 24
"""Largest resource count in a scene’s captured registry."""
const MAX_RESOURCES = 512
"""Scratch vertex capacity for a triangle clipped against the six frustum planes."""
const MAX_CLIPPED_VERTICES = 12
"""Fixed-point units per pixel for sample coverage."""
const SUBPIXEL = 256
"""Center offset within one output pixel in fixed-point units."""
const HALF_SAMPLE = SUBPIXEL ÷ 2

"""Raise a model error for invalid scene input, with its diagnostic."""
invalid(reason) = throw(ModelError(:invalid_input,reason))
"""Raise a model error for an exceeded scene resource bound."""
limit(reason) = throw(ModelError(:resource_limit,reason))
"""Raise a model error for an unavailable target or ticket."""
stale(reason) = throw(ModelError(:invalid_state,reason))

"""Return the dot product of two three-component vectors."""
dot3(a,b) = a[1]*b[1] + a[2]*b[2] + a[3]*b[3]
"""Subtract two three-component vectors component by component."""
sub3(a,b) = (a[1]-b[1], a[2]-b[2], a[3]-b[3])
"""Return the right-handed cross product of two three-component vectors."""
cross3(a,b) = (a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1])
"""Convert three finite real coordinates within ±4096 to a tuple of Float64 values. Invalid coordinates raise `ModelError`."""
function vector3(point)::Vec3
    length(point)==3 && all(x -> x isa Real && isfinite(x) && -4096<=x<=4096,point) || invalid("unbounded 3D coordinate")
    return map(Float64,Tuple(point))
end
"""Normalize a nonzero three-component direction or raise `ModelError` for a singular basis."""
function unit3(point)
    length = sqrt(dot3(point,point))
    length > 1e-10 || invalid("singular camera basis")
    return map(x -> x/length,point)
end

"""
    Mesh(positions, triangles)

Capture 3–128 finite world vertices and 1–192 triangles with one-based
indices. The mesh owns immutable tuples. Invalid coordinates, repeated or
degenerate indices, and excessive counts raise `ModelError`.
"""
struct Mesh <: ResourcePayload
    positions::Tuple{Vararg{Vec3}}
    triangles::Tuple{Vararg{Face}}
    function Mesh(positions,triangles)
        3 <= length(positions) <= MAX_VERTICES || limit("mesh vertex budget exceeded")
        1 <= length(triangles) <= MAX_FACES || limit("mesh triangle budget exceeded")
        vertices = Tuple(vector3(p) for p in positions)
        faces = map(Tuple(triangles)) do face
            length(face)==3 && all(i -> i isa Integer && 1<=i<=length(vertices),face) || invalid("invalid triangle index")
            a,b,c = map(Int,Tuple(face))
            a!=b && a!=c && b!=c || invalid("repeated triangle index")
            normal = cross3(sub3(vertices[b],vertices[a]),sub3(vertices[c],vertices[a]))
            dot3(normal,normal)>1e-20 || invalid("degenerate triangle")
            (a,b,c)
        end
        return new(vertices,faces)
    end
end

"""
    Camera(eye, look, up; fovy=pi/3, near=0.25, far=128.0)

Construct a right-handed perspective camera from its eye, target point,
and nominal up direction. `fovy` is measured vertically in radians and
the clipping planes use world units. Invalid or singular camera
parameters raise `ModelError`.
"""
struct Camera <: ResourcePayload
    eye::Vec3
    forward::Vec3
    right::Vec3
    up::Vec3
    half_height::Float64
    near::Float64
    far::Float64
    function Camera(eye,look,up; fovy::Real=pi/3,near::Real=0.25,far::Real=128.0)
        isfinite(fovy) && 0.05<=fovy<=2.9 && 0.001<=near<far<=8192 || invalid("invalid perspective frustum")
        lens_near, lens_far = Float64(near), Float64(far)
        lens_near < lens_far || invalid("clip planes coincide at Float64 precision")
        origin = vector3(eye)
        forward = unit3(sub3(vector3(look),origin))
        right = unit3(cross3(forward,vector3(up)))
        return new(origin,forward,right,cross3(right,forward),tan(Float64(fovy)/2),lens_near,lens_far)
    end
end

"""
    Material(r::Integer, g::Integer, b::Integer)

Describe an opaque sRGB surface color. Channels range from 0 through 255.
A channel outside that range raises `ModelError`.
"""
struct Material <: ResourcePayload
    color::Color8
    function Material(r::Integer,g::Integer,b::Integer)
        all(x -> 0<=x<=255,(r,g,b)) || invalid("opaque material channel outside 0…255")
        new((UInt8(r),UInt8(g),UInt8(b),0xff))
    end
end

"""
    Instance(id, mesh, material)

Reference one mesh and material in a scene by resource revision. Construct
the mesh in world coordinates. The positive object ID fits in a UInt32.
Wrong reference kinds or an invalid ID raise `ModelError`.
"""
struct Instance
    id::UInt32
    mesh::ResourceRef
    material::ResourceRef
    function Instance(id::Integer,mesh::ResourceRef,material::ResourceRef)
        0 < id <= typemax(UInt32) || invalid("invalid scene object ID")
        mesh.kind===:mesh && material.kind===:material || invalid("invalid object resource kinds")
        return new(UInt32(id),mesh,material)
    end
end

"""
    Scene(assets, camera, instances; background=Material(17, 24, 39))

Capture a 3D scene from a registry `Frame`, a camera reference, and up to
24 distinct object instances. The renderer resolves these resource revisions
from `assets` at submission. Invalid descriptors or excessive resource
counts raise `ModelError`. Scene geometry is independent of 2D drawing nodes.
"""
struct Scene
    assets::Frame
    camera::ResourceRef
    instances::Tuple{Vararg{Instance}}
    background::Color8
    function Scene(assets::Frame,camera::ResourceRef,instances;background::Material=Material(17,24,39))
        camera.kind===:camera || invalid("invalid camera resource kind")
        1<=length(instances)<=MAX_INSTANCES || limit("scene instance budget exceeded")
        length(assets.resources)<=MAX_RESOURCES || limit("scene resource budget exceeded")
        items = Tuple(instances)
        all(x -> x isa Instance,items) || invalid("invalid scene instance")
        ids = map(x -> x.id,items)
        length(unique(ids))==length(ids) || invalid("repeated scene object ID")
        return new(assets,camera,items,background.color)
    end
end
