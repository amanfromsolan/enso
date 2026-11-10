import Foundation

// MARK: - Space colour → chrome theme ("Tonal")
//
// A space's colour (`SpaceColour`: one of 9 hues + strength 0–3) becomes a
// whole-chrome theme: every sidebar/gutter token is one step of an OKLCH
// tonal ramp of the hue. This file is the pure maths, a Swift port of the
// colour-into-theme mockups (internal-docs/2026-11-09-themes-and-settings/
// space-themes/colour-into-theme/_src: colour.js for the maths, x/tonal.js
// for the ramp, which is the source of truth for every number below).
// SpaceToneChrome.swift has the SwiftUI side (environment, styles, the
// crossfade driver).
//
// ## API
//
// Tuned palettes (cached; 9 hues × 3 strengths × light/dark, built once):
//
//     SpaceTone.palette(for: SpaceColour, dark: Bool) -> SpaceTonePalette
//
// Continuous, for the colour picker's live drag (cheap enough per frame):
//
//     SpaceTone.palette(hue: Double, strength: Double, dark: Bool) -> SpaceTonePalette
//
//   - `hue` 0...8 in `SpaceHue` order; a fractional value blends the two
//     neighbouring tuned palettes in OKLab (clamped at both ends, no wrap).
//   - `strength` 0...3. 1...3 blends the tuned strengths. Below 1 it returns
//     Subtle with `presence = strength`: the chrome mixes that much of the
//     palette over today's untinted look, so 0 is exactly "no colour".
//   - The blend is clamped afterwards: every contrast pair is re-checked and
//     any ink that fails is moved (`fit`) until it passes.
//
// Live preview while the picker drags (store side, TerminalSessionStore):
//
//     store.previewColour = SpaceColourPreview(spaceID:, hue:, strength:)
//         // every drag frame; rendered instantly (no animation), never saved.
//     store.commitSpaceColour(spaceID, SpaceColour(hue:, strength:))
//         // on release: saves, clears the preview, springs to the snapped value.
//     store.previewColour = .settling(spaceID, on: SpaceColour(hue:, strength:))
//         // the picker's snap on release when the colour isn't saved yet
//         // (the Edit Space sheet saves on Save): a preview with
//         // `animated: true`, so the chrome springs from the dragged value
//         // to the snapped one instead of jumping. The next plain preview
//         // (another drag) is instant again.
//     store.previewColour = nil      // cancel: springs back to the saved colour.
//     store.setSpaceColour(spaceID, to:)  // plain set; springs too.
//
// A preview for a space that isn't active is ignored until it is. Whoever
// sets a preview must clear it when the picker goes away (the sheet's
// dismiss does, whatever closed it).
//
// The picker's own field and drop (SpaceColourPad, in the Edit Space sheet):
//
//     SpaceTone.pickerField(hue:strength:dark:) -> ToneRGB
//         // the pad's colour at any point: the tonal surface over the
//         // untinted frost, a touch toward the vivid swatch, fading to
//         // the frost at strength 0. Cheap (cached Lab table).
//     SpaceTone.pickerAccent(hue:dark:) -> ToneRGB
//         // the vivid swatch, blended between neighbours (glass tint).
//
// The terminal card's tint (x/terminal.js): every palette carries
// `terminalTint`, a colour plus alpha (0 at Subtle, 1.5–1.8% at Medium, 3%
// at Strong) that crossfades with the rest of the tokens.
//
//     SpaceTone.terminalTint(in: palette, scale:) -> ToneRGB
//         // what the card overlay draws, presence applied (alpha 0 = none).
//
// Pick the palette by the TERMINAL background's lightness, not the system
// appearance. The overlay layers are fed straight from the tone driver in
// AppKit (`TerminalTintFeed`, SpaceToneChrome.swift), never through SwiftUI.
//
// Contrast: `SpaceTone.checks(_:)` lists every pair the chrome draws (text
// ≥ 4.5:1, icons/glyphs ≥ 3:1, on the surface, on hover, on the chip and on
// the glass); tests run it for every hue × strength × appearance.

/// An sRGB colour as colour.js keeps them: components 0–255 (not rounded
/// unless they came out of `OKLab.toRGB`), alpha 0–1.
nonisolated struct ToneRGB: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }

    func with(alpha: Double) -> ToneRGB { ToneRGB(r, g, b, alpha) }
    var opaque: ToneRGB { with(alpha: 1) }
}

