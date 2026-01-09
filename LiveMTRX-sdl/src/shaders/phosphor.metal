#include <metal_stdlib>
using namespace metal;

struct FSIn {
    float4 position [[position]];
    float2 uv;
};

fragment float4 phosphor_blend(
    FSIn in [[stage_in]],
    texture2d<float> current [[texture(0)]],
    texture2d<float> history [[texture(1)]],
    sampler s [[sampler(0)]]
) {
    float3 cur = current.sample(s, in.uv).rgb;
    float3 prev = history.sample(s, in.uv).rgb;

    constexpr float decay = 0.88;
    float3 blended = max(cur, prev * decay);
    return float4(blended, 1);
}
