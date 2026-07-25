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

layout(local_size_x = 256) in;
layout(set = 0,binding = 0,std430) readonly buffer LBVHBuffer
{
    LBVHNode nodes[];
};
layout(set = 0,binding = 1,std430) readonly buffer NodeOffsets
{
    uint node_offsets[];
};
layout(set = 0,binding = 2,std430) readonly buffer NodeLevels
{
    uint node_levels[];
};
layout(set = 0,binding = 3,std430) readonly buffer Vertices
{
    vec3 vertices[];
};
layout(set = 0,binding = 4,std430) readonly buffer Indices
{
    uint indices[];
};

layout(rgba32f,set = 0, binding =5) uniform writeonly image2D output_image;
layout(push_constant,std430) uniform PushConstants{
  uint node_count;  
  uint node_data_start;  
  uint texture_width;
};

ivec2 texel_coord(uint idx)
{
    return ivec2(
        int(idx%texture_width),
        int(idx/texture_width));
}

void write_texel(uint idx,vec4 value)
{
    imageStore(output_image,texel_coord(idx),value);
}
void main()
{
    uint node_idx = gl_GlobalInvocationID.x;
    if(node_idx >= node_count)
    {
        return;
    }
    //header : offset to node data
    if(node_idx == 0u)
    {
        write_texel(0,vec4(float(node_data_start),0.0,0.0,0.0));
    }

    // yeah precomputed with the prefix sum
    write_texel(1u+node_idx, vec4(float(node_offsets[node_idx]),0.0,0.0,0.0));
    LBVHNode node = nodes[node_idx];

    bool is_leaf = node.left == INVALID_POINTER && node.right == INVALID_POINTER;
    uint output_offset = node_data_start+node_offsets[node_idx];
    vec3 aabb_min = vec3(node.aabbMinX,node.aabbMinY,node.aabbMinZ);
    vec3 aabb_max = vec3(node.aabbMaxX,node.aabbMaxY,node.aabbMaxZ);

    // node : texel0 :xyz = min_aabb, w hierarchy_level
    //        texel1 : xyz = max_aabb, w, triangle_count for leaves, otherwise zero 
    write_texel(output_offset+0u, vec4(aabb_min,float(node_levels[node_idx])));
    write_texel(output_offset+1u,vec4(aabb_max,is_leaf?1.0:0.0));
    if (is_leaf)
    {
        uint tri = node.primitiveIdx;
        uint index_offset = tri *3u;
        uint vertex_id_0 = indices[index_offset+0];
        uint vertex_id_1 = indices[index_offset+1];
        uint vertex_id_2 = indices[index_offset+2];
        vec3 vertex_0 = vertices[vertex_id_0];
        vec3 vertex_1 = vertices[vertex_id_1];
        vec3 vertex_2 = vertices[vertex_id_2];
        write_texel(output_offset +2u, vec4(vertex_0,0.0));
        write_texel(output_offset +3u, vec4(vertex_1,0.0));
        write_texel(output_offset +4u, vec4(vertex_2,0.0));
    }
    else
    {
        // non leaf node
        write_texel(output_offset +2u, vec4(float(node.left),float(node.right),0.0,0.0));
    }
    
}