// MARK: - OKLab / OKLCH, WCAG (port of colour.js)

nonisolated enum OKLab {
    static func toLinear(_ v: Double) -> Double {
        let v = v / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    static func toGamma(_ v: Double) -> Double {
        255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
    }

    static func lab(_ c: ToneRGB) -> (L: Double, a: Double, b: Double) {
        let r = toLinear(c.r), g = toLinear(c.g), b = toLinear(c.b)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
        )
    }

    static func linear(_ L: Double, _ a: Double, _ b: Double) -> (Double, Double, Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.291485548 * b, 3)
        return (
            4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
            -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
            -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s
        )
    }

    private static func inGamut(_ v: (Double, Double, Double)) -> Bool {
        let lo = -1e-4, hi = 1 + 1e-4
        return v.0 >= lo && v.0 <= hi && v.1 >= lo && v.1 <= hi && v.2 >= lo && v.2 <= hi
    }

    private static func clamp01(_ v: Double) -> Double { min(1, max(0, v)) }

    /// Rounded to whole 0–255 steps, as colour.js does.
    static func toRGB(_ L: Double, _ a: Double, _ b: Double) -> ToneRGB {
        let v = linear(L, a, b)
        return ToneRGB(
            (toGamma(clamp01(v.0))).rounded(),
            (toGamma(clamp01(v.1))).rounded(),
            (toGamma(clamp01(v.2))).rounded()
        )
    }

    /// OKLCH → sRGB, reducing chroma (keeping L and hue) to stay in gamut.
    static func oklch(_ L: Double, _ C: Double, _ h: Double) -> ToneRGB {
        let L = clamp01(L)
        let hr = h * .pi / 180
        let ca = cos(hr), sa = sin(hr)
        if inGamut(linear(L, C * ca, C * sa)) {
            return toRGB(L, C * ca, C * sa)
        }
        var lo = 0.0, hi = C
        for _ in 0..<18 {
            let mid = (lo + hi) / 2
            if inGamut(linear(L, mid * ca, mid * sa)) { lo = mid } else { hi = mid }
        }
        return toRGB(L, lo * ca, lo * sa)
    }

    static func lch(_ c: ToneRGB) -> (L: Double, C: Double, h: Double) {
        let (L, a, b) = lab(c)
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return (L, hypot(a, b), h)
    }

    /// WCAG 2 relative luminance.
    static func luminance(_ c: ToneRGB) -> Double {
        0.2126 * toLinear(c.r) + 0.7152 * toLinear(c.g) + 0.0722 * toLinear(c.b)
    }

    /// WCAG 2 contrast ratio of two opaque colours.
    static func contrast(_ x: ToneRGB, _ y: ToneRGB) -> Double {
        let a = luminance(x), b = luminance(y)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// `fg` at its own alpha (or `alpha`) composited over opaque `bg`.
    static func over(_ fg: ToneRGB, _ alpha: Double? = nil, _ bg: ToneRGB) -> ToneRGB {
        let a = alpha ?? fg.a
        return ToneRGB(fg.r * a + bg.r * (1 - a), fg.g * a + bg.g * (1 - a), fg.b * a + bg.b * (1 - a))
    }

    /// Mix in OKLab (the crossfade space); alpha mixes linearly.
    static func mix(_ x: ToneRGB, _ y: ToneRGB, _ t: Double) -> ToneRGB {
        if t <= 0 { return x }
        if t >= 1 { return y }
        let A = lab(x), B = lab(y)
        var out = toRGB(A.L + (B.L - A.L) * t, A.a + (B.a - A.a) * t, A.b + (B.b - A.b) * t)
        out.a = x.a + (y.a - x.a) * t
        return out
    }

    /// Moves `fg`'s OKLCH lightness away from `bg` (hue and chroma kept)
    /// until the pair reaches `minimum`.
    static func fit(_ fg: ToneRGB, _ bg: ToneRGB, _ minimum: Double) -> ToneRGB {
        if contrast(fg, bg) >= minimum { return fg.opaque }
        var (L, C, h) = lch(fg)
        let dir: Double = luminance(bg) > 0.18 ? -1 : 1
        for _ in 0..<100 {
            L = clamp01(L + dir * 0.01)
            let c = oklch(L, C, h)
            if contrast(c, bg) >= minimum || L <= 0 || L >= 1 { return c }
        }
        return oklch(L, C, h)
    }

    /// tonal.js's `fitAll`: a small margin over the minimum, and a few
    /// rounds so fixing one ground can't break another.
    static func fitAll(_ fg: ToneRGB, _ grounds: [ToneRGB], _ minimum: Double) -> ToneRGB {
        var fg = fg
        for _ in 0..<6 {
            for g in grounds { fg = fit(fg, g, minimum + 0.02) }
        }
        return fg
    }

    /// Euclidean distance in OKLab (×100 reads like CIE ΔE).
    static func distance(_ x: ToneRGB, _ y: ToneRGB) -> Double {
        let A = lab(x), B = lab(y)
        return ((A.L - B.L) * (A.L - B.L) + (A.a - B.a) * (A.a - B.a) + (A.b - B.b) * (A.b - B.b)).squareRoot()
    }
}

