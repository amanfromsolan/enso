#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The colour pad's glass drop (SpaceColourPad.swift, `PadSurface`).
//
// A port of drawGlass() in
// internal-docs/2026-11-09-themes-and-settings/space-themes/blob-styles/liquid-glass.html.
// One layerEffect over the pad (field + dots): each pixel is mapped back through the inverse
// squash matrix to the unit drop, then gets the mockup's edge lensing, colour fringe, body tint,
// rim veil, through-light, edge line, rim light and specular. Pixels outside the drop return the
// layer untouched, so only the drop's region costs anything.
//
// Colours are mixed in premultiplied space: `c = c * (1 - m) + x * m`. Over whatever is behind a
// transparent sample (the sheet, where the drop leans past the pad) that is exactly the mockup's
// `c += (x - c) * m` on the composited colour.

// The mockup's `LG` recipe (base Liquid glass, no variant).
constant float LG_TINT_DARK = 0.10;    // how much of the hue sits in the glass body
constant float LG_TINT_LIGHT = 0.20;
constant float LG_CENTRE = 0.90;       // lens: centre scale (<1 magnifies)
constant float LG_RIM = 0.58;          // how far the rim reaches out
constant float LG_FRINGE = 0.07;       // R/B split at the rim
constant float LG_VEIL_DARK = 0.16;    // frost toward the rim
constant float LG_VEIL_LIGHT = 0.14;
constant float LG_EDGE_DARK = 0.55;
constant float LG_EDGE_LIGHT = 0.50;
constant float LG_RIM_LIGHT = 1.0;
constant float LG_GLOW = 1.0;
constant float2 LG_LIGHT = float2(-0.6, -0.8);   // toward the light: top left

static float4 toward(float4 c, float3 x, float m) {
    return c * (1.0 - m) + float4(x, 1.0) * m;
}

static float3 saturateBy(float3 c, float f) {
    float l = dot(c, float3(0.3, 0.59, 0.11));
    return clamp(l + (c - l) * f, 0.0, 1.0);
}

/// position:     pixel, in the effect layer's points.
/// centre:       the drop's centre, same space.
/// radius:       the drop's radius at rest, points (blob.html BR).
/// squash:       (a, c, d) of the symmetric matrix [a c; c d], lift scale included.
/// tint:         the vivid colour of the hue under the drop (mockup `tintC`).
/// strength:     continuous strength under the drop, 0...3.
/// dark:         1 in dark appearance, 0 in light.
/// displayScale: device pixels per point, for the anti-aliased rim.
[[ stitchable ]] half4 ensoColourPadGlass(
    float2 position,
    SwiftUI::Layer layer,
    float2 centre,
    float radius,
    float3 squash,
    half4 tint,
    float strength,
    float dark,
    float displayScale
) {
    float a = squash.x, c = squash.y, d = squash.z;
    float det = a * d - c * c;
    float ia = d / det, ib = -c / det, id = a / det;
    float minScale = min(min(min(abs(a + c), abs(a - c)), min(abs(d + c), abs(d - c))), (a + d) * 0.5);
    if (minScale <= 0.0) minScale = 1.0;
    float aa = 1.2 / (radius * displayScale * minScale);

    float2 p = (position - centre) / radius;
    float2 q = float2(ia * p.x + ib * p.y, ib * p.x + id * p.y);
    float r2 = dot(q, q);
    if (r2 > (1.0 + aa) * (1.0 + aa)) return layer.sample(position);

    bool isDark = dark > 0.5;
    float3 tintC = tint.a > 0.0 ? float3(tint.rgb) / float(tint.a) : float3(0.0);
    float3 white = float3(1.0);

    float r = sqrt(r2);
    float cov = clamp((1.0 - r) / aa + 0.5, 0.0, 1.0);
    float rc = min(r, 0.995);
    float k = 1.0 - sqrt(1.0 - rc * rc);
    float2 u = r > 1e-6 ? q / r : float2(0.0);

    // Liquid Glass lensing: nearly 1:1 in the middle, the rim reaches out and bends what's around it inward.
    float sl = LG_CENTRE * rc + LG_RIM * k;
    float2 l = u * sl;
    float2 s = float2(a * l.x + c * l.y, c * l.x + d * l.y) * radius;
    float2 v = float2(a * u.x + c * u.y, c * u.x + d * u.y);
    float disp = k * LG_FRINGE * radius;
    float2 b = centre + s;
    float4 sr = float4(layer.sample(b - v * disp));
    float4 sg = float4(layer.sample(b));
    float4 sb = float4(layer.sample(b + v * disp));
    float4 col = float4(sr.r, sg.g, sb.b, sg.a);
    col.rgb = min(col.rgb, col.a);   // the split samples can disagree on alpha at the pad's edge

    float ndl = dot(u, LG_LIGHT);

    // A whisper of the colour in the glass itself.
    float bodyTint = (isDark ? LG_TINT_DARK : LG_TINT_LIGHT) * clamp(strength, 0.0, 1.0);
    col = toward(col, tintC, bodyTint * (0.5 + 0.5 * k));

    // A soft frost toward the rim.
    float3 frostC = isDark ? mix(tintC, white, 0.35) : mix(tintC, white, 0.78);
    col = toward(col, frostC, smoothstep(0.62, 1.0, r) * (isDark ? LG_VEIL_DARK : LG_VEIL_LIGHT));

    // Light passing through, gathered low on the far side.
    float3 glowC = mix(saturateBy(tintC, 1.6), white, 0.3);
    float glow = smoothstep(0.35, 0.86, r) * (1.0 - smoothstep(0.86, 1.0, r))
        * pow(max(0.0, -ndl), 1.6) * (isDark ? 0.42 : 0.6) * LG_GLOW;
    col = toward(col, glowC, glow);

    // Thin edge for definition.
    float3 edgeC = isDark ? float3(12.0, 13.0, 16.0) / 255.0 : mix(tintC, float3(40.0, 44.0, 54.0) / 255.0, 0.7);
    col = toward(col, edgeC, smoothstep(0.92, 1.0, r) * (isDark ? LG_EDGE_DARK : LG_EDGE_LIGHT));

    // Rim light: the bright Liquid Glass edge, strong toward the light, softer where it leaves.
    float band = smoothstep(0.8, 0.95, r) * (1.0 - smoothstep(0.955, 1.0, r));
    float rim = LG_RIM_LIGHT * band * (pow(max(0.0, ndl), 1.3) * (isDark ? 0.78 : 0.95)
        + pow(max(0.0, -ndl), 2.0) * (isDark ? 0.32 : 0.5));
    col = toward(col, white, min(rim, 1.0));

    // A soft specular that squashes with the drop: an ellipse at (-.4, -.46) of the unit drop,
    // turned -0.62 rad, squashed to .52 high, .27 across, white .8/.92 -> .42/.55 at half -> 0.
    float2 w = q - float2(-0.4, -0.46);
    float cs = cos(0.62), sn = sin(0.62);
    float2 e = float2(w.x * cs - w.y * sn, (w.x * sn + w.y * cs) / 0.52);
    float t = length(e) / 0.27;
    float a0 = isDark ? 0.8 : 0.92, a1 = isDark ? 0.42 : 0.55;
    float spec = t < 0.5 ? mix(a0, a1, t / 0.5) : (t < 1.0 ? mix(a1, 0.0, (t - 0.5) / 0.5) : 0.0);
    col = toward(col, white, spec);

    // Anti-aliased rim over the unlensed pad.
    float4 under = float4(layer.sample(position));
    return half4(col * cov + under * (1.0 - cov));
}
