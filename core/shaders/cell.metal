#include <metal_stdlib>
using namespace metal;

// Shared uniforms for all passes
struct Uniforms {
    float2 viewportSize;   // pixels
    float2 cellSize;       // pixels
    uint2  gridSize;       // cols, rows
};

// ─── Pass 1: Cell Backgrounds ───────────────────────────────────────────────

struct BgInstance {
    packed_float2 position; // grid col, row
    packed_uchar4 color;    // RGBA
};

struct BgVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex BgVertexOut bg_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device BgInstance* instances [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    // Quad: 2 triangles from 6 vertices (0-5)
    // 0─1    vertices: 0=TL, 1=TR, 2=BL, 3=BL, 4=TR, 5=BR
    // │╲│
    // 2─3
    float2 corners[] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    float2 corner = corners[vertexID];

    BgInstance inst = instances[instanceID];
    float2 gridPos = float2(inst.position[0], inst.position[1]);

    // Pixel position of this corner
    float2 pixelPos = (gridPos + corner) * uniforms.cellSize;

    // Convert to Metal NDC: [-1, 1] with Y up
    float2 ndc;
    ndc.x = (pixelPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pixelPos.y / uniforms.viewportSize.y) * 2.0;

    BgVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.color = float4(
        float(inst.color[0]) / 255.0,
        float(inst.color[1]) / 255.0,
        float(inst.color[2]) / 255.0,
        float(inst.color[3]) / 255.0
    );
    return out;
}

fragment float4 bg_fragment(BgVertexOut in [[stage_in]]) {
    return in.color;
}

// ─── Pass 2: Glyph Rendering ────────────────────────────────────────────────

struct GlyphInstance {
    packed_float2 position;  // grid col, row
    packed_float4 uvRect;    // x, y, w, h in normalized atlas coords
    packed_float2 glyphSize; // glyph size in pixels
    packed_float2 bearing;   // glyph bearing in pixels
    packed_uchar4 color;     // fg RGBA
};

struct GlyphVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

vertex GlyphVertexOut glyph_vertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device GlyphInstance* instances [[buffer(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    float2 corners[] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(0, 1), float2(1, 0), float2(1, 1)
    };
    float2 corner = corners[vertexID];

    GlyphInstance inst = instances[instanceID];
    float2 gridPos = float2(inst.position[0], inst.position[1]);
    float4 uvRect = float4(inst.uvRect[0], inst.uvRect[1], inst.uvRect[2], inst.uvRect[3]);
    float2 glyphSize = float2(inst.glyphSize[0], inst.glyphSize[1]);
    float2 bearing = float2(inst.bearing[0], inst.bearing[1]);

    // Pixel position: cell origin + bearing offset + corner * glyph size
    float2 cellOrigin = gridPos * uniforms.cellSize;
    float2 glyphOrigin = cellOrigin + bearing;
    float2 pixelPos = glyphOrigin + corner * glyphSize;

    // Convert to NDC
    float2 ndc;
    ndc.x = (pixelPos.x / uniforms.viewportSize.x) * 2.0 - 1.0;
    ndc.y = 1.0 - (pixelPos.y / uniforms.viewportSize.y) * 2.0;

    // Texture coordinates from atlas UV rect
    float2 texCoord = uvRect.xy + corner * uvRect.zw;

    GlyphVertexOut out;
    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = texCoord;
    out.color = float4(
        float(inst.color[0]) / 255.0,
        float(inst.color[1]) / 255.0,
        float(inst.color[2]) / 255.0,
        float(inst.color[3]) / 255.0
    );
    return out;
}

fragment float4 glyph_fragment(
    GlyphVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float alpha = atlas.sample(s, in.texCoord).r;
    return float4(in.color.rgb, in.color.a * alpha);
}

// ─── Pass 3: Cursor (reuses bg shader with alpha blending) ──────────────────
// Cursor uses the same bg_vertex/bg_fragment shaders with a semi-transparent color.
// No additional shader code needed — just pass a BgInstance with alpha < 255.
