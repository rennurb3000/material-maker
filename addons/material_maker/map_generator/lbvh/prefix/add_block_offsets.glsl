#[compute]
#version 450

#define WORKGROUP_SIZE 256
#define ELEMENTS_PER_GROUP (WORKGROUP_SIZE *2)

layout( local_size_x = WORKGROUP_SIZE ) in;

layout (std430, set = 0, binding = 0) buffer OutputBuffer{
    uint g_output[];
};
layout (std430, set = 0, binding = 1) readonly buffer BlockOffsets{
    uint g_block_offsets[];
};
layout (push_constant, std430) uniform PushConstants{
    uint g_num_elements;
};

void main()
{
    uint lID = gl_LocalInvocationID.x;
    uint group = gl_WorkGroupID.x;
    uint start = group * ELEMENTS_PER_GROUP;
    uint i0 = start+lID;
    uint i1 = start+WORKGROUP_SIZE + lID;
    uint block_offset = g_block_offsets[group];
    if(i0 < g_num_elements)
    {
        g_output[i0] += block_offset;
    }
    if(i1 < g_num_elements)
    {
        g_output[i1] += block_offset;
    }
}
