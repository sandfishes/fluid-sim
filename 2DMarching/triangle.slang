struct VSOutput
{
    float4 pos : SV_Position;
    [vk_location(0)]
    float3 color : COLOR0;
};

struct Vertex
{
    float2 position;
    float3 color;
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
    output.pos = mul(push_constants.render_matrix, float4(v.position, 0.0, 1.0));
    output.color = v.color;
    return output;
}

[shader("fragment")]
float4 fragmentmain(VSOutput input) {
    return float4(input.color, 1.0);
}
