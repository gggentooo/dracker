/**
 * File:         shaders/ui2d.metal
 * Language:     Metal Shading Language (MSL 2.4+)
 * Phase:        Phase 7.4 — Metal 2D Batched Instanced Renderer
 *
 * Purpose:
 *   GPU vertex and fragment shaders for SynthTracker's Retina 60-120 Hz studio
 *   canvas. Renders batched instanced rounded rectangles, gradients, scissor-
 *   clipped panels, anti-aliased polylines/cubic Beziers (patchbay cables,
 *   envelopes, oscilloscopes), and R8 CoreText glyph quads.
 *
 * Dependencies:
 *   External: <metal_stdlib>
 *   Host:     source/platform/macos/metal_renderer.d
 *
 * Planned Shaders & Structs:
 *   - UIUniforms       : viewport size, backingScaleFactor, time
 *   - UIInstance       : bounds, cornerRadius, borderWidth, fill/border RGBA, uvRect, kind
 *   - ui2d_vertex      : instanced quad expansion in logical/physical pixel space
 *   - ui2d_fragment    : SDF rounded rect/border, R8 glyph coverage, curve AA
 */

#include <metal_stdlib>
using namespace metal;

struct UIUniforms {
    float2 viewportPx;
    float  scaleFactor;
    float  reserved;
};

struct UIInstance {
    float4 rectPx;       // x, y, width, height
    float4 uvRect;       // u0, v0, u1, v1
    float4 colorA;       // primary / top fill RGBA
    float4 colorB;       // border / bottom gradient RGBA
    float  cornerRadius;
    float  borderWidth;
    uint   kind;         // 0 = rounded rect, 1 = glyph R8, 2 = textured RGBA, 3 = AA line/bezier
    uint   flags;
};

struct VertexOut {
    float4 position [[position]];
    float2 localPx;
    float2 sizePx;
    float2 uv;
    float4 colorA;
    float4 colorB;
    float  cornerRadius;
    float  borderWidth;
    uint   kind;
};

vertex VertexOut ui2d_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant UIUniforms &u [[buffer(0)]],
                             constant UIInstance *instances [[buffer(1)]]) {
    constant UIInstance &inst = instances[iid];
    const float2 corners[4] = {
        float2(0.0f, 0.0f),
        float2(1.0f, 0.0f),
        float2(0.0f, 1.0f),
        float2(1.0f, 1.0f)
    };
    const uint indices[6] = { 0, 1, 2, 2, 1, 3 };
    float2 unit = corners[indices[vid % 6]];

    float2 posPx = inst.rectPx.xy + unit * inst.rectPx.zw;
    float2 ndc = (posPx / max(u.viewportPx, float2(1.0f))) * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f);

    VertexOut out;
    out.position = float4(ndc, 0.0f, 1.0f);
    out.localPx = unit * inst.rectPx.zw;
    out.sizePx = inst.rectPx.zw;
    out.uv = mix(inst.uvRect.xy, inst.uvRect.zw, unit);
    out.colorA = inst.colorA;
    out.colorB = inst.colorB;
    out.cornerRadius = inst.cornerRadius;
    out.borderWidth = inst.borderWidth;
    out.kind = inst.kind;
    return out;
}

fragment float4 ui2d_fragment(VertexOut in [[stage_in]],
                              texture2d<float> glyphAtlas [[texture(0)]],
                              sampler linearSampler [[sampler(0)]]) {
    if (in.kind == 1u) {
        float cov = glyphAtlas.sample(linearSampler, in.uv).r;
        return float4(in.colorA.rgb, in.colorA.a * cov);
    }
    return in.colorA;
}
