#include <metal_stdlib>
using namespace metal;

struct FSIn {
    float4 position [[position]];
    float2 uv;
};

fragment float4 bright_extract(
    FSIn in [[stage_in]],
    texture2d<float> src [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    float3 col = src.sample(s, in.uv).rgb;
    float luma = dot(col, float3(0.2126, 0.7152, 0.0722));
    if (luma < 0.9) return float4(0,0,0,1);
    return float4(col, 1);
}
