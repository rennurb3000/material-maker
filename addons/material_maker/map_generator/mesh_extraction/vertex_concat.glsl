#[compute]
#version 450
layout(local_size_x = 256) in;
layout(set = 0,binding = 0,std430) readonly buffer SurfaceVertices
{
    vec3 surface_vertices[];
};
layout(set = 0,binding = 1,std430) writeonly buffer Vertices
{
    vec3 vertices[];
};
layout(set = 0,binding = 2,std430) writeonly buffer SurfaceIds
{
    uint surface_ids[];
};
layout(push_constant,std430) uniform PushConstants{
  uint vertex_count;  
  uint vertex_offset;  
  uint surface_id;
};

void main()
{
    uint i = gl_GlobalInvocationID.x;
    if(i>= vertex_count)
    {
        return;
    }
    uint dst = vertex_offset+i;
    vertices[dst] = surface_vertices[i];
    surface_ids[dst] = surface_id;
}
