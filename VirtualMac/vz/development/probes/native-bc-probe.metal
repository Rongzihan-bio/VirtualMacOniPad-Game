#include <metal_stdlib>
using namespace metal;

struct ProbeVertex {
    float4 position [[position]];
    float2 texcoord;
};

vertex ProbeVertex native_bc_probe_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[] = {
        float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0),
    };
    const float2 texcoords[] = {
        float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0),
    };
    return { float4(positions[vertexID], 0.0, 1.0), texcoords[vertexID] };
}

fragment float4 native_bc_probe_fragment(
    ProbeVertex input [[stage_in]], texture2d<float> texture [[texture(0)]]) {
    constexpr sampler nearestSampler(coord::normalized, address::clamp_to_edge,
                                     filter::nearest);
    return texture.sample(nearestSampler, input.texcoord);
}
