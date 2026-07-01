#[compute]
#version 450

#define WORKGROUP_SIZE 256
#define ELEMENTS_PER_GROUP (WORKGROUP_SIZE * 2)

// https://developer.nvidia.com/gpugems/gpugems3/part-vi-gpu-computing/chapter-39-parallel-prefix-sum-scan-cuda
// https://www.youtube.com/watch?v=mmYv3Haj6uc blelloch scan

layout(local_size_x = WORKGROUP_SIZE) in;

layout (std430, set = 0, binding = 0) readonly buffer InputBuffer {
    uint g_input[];
};
layout (std430, set = 0, binding = 1) writeonly buffer OutputBuffer{
    uint g_output[];
};
layout (std430, set = 0, binding = 2) writeonly buffer BlockSums{
    uint g_block_sums[];
};

layout (push_constant, std430) uniform PushConstants {
    uint g_num_elements;
};

shared uint temp[ELEMENTS_PER_GROUP];

void main()
{
    uint lID = gl_LocalInvocationID.x;
    uint group = gl_WorkGroupID.x;

    uint start = group * ELEMENTS_PER_GROUP;
    uint i0 = start+ lID;
    uint i1 = start+ WORKGROUP_SIZE + lID;
    temp[lID] = (i0 <g_num_elements)? g_input[i0]:0u;
    temp[WORKGROUP_SIZE + lID] = (i0 <g_num_elements)? g_input[i1]:0u;
    barrier();

    // upsweep
    for(uint stride = 1u;stride<ELEMENTS_PER_GROUP;stride <<= 1u)
    {
        barrier();
        uint idx = (lID + 1u) * stride * 2u -1u;
        if(idx < ELEMENTS_PER_GROUP)
        {
            temp[idx] += temp[idx-stride];
        }
    }
    barrier();
    if (lID == 0u)
    {
        g_block_sums[group] = temp[ELEMENTS_PER_GROUP -1u];
        temp[ELEMENTS_PER_GROUP -1u] = 0u;
    }
    // downsweep
    for(uint stride = ELEMENTS_PER_GROUP >> 1; stride>0; stride >>= 1u)
    {
        barrier();
        uint idx = (lID + 1u) * stride * 2u - 1u;
        if(idx < ELEMENTS_PER_GROUP)
        {
            uint t = temp[idx-stride];
            temp[idx -stride] = temp[idx];
            temp[idx] += t;
        }
    }
    barrier();

    if(i0<g_num_elements)
    {
        g_output[i0] = temp[lID];
    }
    if(i1 < g_num_elements)
    {
        g_output[i1] = temp[WORKGROUP_SIZE + lID];
    }
}
