/**
 * File:         shaders/ui2d.metal
 * Language:     Metal Shading Language (MSL 2.4+)
 * Phase:        Phase 7.4 — Metal 2D Batched Instanced Renderer
 *
 * Purpose:
 *   GPU vertex and fragment shaders for SynthTracker's Retina 60-120 Hz studio canvas. One instanced
 *   6-vertex quad per UIInstance renders SDF rounded rectangles with borders and vertical gradients,
 *   R8 CoreText glyph quads (atlas sampled in pixel coordinates so atlas growth never invalidates UVs),
 *   RGBA textured quads, and anti-aliased round-capped line segments (polylines, Bezier cables, scopes).
 *   Output is premultiplied alpha (blend: one, oneMinusSourceAlpha).
 *
 * Dependencies:
 *   External: <metal_stdlib>
 *   Host:     source/platform/macos/metal_renderer.d (UIInstance mirrors gui.renderer.UIInstance, 96 bytes)
 *
 * Planned Shaders & Structs:
 *   - UIUniforms       : viewport size in pixels, backingScaleFactor, time
 *   - UIInstance       : rect, uv, colorA, colorB, colorBorder, cornerRadius, borderWidth, kind, flags
 *   - ui2d_vertex      : instanced quad expansion (axis-aligned for shapes/glyphs/images, oriented for lines)
 *   - ui2d_fragment    : SDF rounded rect + border + gradient, R8 glyph coverage, RGBA image, line AA
 */

#include <metal_stdlib>
using namespace metal;

struct UIUniforms {
    float2 viewportPx;
    float  scaleFactor;
    float  timeSeconds;
};

struct UIInstance {
    float4 rect;
    float4 uv;
    float4 colorA;
    float4 colorB;
    float4 colorBorder;
    float  cornerRadius;
    float  borderWidth;
    uint   kind;
    uint   flags;
};

struct VertexOut {
    float4 position [[position]];
    float2 localPx;
    float2 sizePx;
    float2 uv;
    float4 colorA [[flat]];
    float4 colorB [[flat]];
    float4 colorBorder [[flat]];
    float4 segment [[flat]];
    float  cornerRadius [[flat]];
    float  borderWidth [[flat]];
    uint   kind [[flat]];
};

constant uint KIND_SHAPE = 0u;
constant uint KIND_GLYPH = 1u;
constant uint KIND_IMAGE = 2u;
constant uint KIND_LINE = 3u;

vertex VertexOut ui2d_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant UIUniforms &u [[buffer(0)]],
                             const device UIInstance *instances [[buffer(1)]]) {
    const device UIInstance &inst = instances[iid];
    const float2 corners[6] = {
        float2(0.0f, 0.0f), float2(1.0f, 0.0f), float2(0.0f, 1.0f),
        float2(0.0f, 1.0f), float2(1.0f, 0.0f), float2(1.0f, 1.0f)
    };
    float2 unit = corners[vid % 6u];
    float2 posPx;

    if (inst.kind == KIND_LINE) {
        float2 a = inst.uv.xy;
        float2 b = inst.uv.zw;
        float2 d = b - a;
        float len = length(d);
        float2 dir = len > 1e-4f ? d / len : float2(1.0f, 0.0f);
        float2 nrm = float2(-dir.y, dir.x);
        float ext = inst.cornerRadius + 1.5f;
        float2 along = mix(a - dir * ext, b + dir * ext, unit.x);
        posPx = along + nrm * mix(-ext, ext, unit.y);
    } else {
        posPx = inst.rect.xy + unit * inst.rect.zw;
    }

    float2 ndc = (posPx / max(u.viewportPx, float2(1.0f))) * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f);

    VertexOut out;
    out.position = float4(ndc, 0.0f, 1.0f);
    out.localPx = unit * inst.rect.zw;
    out.sizePx = inst.rect.zw;
    out.uv = mix(inst.uv.xy, inst.uv.zw, unit);
    out.colorA = inst.colorA;
    out.colorB = inst.colorB;
    out.colorBorder = inst.colorBorder;
    out.segment = inst.uv;
    out.cornerRadius = inst.cornerRadius;
    out.borderWidth = inst.borderWidth;
    out.kind = inst.kind;
    return out;
}

static float roundedBoxDistance(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - (halfSize - float2(radius));
    return length(max(q, float2(0.0f))) + min(max(q.x, q.y), 0.0f) - radius;
}

static float segmentDistance(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float denom = max(dot(ba, ba), 1e-6f);
    float h = clamp(dot(pa, ba) / denom, 0.0f, 1.0f);
    return length(pa - ba * h);
}

fragment float4 ui2d_fragment(VertexOut in [[stage_in]],
                              texture2d<float> glyphAtlas [[texture(0)]],
                              texture2d<float> image [[texture(1)]]) {
    constexpr sampler atlasSampler(coord::pixel, filter::linear, address::clamp_to_edge);
    constexpr sampler imageSampler(coord::normalized, filter::linear, address::clamp_to_edge);

    if (in.kind == KIND_GLYPH) {
        float cov = glyphAtlas.sample(atlasSampler, in.uv).r;
        float a = in.colorA.a * cov;
        return float4(in.colorA.rgb * a, a);
    }
    if (in.kind == KIND_IMAGE) {
        float4 texel = image.sample(imageSampler, in.uv) * in.colorA;
        return float4(texel.rgb * texel.a, texel.a);
    }
    if (in.kind == KIND_LINE) {
        float d = segmentDistance(in.position.xy, in.segment.xy, in.segment.zw) - in.cornerRadius;
        float cov = clamp(0.5f - d, 0.0f, 1.0f);
        float a = in.colorA.a * cov;
        return float4(in.colorA.rgb * a, a);
    }

    float2 halfSize = in.sizePx * 0.5f;
    float radius = min(in.cornerRadius, min(halfSize.x, halfSize.y));
    float d = roundedBoxDistance(in.localPx - halfSize, halfSize, radius);
    float coverage = clamp(0.5f - d, 0.0f, 1.0f);
    float t = in.sizePx.y > 0.0f ? clamp(in.localPx.y / in.sizePx.y, 0.0f, 1.0f) : 0.0f;
    float4 fill = mix(in.colorA, in.colorB, t);
    float borderMask = in.borderWidth > 0.0f ? clamp(d + in.borderWidth + 0.5f, 0.0f, 1.0f) : 0.0f;
    float3 premul = fill.rgb * fill.a * (1.0f - borderMask) + in.colorBorder.rgb * in.colorBorder.a * borderMask;
    float alpha = fill.a * (1.0f - borderMask) + in.colorBorder.a * borderMask;
    return float4(premul * coverage, alpha * coverage);
}
