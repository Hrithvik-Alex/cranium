#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position;
    float2 texcoord;
};

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
};

vertex VertexOut glyph_vertex_main(uint vid [[vertex_id]],
                              constant VertexIn *vertices [[buffer(0)]],
                              constant float2 &viewport [[buffer(1)]],
                              constant float &scroll_offset [[buffer(2)]]) {
    VertexOut out;
    float2 pos = vertices[vid].position;
    float2 scrolled = float2(pos.x, pos.y - scroll_offset);
    out.position = float4(scrolled.x / viewport.x * 2.0 - 1.0,
                          1.0 - scrolled.y / viewport.y * 2.0,
                          0.0, 1.0);
    out.texcoord = vertices[vid].texcoord;
    return out;
}

fragment float4 glyph_fragment_main(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
    float alpha = tex.sample(smp, in.texcoord).r;
    return float4(1.0, 1.0, 1.0, alpha);
}
