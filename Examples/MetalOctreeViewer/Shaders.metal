#include <metal_stdlib>
using namespace metal;

// Vertex shader inputs/outputs
struct VertexIn {
    float3 position [[attribute(0)]];
    float3 color [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 color;
    float pointSize [[point_size]];
};

struct Uniforms {
    float4x4 modelViewProjectionMatrix;
    float pointSize;
};

// Point cloud vertex shader
vertex VertexOut point_vertex(
    VertexIn in [[stage_in]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    VertexOut out;
    out.position = uniforms.modelViewProjectionMatrix * float4(in.position, 1.0);
    out.color = in.color;
    out.pointSize = uniforms.pointSize;
    return out;
}

// Point cloud fragment shader
fragment float4 point_fragment(
    VertexOut in [[stage_in]]
) {
    return float4(in.color, 1.0);
}

// Bounding box vertex shader (no color attribute)
struct BBoxVertexIn {
    float3 position [[attribute(0)]];
};

vertex VertexOut bbox_vertex(
    BBoxVertexIn in [[stage_in]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    VertexOut out;
    out.position = uniforms.modelViewProjectionMatrix * float4(in.position, 1.0);
    out.color = float3(0.3, 0.8, 0.3); // Green color for bounding boxes
    out.pointSize = 1.0;
    return out;
}

// Bounding box fragment shader
fragment float4 bbox_fragment(
    VertexOut in [[stage_in]]
) {
    return float4(in.color, 0.5); // Semi-transparent
}
