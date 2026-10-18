#[compute]
#version 450

#define FLT_MAX 3.402823466e+38
#define FLT_MIN 1.175494351e-38

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

layout(local_size_x = 256) in;
layout(push_constant,std430) uniform PushConstants
{
    uint g_num_elements;
    uint g_leaf_size;
    float g_min_x;// AABB that contains the entire model
    float g_min_y;
    float g_min_z;
    float g_max_x;
    float g_max_y;
    float g_max_z;
};
layout (std430, set = 0, binding = 0) readonly buffer elements {
    Element g_elements[];
};
layout (std430, set = 0, binding = 1) readonly buffer sortedMorton{
    MortonCodeElement g_sorted_morton[];
};
layout (std430, set = 0, binding = 2) writeonly buffer clusterElements{
    Element g_cluster_elements[];
};
layout (std430, set = 0, binding = 3) writeonly buffer clusterMorton{
    MortonCodeElement g_cluster_morton[];
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

void main(){
    uint cluster_id = gl_GlobalInvocationID.x;
    uint cluster_count = (g_num_elements + g_leaf_size-1)/g_leaf_size;

    if(cluster_id >= cluster_count)
    {
        return;
    }
    uint first = cluster_id * g_leaf_size;
    uint count = min(uint(g_leaf_size),g_num_elements-first);

    vec3 bounds_min = vec3(FLT_MAX);
    vec3 bounds_max = vec3(-FLT_MAX);

    for(uint i=0;i<count;i++)
    {
        uint element_idx = g_sorted_morton[first+i].elementIdx;
        Element element = g_elements[element_idx];

        bounds_min = min(bounds_min,vec3(element.aabbMinX,element.aabbMinY,element.aabbMinZ));    
        bounds_max = max(bounds_max,vec3(element.aabbMaxX,element.aabbMaxY,element.aabbMaxZ));    
    }
    vec3 center = (bounds_min+ 0.5 * (bounds_max-bounds_min)).xyz;
    // map to unit cube
    vec3 g_min = vec3(g_min_x, g_min_y, g_min_z);
    vec3 g_max = vec3(g_max_x, g_max_y, g_max_z);
    vec3 mappedCenter = (center - g_min) / (g_max - g_min);
    uint morton_code = morton3D(mappedCenter.x,mappedCenter.y,mappedCenter.z);
    g_cluster_morton[cluster_id]= MortonCodeElement(morton_code,cluster_id);
    g_cluster_elements[cluster_id] = Element(
        first,
        bounds_min.x, bounds_min.y, bounds_min.z,
        bounds_max.x, bounds_max.y, bounds_max.z
    );
}
