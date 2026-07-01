#[compute]
#version 450

#define INVALID_POINTER 0x0
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

layout (local_size_x = 64) in;
