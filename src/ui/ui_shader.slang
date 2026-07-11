struct VS_Output {
  float4 pos : SV_Position;
  [vk_location(0)]
  float4 color: COLOR0;
  [vk_location(1)]
  float2 uv;
  [vk_location(2)]
  int id;
};

struct Buffer_Descriptor {
  float4x4 world_matrix;
  float2 *pos_buffer;
  float4 *col_buffer;
  float2 *uvs_buffer;
  int *ids_buffer;
};

[vk_push_constant]
Buffer_Descriptor descriptor;

[[vk_binding(0, 0)]]
Sampler2D samplers[];

[shader("vertex")]
VS_Output vertexmain(uint vertex_index: SV_VertexID) {
  VS_Output output;
  float2 pos = descriptor.pos_buffer[vertex_index];
  // TODO
  output.pos = mul(float4(pos, 0.0, 1.0), descriptor.world_matrix);
  output.color = descriptor.col_buffer[vertex_index];
  output.uv = descriptor.uvs_buffer[vertex_index];
  output.id = descriptor.ids_buffer[vertex_index];
  return output;
}

[shader("fragment")]
float4 fragmentmain(VS_Output input) {
  Sampler2D atlas = samplers[0];
  float size_x;
  float size_y;
  float4 atlas_color = atlas.Sample(input.uv);
  // TODO alpha swizzling so no branching
  if (input.id == 0) { // drawing text or shapes
    return float4(input.color.rgb, atlas_color.r);
    // return float4(1, 1, 1, 1);
  } else {
    // return float4(1, 1, 1, 1);
    return float4(input.color.rgb, 1); 
  }
}
