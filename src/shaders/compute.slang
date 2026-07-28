struct Particle
{
    float2 position;
    float2 velocity;
    float3 color;
};

struct ParticleSSBO {
    Particle particles; 
};

StructuredBuffer<ParticleSSBO> particlesIn;
RWStructuredBuffer<ParticleSSBO> particlesOut;

[shader("vertex")]
VSOutput vertexmain()
{
}

[shader("fragment")]
float4 fragmentmain() {
}
