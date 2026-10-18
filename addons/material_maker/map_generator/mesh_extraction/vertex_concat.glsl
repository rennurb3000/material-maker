#[compute]
#version 450
layout(local_size_x = 256) in;
layout(set = 0,binding = 0,std430) readonly buffer InputPositions
{
    float position_data[];
};
layout(set = 0,binding = 1,std430) readonly buffer InputIndices
{
    uint indices[];
};
layout(set = 0,binding = 2,std430) readonly buffer InputNormals
{
    float normal_data[];
};
layout(set = 0,binding = 3,std430) readonly buffer InputTangents
{
    vec4 tangents[];
};
layout(set = 0,binding = 4,std430) readonly buffer InputColors
{
    vec4 colors[];
};
layout(set = 0,binding = 5,std430) readonly buffer InputUVs
{
    vec2 uvs[];
};
layout(set = 0,binding = 6,std430) readonly buffer InputUV2s
{
    vec2 uv2s[];
};
layout(set = 0,binding = 7,std430) writeonly buffer OutputVertices
{
    vec3 output_vertices[];
};
layout(set = 0,binding = 8,std430) writeonly buffer OutputIndices
{
    uint output_indices[];
};

layout(set = 0,binding =9  ,rgba32f) uniform writeonly image2D position_lut;
layout(set = 0,binding =10 ,rgba32f) uniform writeonly image2D normal_lut;
layout(set = 0,binding =11 ,rgba32f) uniform writeonly image2D tangent_lut;
layout(set = 0,binding =12 ,rgba32f) uniform writeonly image2D color_lut;
layout(set = 0,binding =13 ,rgba32f) uniform writeonly image2D uv_lut;
layout(set = 0,binding =14 ,rgba32f) uniform writeonly image2D uv2_lut;
layout(set = 0,binding =15 ,r32ui  ) uniform writeonly uimage2D surface_id_lut;
layout(set = 0,binding = 16, std430) writeonly buffer OutputSurfaceIds
{ 
	uint output_surface_ids[];
};

layout(push_constant,std430) uniform PushConstants{
    uint vertex_count;  
    uint index_count;  
    uint vertex_offset;
    uint index_offset;
    uint surface_id;
    uint indexed;
    uint attribute_flags;
    uint lut_width;
} pc;

const uint HAS_NORMAL = 1u << 0;
const uint HAS_TANGENT= 1u << 1;
const uint HAS_COLOR  = 1u << 2;
const uint HAS_UV     = 1u << 3;
const uint HAS_UV2    = 1u << 4;

ivec2 lut_coord(uint index) {
    return ivec2(
        int(index % pc.lut_width),
        int(index / pc.lut_width)
    );
}

void main() {
    uint i = gl_GlobalInvocationID.x;

    if (i < pc.vertex_count) {
        uint dst = pc.vertex_offset + i;
        ivec2 coord = lut_coord(dst);
		output_surface_ids[dst] = pc.surface_id;

        vec3 position = vec3(position_data[i*3u],position_data[i*3u+1],position_data[i*3u+2]);

        vec3 normal = vec3(0.0, 0.0, 1.0);
		if ((pc.attribute_flags & HAS_NORMAL) != 0u) {
			normal = vec3(
        		normal_data[i * 3u],
        		normal_data[i * 3u + 1u],
        		normal_data[i * 3u + 2u]
    		);
		}

        vec4 tangent = (pc.attribute_flags & HAS_TANGENT) != 0u
            ? tangents[i] : vec4(1.0, 0.0, 0.0, 1.0);

        vec4 color = (pc.attribute_flags & HAS_COLOR) != 0u
            ? colors[i] : vec4(1.0);

        vec2 uv = (pc.attribute_flags & HAS_UV) != 0u
            ? uvs[i] : vec2(0.0);

        vec2 uv2 = (pc.attribute_flags & HAS_UV2) != 0u
            ? uv2s[i] : vec2(0.0);

        output_vertices[dst] = position;

        imageStore(position_lut, coord, vec4(position, 1.0));
        imageStore(normal_lut, coord, vec4(normal, 0.0));
        imageStore(tangent_lut, coord, tangent);
        imageStore(color_lut, coord, color);
        imageStore(uv_lut, coord, vec4(uv, 0.0, 0.0));
        imageStore(uv2_lut, coord, vec4(uv2, 0.0, 0.0));
        imageStore(surface_id_lut, coord, uvec4(pc.surface_id, 0u, 0u, 0u));
    }

    if (i < pc.index_count) {
        uint index = pc.indexed != 0u ? indices[i] : i;
        output_indices[pc.index_offset + i] =
            pc.vertex_offset + index;
    }
}

