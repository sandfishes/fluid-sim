struct VSOutput
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float3 color : COLOR0;
};

struct Vertex
{
    float3 position;
    float4 color;
}

struct PushConstants
{
    float4x4 render_matrix;
    Vertex *vertex_buffer;
};

[vk_push_constant]
PushConstants push_constants;

[shader("vertex")]
VSOutput vertexmain(uint vertex_index: SV_VertexID)
{
    Vertex v = push_constants.vertex_buffer[vertex_index];

    VSOutput output;
    output.pos = mul(push_constants.render_matrix, float4(v.position, 1.0));
    output.color = v.color.xyz;
    return output;
}

[shader("fragment")]
float4 fragmentmain(VSOutput input) {
    return float4(input.color, 1.0);
}