// MARK: - Palette

/// Every chrome token one space colour produces, for one appearance.
/// Opaque unless noted; inks are already contrast-fitted.
nonisolated struct SpaceTonePalette: Hashable, Sendable {
    /// Sidebar ground (drawn over the frost at `SpaceTone.groundOpacity`).
    var surface: ToneRGB
    /// The window gutter around the terminal card: one step deeper.
    var gutter: ToneRGB
    /// Selected-row chip and the capsule/pill thumbs.
    var chip: ToneRGB
    /// The chip's hairline rim; carries its alpha.
    var chipRim: ToneRGB
    /// The chip's shadow colour (the views apply the two shadow alphas).
    var shadow: ToneRGB
    /// Hover/selection wash ink, used at the call site's opacity.
    var hover: ToneRGB
    /// Glass tint for the capsule, pill and + circle; carries its alpha.
    var glass: ToneRGB
    /// Glass hairline (pre-glass fallback); carries its alpha.
    var glassRim: ToneRGB
    /// The text steps, named for the opacities they replace.
    var t95: ToneRGB
    var t90: ToneRGB
    var t82: ToneRGB
    var t62: ToneRGB
    var t40: ToneRGB
    /// Folder and tab glyphs, badges.
    var glyph: ToneRGB
    /// Terminal card hairline (computed, not drawn: the card has no rim).
    var cardRim: ToneRGB
    /// Focus / drop-indicator accent.
    var accent: ToneRGB
    /// This space's icon in the pill while ANOTHER space is active: its
    /// glyph, held at 3:1 on every space's glass.
    var cell: ToneRGB
    /// The terminal card's background tint (x/terminal.js), drawn over the
    /// whole card at its own alpha: 0 at Subtle, ≤ 3% at Strong. Which
    /// appearance's palette applies is the TERMINAL theme's call (its
    /// background's lightness), not the chrome's. See
    /// `SpaceTone.terminalTint(in:scale:)`.
    var terminalTint = ToneRGB(0, 0, 0, 0)
    /// How much of the palette is in effect over today's untinted chrome:
    /// 0 = no colour (draw exactly today's tokens), 1 = fully tinted.
    var presence: Double = 1

    /// The ground the sidebar's text actually sits on, for contrast.
    var hoverGround: ToneRGB { OKLab.over(hover, SpaceTone.rowHoverAlpha, surface) }
    var nameHoverGround: ToneRGB { OKLab.over(hover, SpaceTone.nameHoverAlpha, surface) }
    var glassGround: ToneRGB { OKLab.over(glass, nil, surface) }

    static let tokenPaths: [WritableKeyPath<SpaceTonePalette, ToneRGB>] = [
        \.surface, \.gutter, \.chip, \.chipRim, \.shadow, \.hover, \.glass, \.glassRim,
        \.t95, \.t90, \.t82, \.t62, \.t40, \.glyph, \.cardRim, \.accent, \.cell, \.terminalTint,
    ]

    /// OKLab mix of every token. A side with no presence contributes no
    /// colour (only its lack of presence), so fading to or from "no colour"
    /// never drags the tokens through an arbitrary hue.
    static func mix(_ a: SpaceTonePalette, _ b: SpaceTonePalette, _ t: Double) -> SpaceTonePalette {
        if t <= 0 { return a }
        if t >= 1 { return b }
        var out = a
        if a.presence <= 0 {
            out = b
        } else if b.presence > 0 {
            for path in tokenPaths {
                out[keyPath: path] = OKLab.mix(a[keyPath: path], b[keyPath: path], t)
            }
        }
        out.presence = a.presence + (b.presence - a.presence) * t
        return out
    }
}

// MARK: - The Tonal ramp (port of x/tonal.js)

