#include <metal_stdlib>
using namespace metal;

struct SelectionVertexIn {
    float2 position;
};

struct SelectionVertexOut {
    float4 position [[position]];
};

vertex SelectionVertexOut selection_vertex_main(uint vid [[vertex_id]],
                                                 constant SelectionVertexIn *vertices [[buffer(0)]],
                                                 constant float2 &viewport [[buffer(1)]],
                                                 constant float &scroll_offset [[buffer(2)]]) {
    SelectionVertexOut out;
    float2 pos = vertices[vid].position;
    float2 scrolled = float2(pos.x, pos.y - scroll_offset);
    out.position = float4(scrolled.x / viewport.x * 2.0 - 1.0,
                          1.0 - scrolled.y / viewport.y * 2.0,
                          0.0, 1.0);
    return out;
}

fragment float4 selection_fragment_main(SelectionVertexOut in [[stage_in]]) {
    // With subtract blending (src=1, dst=1), this inverts destination RGB.
    return float4(1.0, 1.0, 1.0, 1.0);
}
