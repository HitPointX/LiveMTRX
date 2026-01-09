#include "shared.metal"

fragment float4 glyph_frag(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler samp [[sampler(0)]]
) {
    float a = atlas.sample(samp, in.uv).r;
    if (a < 0.05) discard_fragment();

    float3 col = in.color * in.intensity;
    return float4(col, a);
}