nonisolated enum SpaceTone {
    /// The sidebar ground's opacity over the translucent frost. Tonal's
    /// contrast numbers are measured on the opaque surface; the README
    /// asks for ≥ ~85% so the frost leaking through can't move them much.
    static let groundOpacity: Double = 0.9

    /// The app's hover washes (Theme.ink × these, over the surface): rows
    /// use 0.05–0.07, the space name 0.08, the sidebar toggle 0.09.
    /// tonal.js checks 0.05 / 0.06; the app checks its own, higher values.
    static let rowHoverAlpha: Double = 0.07
    static let nameHoverAlpha: Double = 0.08
    static let buttonHoverAlpha: Double = 0.09

    /// The swatch row: OKLCH hue angle and peak chroma come from the light
    /// swatch (the macOS accent); graphite is a fixed cool slate.
    static let swatches: [SpaceHue: (light: UInt32, dark: UInt32)] = [
        .blue: (0x007AFF, 0x0A84FF), .purple: (0xAF52DE, 0xBF5AF2), .pink: (0xFF2D55, 0xFF375F),
        .red: (0xFF3B30, 0xFF453A), .orange: (0xFF9500, 0xFF9F0A), .yellow: (0xFFCC00, 0xFFD60A),
        .green: (0x34C759, 0x30D158), .teal: (0x30B0C7, 0x40C8E0), .graphite: (0x8E8E93, 0x98989D),
    ]

    static let hueAngles: [SpaceHue: (h: Double, c: Double)] = {
        var out: [SpaceHue: (h: Double, c: Double)] = [:]
        for hue in SpaceHue.allCases {
            let (_, C, h) = OKLab.lch(ToneRGB(hex: swatches[hue]!.light))
            out[hue] = hue == .graphite ? (255, 0.014) : (h, C)
        }
        return out
    }()

    /// Strength → chroma factor for the whole ramp.
    static let strengthFactor: [Double] = [0.35, 0.7, 1]

    /// Per-hue surface hue, ink hue and chroma scale. Yellow inks go ochre in
    /// light and its dark surfaces lean amber with less chroma (no khaki);
    /// graphite is a cool slate at low chroma.
    private static func hueShape(_ hue: SpaceHue, dark: Bool) -> (s: Double, i: Double, k: Double) {
        switch (hue, dark) {
        case (.yellow, false): return (92, 76, 1)
        case (.yellow, true): return (80, 92, 0.7)
        case (.orange, false): return (62, 52, 0.95)
        case (.orange, true): return (58, 66, 0.85)
        case (.graphite, false): return (252, 258, 0.32)
        case (.graphite, true): return (252, 250, 0.34)
        case (.teal, false): return (208, 212, 1.1)
        case (.teal, true): return (208, 205, 1.1)
        case (.green, false): return (150, 150, 0.9)
        case (.green, true): return (152, 148, 0.9)
        default:
            let h = hueAngles[hue]!.h
            return (h, h, 1)
        }
    }

    private enum Role: CaseIterable {
        case surface, gutter, chip, chipRim, shadow, hover, glass, glassRim
        case t95, t90, t82, t62, t40, glyph, cardRim, accent

        var isInk: Bool {
            switch self {
            case .t95, .t90, .t82, .t62, .t40, .glyph, .hover, .shadow, .cardRim, .glassRim, .accent: true
            default: false
            }
        }
    }

    /// [L, C] per role, C before the strength factor. Separate ramps, not
    /// an inversion: high-L surfaces with deep ink in light, low-L surfaces
    /// with pale ink in dark.
    private static func lc(_ role: Role, dark: Bool) -> (L: Double, C: Double) {
        if dark {
            switch role {
            // Lead review: surface/gutter/chip chroma raised from
            // .028/.026/.036; it was quieter than Today at Strong.
            case .surface: return (0.268, 0.046)
            case .gutter: return (0.238, 0.042)
            case .chip: return (0.362, 0.052)
            case .chipRim: return (0.78, 0.04)
            case .shadow: return (0.10, 0.02)
            case .hover: return (0.95, 0.03)
            case .glass: return (0.82, 0.04)
            case .glassRim: return (0.86, 0.04)
            case .t95: return (0.965, 0.012)
            case .t90: return (0.935, 0.018)
            case .t82: return (0.89, 0.024)
            case .t62: return (0.785, 0.035)
            case .t40: return (0.67, 0.035)
            case .glyph: return (0.79, 0.10)
            case .cardRim: return (0.10, 0.015)
            case .accent: return (0.72, 0.14)
            }
        }
        switch role {
        case .surface: return (0.93, 0.036)
        case .gutter: return (0.908, 0.04)
        case .chip: return (0.988, 0.012)
        case .chipRim: return (0.997, 0.004)
        case .shadow: return (0.30, 0.06)
        case .hover: return (0.32, 0.08)
        case .glass: return (0.978, 0.016)
        case .glassRim: return (0.36, 0.06)
        case .t95: return (0.21, 0.035)
        case .t90: return (0.25, 0.04)
        case .t82: return (0.31, 0.05)
        case .t62: return (0.43, 0.06)
        case .t40: return (0.53, 0.06)
        case .glyph: return (0.50, 0.13)
        case .cardRim: return (0.30, 0.05)
        case .accent: return (0.55, 0.16)
        }
    }

    static func glassAlpha(dark: Bool) -> Double { dark ? 0.085 : 0.62 }

    private static func ramp(_ hue: SpaceHue, strength: Int, dark: Bool) -> [Role: ToneRGB] {
        let shape = hueShape(hue, dark: dark)
        let f = strengthFactor[strength - 1] * shape.k
        var out: [Role: ToneRGB] = [:]
        for role in Role.allCases {
            let (L, C) = lc(role, dark: dark)
            // Glyphs keep a floor of colour so Subtle still says which
            // space you're in.
            let c = role == .glyph ? max(C * f, hue == .graphite ? 0.012 : 0.04) : C * f
            out[role] = OKLab.oklch(L, c, role.isInk ? shape.i : shape.s)
        }
        return out
    }

    /// tonal.js `build()`: the ramp with its inks fitted to the grounds they
    /// sit on. `cell` is filled in by the table (it needs every glass).
    private static func build(_ hue: SpaceHue, strength: Int, dark: Bool) -> SpaceTonePalette {
        let t = ramp(hue, strength: strength, dark: dark)
        let surface = t[.surface]!, chip = t[.chip]!
        let glassTint = t[.glass]!.with(alpha: glassAlpha(dark: dark))
        let hov = OKLab.over(t[.hover]!, 0.05, surface)
        let nameHov = OKLab.over(t[.hover]!, 0.06, surface)
        let glass = OKLab.over(glassTint, nil, surface)
        var p = SpaceTonePalette(
            surface: surface,
            gutter: t[.gutter]!,
            chip: chip,
            chipRim: t[.chipRim]!.with(alpha: dark ? 0.2 : 1),
            shadow: t[.shadow]!,
            hover: t[.hover]!,
            glass: glassTint,
            glassRim: t[.glassRim]!.with(alpha: dark ? 0.13 : 0.11),
            t95: OKLab.fitAll(t[.t95]!, [chip], 4.5),
            t90: OKLab.fitAll(t[.t90]!, [surface, nameHov, chip], 4.5),
            t82: OKLab.fitAll(t[.t82]!, [surface, hov, glass], 4.5),
            t62: OKLab.fitAll(t[.t62]!, [surface, hov, glass], 4.5),
            t40: OKLab.fitAll(t[.t40]!, [surface, nameHov], 3),
            glyph: OKLab.fitAll(t[.glyph]!, [surface, hov, chip], 3),
            cardRim: t[.cardRim]!.with(alpha: dark ? 0.55 : 0.2),
            accent: t[.accent]!,
            cell: t[.glyph]!,
            terminalTint: terminalTint(hue, strength: strength, dark: dark)
        )
        p.cell = p.glyph
        return p
    }

    /// The app draws a few pairs tonal.js doesn't (higher hover washes, a
    /// sleeping selected row's dimmer text on the chip, the toggle's hover):
    /// fit those too. Usually a no-op; it never makes a passing ink fail.
    fileprivate static func clamp(_ p: SpaceTonePalette, glasses: [ToneRGB]) -> SpaceTonePalette {
        var p = p
        let s = p.surface, hov = p.hoverGround, name = p.nameHoverGround, glass = p.glassGround, chip = p.chip
        let button = OKLab.over(p.hover, buttonHoverAlpha, s)
        let buttonOnRow = OKLab.over(p.hover, buttonHoverAlpha, hov)
        for _ in 0..<2 {
            p.t95 = OKLab.fitAll(p.t95, [chip, s], 4.5)
            p.t90 = OKLab.fitAll(p.t90, [s, name, chip, hov, button, buttonOnRow, glass], 4.5)
            p.t82 = OKLab.fitAll(p.t82, [s, hov, name, button, glass], 4.5)
            p.t62 = OKLab.fitAll(p.t62, [s, hov, glass, chip, buttonOnRow], 4.5)
            p.t40 = OKLab.fitAll(p.t40, [s, name, hov], 3)
            p.glyph = OKLab.fitAll(p.glyph, [s, hov, chip], 3)
        }
        p.cell = OKLab.fitAll(p.cell, glasses + [glass], 3)
        return p
    }

    // MARK: Cache

    /// [dark ? 1 : 0][hue][strength - 1]
    private static let table: [[[SpaceTonePalette]]] = {
        [false, true].map { dark in
            let built = SpaceHue.allCases.map { hue in
                (1...3).map { build(hue, strength: $0, dark: dark) }
            }
            let glasses = built.flatMap { $0.map(\.glassGround) }
            return built.map { row in row.map { clamp($0, glasses: glasses) } }
        }
    }()

    /// Every tuned glass of one appearance (other spaces' pill icons must
    /// read on all of them).
    static func allGlasses(dark: Bool) -> [ToneRGB] {
        glassTable[dark ? 1 : 0]
    }

    /// Built once: the picker's continuous palette clamps against these on
    /// every drag frame, and each is an OKLab composite.
    private static let glassTable: [[ToneRGB]] = [false, true].map { dark in
        table[dark ? 1 : 0].flatMap { $0.map(\.glassGround) }
    }

    /// The tuned palette, before the app's extra clamp (what tonal.js
    /// produces), for cross-checking against the mockup.
    static func unclampedPalette(_ hue: SpaceHue, strength: Int, dark: Bool) -> SpaceTonePalette {
        build(hue, strength: min(max(strength, 1), 3), dark: dark)
    }

    static func tuned(_ hue: SpaceHue, strength: Int, dark: Bool) -> SpaceTonePalette {
        table[dark ? 1 : 0][hue.rawValue][min(max(strength, 1), 3) - 1]
    }

    // MARK: Public entry points

    /// A saved colour's palette. Strength 0 returns Subtle with presence 0:
    /// the chrome reads that as "draw today's tokens".
    static func palette(for colour: SpaceColour, dark: Bool) -> SpaceTonePalette {
        var p = tuned(colour.hue, strength: max(colour.strength, 1), dark: dark)
        p.presence = colour.strength > 0 ? 1 : 0
        return p
    }

    /// The picker's continuous palette: see the API notes at the top.
    static func palette(hue: Double, strength: Double, dark: Bool) -> SpaceTonePalette {
        let maxHue = Double(SpaceHue.allCases.count - 1)
        let h = hue.isFinite ? min(max(hue, 0), maxHue) : 0
        let s = strength.isFinite ? min(max(strength, 0), 3) : 0
        let presence = min(s, 1)
        let sEff = max(s, 1)
        let h0 = Int(h.rounded(.down)), h1 = min(h0 + 1, Int(maxHue))
        let s0 = Int(sEff.rounded(.down)), s1 = min(s0 + 1, 3)
        let th = h - Double(h0), ts = sEff - Double(s0)
        let hue0 = SpaceHue(rawValue: h0)!, hue1 = SpaceHue(rawValue: h1)!

        var p: SpaceTonePalette
        if th < 1e-6, ts < 1e-6 {
            p = tuned(hue0, strength: s0, dark: dark)
        } else {
            let lo = SpaceTonePalette.mix(
                tuned(hue0, strength: s0, dark: dark), tuned(hue1, strength: s0, dark: dark), th
            )
            let hi = SpaceTonePalette.mix(
                tuned(hue0, strength: s1, dark: dark), tuned(hue1, strength: s1, dark: dark), th
            )
            p = clamp(SpaceTonePalette.mix(lo, hi, ts), glasses: allGlasses(dark: dark))
        }
        p.presence = presence
        return p
    }

    // MARK: Checks

    struct Check: Sendable {
        let label: String
        let fg: ToneRGB
        let bg: ToneRGB
        let minimum: Double
        var ratio: Double { OKLab.contrast(fg, bg) }
    }

    /// Every pair as it sits on screen: tonal.js's list, plus the app's own
    /// hover washes and states.
    static func checks(_ p: SpaceTonePalette, dark: Bool) -> [Check] {
        let s = p.surface, hov = p.hoverGround, name = p.nameHoverGround, glass = p.glassGround, chip = p.chip
        let tonalHov = OKLab.over(p.hover, 0.05, s), tonalName = OKLab.over(p.hover, 0.06, s)
        let button = OKLab.over(p.hover, buttonHoverAlpha, s)
        let buttonOnRow = OKLab.over(p.hover, buttonHoverAlpha, hov)
        var out: [Check] = [
            Check(label: "row title on surface", fg: p.t62, bg: s, minimum: 4.5),
            Check(label: "row title on hover", fg: p.t62, bg: tonalHov, minimum: 4.5),
            Check(label: "row title on app hover (.07)", fg: p.t62, bg: hov, minimum: 4.5),
            Check(label: "folder title on surface", fg: p.t82, bg: s, minimum: 4.5),
            Check(label: "folder title on hover", fg: p.t82, bg: hov, minimum: 4.5),
            Check(label: "space name on surface", fg: p.t90, bg: s, minimum: 4.5),
            Check(label: "space name on hover", fg: p.t90, bg: tonalName, minimum: 4.5),
            Check(label: "space name on app hover (.08)", fg: p.t90, bg: name, minimum: 4.5),
            Check(label: "selected row text on chip", fg: p.t95, bg: chip, minimum: 4.5),
            Check(label: "sleeping selected row text on chip", fg: p.t62, bg: chip, minimum: 4.5),
            Check(label: "chevron / sidebar icon (tx-40)", fg: p.t40, bg: s, minimum: 3),
            Check(label: "folder chevron on hover", fg: p.t40, bg: hov, minimum: 3),
            Check(label: "row + folder glyph on surface", fg: p.glyph, bg: s, minimum: 3),
            Check(label: "row glyph on hover", fg: p.glyph, bg: hov, minimum: 3),
            Check(label: "selected row glyph on chip", fg: p.glyph, bg: chip, minimum: 3),
            Check(label: "capsule / pill icon on glass", fg: p.t62, bg: glass, minimum: 3),
            Check(label: "plus icon on glass", fg: p.t82, bg: glass, minimum: 3),
            Check(label: "capsule thumb icon (tx-95)", fg: p.t95, bg: chip, minimum: 3),
            Check(label: "pill thumb icon (tx-90)", fg: p.t90, bg: chip, minimum: 3),
            Check(label: "sidebar toggle on hover", fg: p.t82, bg: button, minimum: 4.5),
            Check(label: "row hover button on hover", fg: p.t90, bg: buttonOnRow, minimum: 4.5),
        ]
        for hue in SpaceHue.allCases {
            for strength in [1, 3] {
                out.append(Check(
                    label: "pill icon (other space)",
                    fg: tuned(hue, strength: strength, dark: dark).cell,
                    bg: glass,
                    minimum: 3
                ))
            }
        }
        return out
    }
}

