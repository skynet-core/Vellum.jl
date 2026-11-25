"""
    draw_program(output="draw_pixel(p)")

Assemble the Vulkan buffer interface and entry point around the generated Julia kernel.
"""
draw_program(output="draw_pixel(p)") = """
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(std430,binding=0) readonly buffer Plan { double words[]; };
layout(std430,binding=1) readonly buffer Atlas { uint texels[]; };
layout(std430,binding=2) readonly buffer Slots { uint base[]; };
layout(std430,binding=3) buffer Output { uint pixels[]; };
struct PacketTables { int shape; int contour; int point; int stop; int raster; int page; };
struct DrawPass { $(join(("int "*String(k)*";" for k in fieldnames(Backend.QueueKernel.DrawPass))," ")) };
layout(push_constant) uniform Dispatch { DrawPass pass; };
$KERNEL_FUNCTIONS
void main() {
    ivec2 p=ivec2(gl_GlobalInvocationID.xy);
    if (p.x>=pass.width || p.y>=pass.height) return;
    if (pass.mode==0) pixels[p.y*pass.width+p.x]=$output;
    else execute_pass(pass,p);
}
"""

"""
    compile_program(program)

Compile the compute shader to SPIR-V with the packaged shaderc C API. Release both compiler objects.
"""
function compile_program(program)
    compiler = ccall((:shaderc_compiler_initialize,libshaderc_shared),Ptr{Cvoid},())
    compiler != C_NULL || error("shaderc initialization failed")
    try
        result = ccall((:shaderc_compile_into_spv,libshaderc_shared),Ptr{Cvoid},
            (Ptr{Cvoid},Cstring,Csize_t,Cint,Cstring,Cstring,Ptr{Cvoid}),compiler,program,sizeof(program),
            2,"vellum.comp","main",C_NULL)
        result != C_NULL || error("shaderc returned no compilation result")
        try
            status = ccall((:shaderc_result_get_compilation_status,libshaderc_shared),Cint,(Ptr{Cvoid},),result)
            if status != 0
                message = ccall((:shaderc_result_get_error_message,libshaderc_shared),Cstring,(Ptr{Cvoid},),result)
                error("Vulkan draw shader: ",unsafe_string(message))
            end
            bytes = ccall((:shaderc_result_get_length,libshaderc_shared),Csize_t,(Ptr{Cvoid},),result)
            data = ccall((:shaderc_result_get_bytes,libshaderc_shared),Ptr{UInt32},(Ptr{Cvoid},),result)
            return copy(unsafe_wrap(Vector{UInt32},data,Int(bytes)÷4))
        finally
            ccall((:shaderc_result_release,libshaderc_shared),Cvoid,(Ptr{Cvoid},),result)
        end
    finally
        ccall((:shaderc_compiler_release,libshaderc_shared),Cvoid,(Ptr{Cvoid},),compiler)
    end
end
