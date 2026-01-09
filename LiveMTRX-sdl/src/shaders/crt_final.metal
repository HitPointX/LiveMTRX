#include "shared.metal"

static inline float2 apply_curvature(float2 uv, float strength) {
    float2 cc = uv - 0.5;
    float r2 = dot(cc, cc);
    return uv + cc * r2 * strength;
}

static inline float3 shadow_mask(float2 fragCoord, int mode) {
    int x = (int)fragCoord.x;
    int y = (int)fragCoord.y;

    if (mode == 0) {
        int m = x % 3;
        return (m == 0) ? float3(1.0,0.85,0.85) :
               (m == 1) ? float3(0.85,1.0,0.85) :
                          float3(0.85,0.85,1.0);
    }
    if (mode == 1) {
        int d = (x + y) % 3;
        return (d == 0) ? float3(1.0,0.7,0.7) :
               (d == 1) ? float3(0.7,1.0,0.7) :
                          float3(0.7,0.7,1.0);
    }
    return ((y & 1) == 0) ? float3(0.9) : float3(1.0);
}

fragment float4 crt_final(
    VertexOut in [[stage_in]],
    texture2d<float> baseTex  [[texture(0)]],
    texture2d<float> bloomTex [[texture(1)]],
    constant CRTSettings& sgs [[buffer(3)]],
    sampler s [[sampler(0)]]
) {
    float2 uv = in.uv;

    uv = apply_curvature(uv, sgs.curvature);

    if (uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1)
        discard_fragment();

    float3 base  = baseTex.sample(s, uv).rgb;
    float3 bloom = bloomTex.sample(s, uv).rgb * 1.2;
    float3 col = base + bloom;

    float scan = sin(in.screen_pos.y * 3.14159);
    col *= 0.85 + 0.15 * scan;

    col *= shadow_mask(in.screen_pos, sgs.shadowMaskMode);

    float off = 0.0015;
    col.r = baseTex.sample(s, uv + float2(off,0)).r;
    col.b = baseTex.sample(s, uv - float2(off,0)).b;

    float2 cc = (in.uv - 0.5);
    float vig = smoothstep(0.9, 0.3, length(cc));
    col *= vig;

    return float4(col, 1.0);
}
