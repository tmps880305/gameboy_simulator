#include <metal_stdlib>
using namespace metal;

struct ScreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

// Full-screen quad generated from the vertex id; the viewport does the scaling.
vertex ScreenVertexOut screen_vertex(uint vid [[vertex_id]]) {
    const float2 positions[4] = { {-1, -1}, {1, -1}, {-1, 1}, {1, 1} };
    const float2 uvs[4] = { {0, 1}, {1, 1}, {0, 0}, {1, 0} };
    ScreenVertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = uvs[vid];
    return out;
}

fragment float4 screen_fragment(ScreenVertexOut in [[stage_in]],
                                texture2d<float> screen [[texture(0)]],
                                sampler nearest [[sampler(0)]]) {
    return float4(screen.sample(nearest, in.uv).rgb, 1);
}
