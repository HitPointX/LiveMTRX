#include <metal_stdlib>
using namespace metal;

struct FSIn {
    float4 position [[position]];
    float2 uv;
};

fragment float4 blur_h(
    FSIn in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    constexpr float w[5] = {0.227027,0.1945946,0.1216216,0.054054,0.016216};
    float2 px = float2(1.0 / (float)tex.get_width(), 0.0);

    float3 col = tex.sample(s, in.uv).rgb * w[0];
    for (uint i=1;i<5;i++) {
        col += tex.sample(s, in.uv + px * (float)i).rgb * w[i];
        col += tex.sample(s, in.uv - px * (float)i).rgb * w[i];
    }
    return float4(col, 1);
}
