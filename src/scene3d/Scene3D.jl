"""Bounded perspective scenes with opaque triangle rendering, depth and picking."""
module Scene3D

import ..Vellum
import Libdl
using ..Vellum: Backend, CanvasEdit, Capabilities, Frame, Image, ImageData, ModelError,
    FrozenBytes, ResourcePayload, ResourceRef, Submission, Surface, VulkanBackend,
    draw_image!, resource, resource!

export Mesh, Camera, Material, Instance, Scene, SceneCPU, pick, detached_image, shade_image, attach!, timings
export SceneVulkan, SceneOverlay, window_surface, vulkan_statistics

include("model.jl")
include("cpu.jl")
include("vulkan.jl")

end
