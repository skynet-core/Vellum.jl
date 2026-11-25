module VellumVulkanExt

using Vellum
import VulkanCore
using VulkanCore.LibVulkan
using Shaderc_jll: libshaderc_shared
import Vellum: VulkanBackend as Backend
import Vellum: OpenGLBackend as Packed

using Vellum.VulkanBackend.QueueKernel: KERNEL_FUNCTIONS
include("shader.jl")

@static if VulkanCore.HAS_LOADER
include("device.jl")
include("submission.jl")
else
"""
    open_target(device,size)

Explain the missing Vulkan loader when the first queue target is requested.
"""
open_target(device,size) = throw(ArgumentError("VulkanCore needs a Vulkan loader for this platform"))
end

end
