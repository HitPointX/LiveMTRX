#include "shared.metal"

vertex VertexOut glyph_vert(
    VertexIn v [[stage_in]],
    const device InstanceIn* instances [[buffer(1)]],
    constant Uniforms& u [[buffer(2)]],
    uint iid [[instance_id]]
) {
    InstanceIn inst = instances[iid];

    float2 px = inst.inst_pos + v.pos * inst.inst_size;

    float2 ndc = (px / u.screen_size) * 2.0 - 1.0;
    ndc.y = -ndc.y;

    uint col = inst.glyph_index % u.atlas_cols;
    uint row = inst.glyph_index / u.atlas_cols;

    float2 uv0 = float2((float)col, (float)row) * u.atlas_cell_uv;
    float2 uv  = uv0 + v.pos * u.atlas_cell_uv;

    VertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.uv = uv;
    out.intensity = inst.intensity;
    out.color = inst.color;
    out.screen_pos = px;
    return out;
}
