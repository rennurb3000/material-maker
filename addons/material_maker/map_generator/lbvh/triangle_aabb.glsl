// this creates an aabb per triangle!
// this matches the struct definition of https://github.com/MircoWerner/VkLBVH/tree/main
#[compute]
#version 450

layout(local_size_x = 64) in;

layout(set = 0, binding = 0, std430) readonly buffer Vertices{
    vec3 vertices[];
};
layout(set = 0, binding = 1, std430) readonly buffer Indices{
    uint indices[];
};

struct Element{
    uint primitiveIdx;
    float aabbMinX;
    float aabbMinY;
    float aabbMinZ;
    float aabbMaxX;
    float aabbMaxY;
    float aabbMaxZ;
};

layout(set =0,binding = 2,std430) buffer Elements{
    Element elements[];
};
layout(push_constant,std430) uniform PushConstants{
    uint numTriangles;
};

void main() {
    uint tri = gl_GlobalInvocationID.x;
    if(tri>=numTriangles)
    {
        return;
    }
    uint i0 = indices[tri*3+0];
    uint i1 = indices[tri*3+1];
    uint i2 = indices[tri*3+2];
    vec3 v0 = vertices[i0];
    vec3 v1 = vertices[i1];
    vec3 v2 = vertices[i2];
    vec3 minAABB = min(v0,min(v1,v2));
    vec3 maxAABB = max(v0,max(v1,v2));
    elements[tri].primitiveIdx= tri;
    elements[tri].aabbMinX = minAABB.x;
    elements[tri].aabbMinY = minAABB.y;
    elements[tri].aabbMinZ = minAABB.z;
    elements[tri].aabbMaxX = maxAABB.x;
    elements[tri].aabbMaxY = maxAABB.y;
    elements[tri].aabbMaxZ = maxAABB.z;
    
}
