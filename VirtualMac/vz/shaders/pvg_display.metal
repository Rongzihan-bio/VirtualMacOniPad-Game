#include <metal_stdlib>
using namespace metal;

// Reconstructed from the AIR and reflection metadata in the unmodified
// macOS 13.2.1 (22D68) ParavirtualizedGraphics default.metallib. Keep names,
// resource indices, types, and math identical so the extracted PVG framework
// can create its pipelines with an iOS-targeted library.

kernel void BlitInRGB_2P_XR10_A8(
    texture2d<half, access::read> srcColor [[texture(0)]],
    texture2d<half, access::read> srcAlpha [[texture(1)]],
    texture2d<half, access::write> dst [[texture(2)]],
    uint2 index [[thread_position_in_grid]],
    uint2 size [[threads_per_grid]]) {
    (void)size;
    half4 color = srcColor.read(index);
    half4 alpha = srcAlpha.read(index);
    dst.write(half4(color.rgb, alpha.r), index);
}

kernel void BlitOutRGB_2P_XR10_A8(
    texture2d<half, access::read> src [[texture(0)]],
    texture2d<half, access::write> dstColor [[texture(1)]],
    texture2d<half, access::write> dstAlpha [[texture(2)]],
    uint2 index [[thread_position_in_grid]]) {
    half4 color = src.read(index);
    dstColor.write(half4(color.rgb, 0.0h), index);
    dstAlpha.write(color.aaaa, index);
}

struct PGDisplayVertexOutput {
    float4 pos [[position]];
    float2 tex;
};

vertex PGDisplayVertexOutput displayPresentVertex(
    constant float4 *positions [[buffer(0)]],
    constant float2 *textureCoordinates [[buffer(1)]],
    uint vertexID [[vertex_id]]) {
    return {positions[vertexID], textureCoordinates[vertexID]};
}

constexpr sampler displaySampler(
    coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler gammaSampler(
    coord::normalized, address::clamp_to_edge, filter::linear);

fragment float4 displayPresentFragment(
    PGDisplayVertexOutput input [[stage_in]],
    texture2d<float, access::sample> texture [[texture(0)]]) {
    return texture.sample(displaySampler, input.tex);
}

struct PGDisplayFragmentShaderProperties {
    float4x3 colorMatrix;
};

fragment float4 displayPresentFragmentWithGammaTableAndColorMatrix(
    PGDisplayVertexOutput input [[stage_in]],
    texture2d<float, access::sample> texture [[texture(0)]],
    texture1d_array<float, access::sample> gammaTable [[texture(1)]],
    constant PGDisplayFragmentShaderProperties &properties [[buffer(0)]]) {
    float4 color = texture.sample(displaySampler, input.tex);
    float4 gammaColor(
        gammaTable.sample(gammaSampler, color.r, 0).r,
        gammaTable.sample(gammaSampler, color.g, 1).r,
        gammaTable.sample(gammaSampler, color.b, 2).r,
        1.0f);
    return float4(properties.colorMatrix * gammaColor, 1.0f);
}
