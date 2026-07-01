// code copied together from https://github.com/MircoWerner/VkLBVH
#[compute]
#version 450

#define INVALID_POINTER 0x0

// input for the builder (normally a triangle or some other kind of primitive); it is necessary to allocate and fill the buffer
struct Element {
    uint primitiveIdx;// the id of the primitive; this primitive id is copied to the leaf nodes of the  LBVHNode
    float aabbMinX;// aabb of the primitive
    float aabbMinY;
    float aabbMinZ;
    float aabbMaxX;
    float aabbMaxY;
    float aabbMaxZ;
};

// output of the builder; it is necessary to allocate the (empty) buffer
struct LBVHNode {
    int left;// pointer to the left child or INVALID_POINTER in case of leaf
    int right;// pointer to the right child or INVALID_POINTER in case of leaf
    uint primitiveIdx;// custom value that is copied from the input Element or 0 in case of inner node
    float aabbMinX;// aabb of the node
    float aabbMinY;
    float aabbMinZ;
    float aabbMaxX;
    float aabbMaxY;
    float aabbMaxZ;
};

// only used on the GPU side during construction; it is necessary to allocate the (empty) buffer
struct MortonCodeElement {
    uint mortonCode;// key for sorting
    uint elementIdx;// pointer into element buffer
};

// only used on the GPU side during construction; it is necessary to allocate the (empty) buffer
struct LBVHConstructionInfo {
    uint parent;// pointer to the parent
    int visitationCount;// number of threads that arrived
};

layout(local_size_x = 64) in;

layout(set = 0,binding = 0,std430) writeonly buffer morton_codes{
    MortonCodeElement g_morton_codes[];
};

layout(set = 0,binding = 1,std430) readonly buffer elements{
    Element g_elements[];
};
layout(push_constant,std430) uniform PushConstants{
    uint g_num_elements;
    float g_min_x;// AABB that contains the entire model
    float g_min_y;
    float g_min_z;
    float g_max_x;
    float g_max_y;
    float g_max_z;
};

// Expands a 10-bit integer into 30 bits
// by inserting 2 zeros after each bit.
uint expandBits(uint v) {
    v = (v * 0x00010001u) & 0xFF0000FFu;
    v = (v * 0x00000101u) & 0x0F00F00Fu;
    v = (v * 0x00000011u) & 0xC30C30C3u;
    v = (v * 0x00000005u) & 0x49249249u;
    return v;
}

// Calculates a 30-bit Morton code for the
// given 3D point located within the unit cube [0,1].
uint morton3D(float x, float y, float z) {
    x = min(max(x * 1024.0f, 0.0f), 1023.0f);
    y = min(max(y * 1024.0f, 0.0f), 1023.0f);
    z = min(max(z * 1024.0f, 0.0f), 1023.0f);
    uint xx = expandBits(uint(x));
    uint yy = expandBits(uint(y));
    uint zz = expandBits(uint(z));
    return xx * 4 + yy * 2 + zz;
}
// calculate morton code for each element
void main()
{
    uint gID = gl_GlobalInvocationID.x;
    if (gID >= g_num_elements)
    {
        return;
    }
    Element element = g_elements[gID];
    vec3 aabbMin= vec3(element.aabbMinX,element.aabbMinY,element.aabbMinZ);
    vec3 aabbMax= vec3(element.aabbMaxX,element.aabbMaxY,element.aabbMaxZ);

    // calculate center
    vec3 center = (aabbMin + 0.5 * (aabbMax-aabbMin)).xyz;
    // map to unit cube
    vec3 g_min = vec3(g_min_x, g_min_y, g_min_z);
    vec3 g_max = vec3(g_max_x, g_max_y, g_max_z);
    vec3 mappedCenter = (center - g_min) / (g_max - g_min);
    // assign morton code
    g_morton_codes[gID] = MortonCodeElement(morton3D(mappedCenter.x, mappedCenter.y, mappedCenter.z), gID);
}
