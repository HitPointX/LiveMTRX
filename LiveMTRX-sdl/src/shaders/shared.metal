#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 pos [[attribute(0)]];
};

struct InstanceIn {
    float2 inst_pos;
    float2 inst_size;
    uint  glyph_index;
    float intensity;
    float3 color;
};

struct Uniforms {
    float2 screen_size;
    float2 atlas_cell_uv; // uv size of one cell: (cell_w/atlas_w, cell_h/atlas_h)
    uint   atlas_cols;
    float  time;
};

struct CRTSettings {
    int shadowMaskMode;
    float curvature;
    float phosphorDecay;
    float dotCrawl;
    float colorBleed;
    float jitter;
    float roll;
    float tubeAge;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float intensity;
    float3 color;
    float2 screen_pos;
};
