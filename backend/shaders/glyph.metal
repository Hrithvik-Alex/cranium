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

vertex VertexOut vertex_main(uint vid [[vertex_id]],
                              constant VertexIn *vertices [[buffer(0)]]) {
    VertexOut out;
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    out.texcoord = vertices[vid].texcoord;
    return out;
}

fragment float4 fragment_main(VertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
    float alpha = tex.sample(smp, in.texcoord).r;
    return float4(1.0, 1.0, 1.0, alpha);
}
