#[compute]
#version 450

#define INVALID_POINTER 0x0
#define LEAF_SIZE 5u
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

layout (local_size_x = 256) in;
layout(set = 0,binding = 0,std430) readonly buffer LBVHBuffer
{
    LBVHNode nodes[];
};
layout(set = 0,binding = 1,std430) writeonly buffer NodeSizes
{
    uint node_sizes[];
};
layout(push_constant,std430) uniform PushConstants{
  uint node_count;  
};

void main(){
    uint node_idx = gl_GlobalInvocationID.x;
    if(node_idx >= node_count)
    {
        return;
    }
    LBVHNode node = nodes[node_idx];
    bool is_leaf = node.left == INVALID_POINTER && node.right == INVALID_POINTER;
    node_sizes[node_idx] = is_leaf?LEAF_SIZE:3u;
}
