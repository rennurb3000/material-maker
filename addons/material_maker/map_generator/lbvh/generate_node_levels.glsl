#[compute]
#version 450

// only used on the GPU side during construction; it is necessary to allocate the (empty) buffer
struct LBVHConstructionInfo {
    uint parent;// pointer to the parent
    int visitationCount;// number of threads that arrived
};


layout(local_size_x = 256) in;
layout (std430, set = 0, binding = 0) readonly buffer lbvh_construction_infos {
    LBVHConstructionInfo g_lbvh_construction_infos[];
};

layout(set = 0,binding = 1,std430) writeonly buffer NodeLevels
{
    uint node_levels[];
};
layout(push_constant,std430) uniform PushConstants{
  uint node_count;  
  uint node_data_start;  
};

void main()
{
    uint node_idx = gl_GlobalInvocationID.x;
    if(node_idx >= node_count)
    {
        return;
    }
    uint cursor = node_idx; // node id , as we walk up the graph
    uint level = 0u;
    while(cursor != 0u)
    {
       cursor = g_lbvh_construction_infos[cursor].parent; 
       level++;
    }
    node_levels[node_idx] = level;
}