// MARK: - The terminal card's tint (port of x/terminal.js)

nonisolated extension SpaceTone {
    /// terminal.js `R[app].tint`, indexed by strength 0...3: none, Subtle
    /// (no tint, the sidebar alone carries it), Medium, Strong. Dark is a
    /// touch richer at Medium because a few percent of near-black barely
    /// registers.
    static let terminalTintAlpha: (light: [Double], dark: [Double]) = (
        light: [0, 0, 0.015, 0.03],
        dark: [0, 0, 0.018, 0.03]
    )

    /// terminal.js `tintSrc`: the colour the tint is mixed from. A mid tone
    /// (OKLCH L .62) at the hue's peak chroma, so 3% reads as a clean tint
    /// rather than grey; dark asks for 1.1× the chroma (gamut-mapped, so
    /// most hues come out the same).
    static func terminalTintSource(_ hue: SpaceHue, dark: Bool) -> ToneRGB {
        let shape = hueAngles[hue]!
        return OKLab.oklch(0.62, shape.c * (dark ? 1.1 : 1), shape.h)
    }

    /// One tuned strength's tint: the source colour at that strength's alpha.
    static func terminalTint(_ hue: SpaceHue, strength: Int, dark: Bool) -> ToneRGB {
        let alphas = dark ? terminalTintAlpha.dark : terminalTintAlpha.light
        return terminalTintSource(hue, dark: dark).with(alpha: alphas[min(max(strength, 0), 3)])
    }

    /// What the card overlay draws for a (possibly mid-crossfade) palette:
    /// the tint with presence applied, times the dev tuning `scale`. Alpha 0
    /// means draw nothing.
    static func terminalTint(in palette: SpaceTonePalette, scale: Double = 1) -> ToneRGB {
        let tint = palette.terminalTint
        let alpha = tint.a * palette.presence * scale
        return tint.with(alpha: alpha.isFinite ? min(1, max(0, alpha)) : 0)
    }

    /// The opaque card background a terminal theme's `background` becomes
    /// under the tint (straight sRGB source-over, as Core Animation
    /// composites it and as terminal.js's `CT.mix` models it).
    static func tintedTerminalBackground(_ background: ToneRGB, palette: SpaceTonePalette, scale: Double = 1) -> ToneRGB {
        OKLab.over(terminalTint(in: palette, scale: scale), nil, background.opaque)
    }
}

