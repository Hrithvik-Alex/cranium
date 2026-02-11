#include <metal_stdlib>
using namespace metal;

struct CursorVertexIn {
    float2 position;
};

struct CursorVertexOut {
    float4 position [[position]];
};

vertex CursorVertexOut cursor_vertex_main(uint vid [[vertex_id]],
                                           constant CursorVertexIn *vertices [[buffer(0)]],
                                           constant float2 &viewport [[buffer(1)]]) {
    CursorVertexOut out;
    float2 pos = vertices[vid].position;
    out.position = float4(pos.x / viewport.x * 2.0 - 1.0,
                          1.0 - pos.y / viewport.y * 2.0,
                          0.0, 1.0);
    return out;
}

fragment float4 cursor_fragment_main(CursorVertexOut in [[stage_in]],
                                      constant float &opacity [[buffer(0)]]) {
    return float4(1.0, 1.0, 1.0, opacity);
}