// MARK: - The picker's pad

nonisolated extension SpaceTone {
    /// What the sidebar looks like with no colour: the frost (material +
    /// window wash), as the mockups model it. The pad's bottom row.
    static let untintedFrost = (light: ToneRGB(228, 230, 233), dark: ToneRGB(44, 45, 47))

    /// OKLab vectors, so a pad sample is a few lerps and one conversion.
    private struct PickerTable: Sendable {
        var frost: SIMD3<Double>
        /// [hue][strength - 1]: the tonal surface over the frost.
        var field: [[SIMD3<Double>]]
        /// [hue]: the swatch (macOS accent).
        var vivid: [SIMD3<Double>]
    }

    private static func labVector(_ c: ToneRGB) -> SIMD3<Double> {
        let v = OKLab.lab(c)
        return SIMD3(v.L, v.a, v.b)
    }

    private static let pickerTables: [PickerTable] = [false, true].map { dark in
        let frost = dark ? untintedFrost.dark : untintedFrost.light
        return PickerTable(
            frost: labVector(frost),
            field: SpaceHue.allCases.map { hue in
                (1...3).map { s in
                    labVector(OKLab.over(tuned(hue, strength: s, dark: dark).surface, groundOpacity, frost))
                }
            },
            vivid: SpaceHue.allCases.map { hue in
                labVector(ToneRGB(hex: dark ? swatches[hue]!.dark : swatches[hue]!.light))
            }
        )
    }

    private static func pickerHue(_ hue: Double) -> (Int, Int, Double) {
        let maxHue = Double(SpaceHue.allCases.count - 1)
        let h = hue.isFinite ? min(max(hue, 0), maxHue) : 0
        let h0 = Int(h.rounded(.down))
        return (h0, min(h0 + 1, Int(maxHue)), h - Double(h0))
    }

    /// The pad's colour at a continuous hue (0...8) and strength (0...3):
    /// the tonal surface the sidebar would get, over the frost, nudged a
    /// touch toward the vivid swatch so the pad reads as colour (more at
    /// Strong), and fading to the plain frost below Subtle.
    static func pickerField(hue: Double, strength: Double, dark: Bool) -> ToneRGB {
        let t = pickerTables[dark ? 1 : 0]
        let (h0, h1, th) = pickerHue(hue)
        let s = strength.isFinite ? min(max(strength, 0), 3) : 0
        let sEff = max(s, 1)
        let s0 = Int(sEff.rounded(.down)), s1 = min(s0 + 1, 3), ts = sEff - Double(s0)
        func at(_ h: Int, _ s: Int) -> SIMD3<Double> { t.field[h][s - 1] }
        let lo = at(h0, s0) + (at(h1, s0) - at(h0, s0)) * th
        let hi = at(h0, s1) + (at(h1, s1) - at(h0, s1)) * th
        var c = lo + (hi - lo) * ts
        let vivid = t.vivid[h0] + (t.vivid[h1] - t.vivid[h0]) * th
        c += (vivid - c) * ((dark ? 0.16 : 0.13) * s / 3)
        if s < 1 { c = t.frost + (c - t.frost) * s }
        return OKLab.toRGB(c.x, c.y, c.z)
    }

    /// The vivid swatch for a continuous hue (the picker drop's glass tint
    /// and caustic).
    static func pickerAccent(hue: Double, dark: Bool) -> ToneRGB {
        let t = pickerTables[dark ? 1 : 0]
        let (h0, h1, th) = pickerHue(hue)
        let c = t.vivid[h0] + (t.vivid[h1] - t.vivid[h0]) * th
        return OKLab.toRGB(c.x, c.y, c.z)
    }
}
