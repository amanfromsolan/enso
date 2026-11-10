import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
@testable import Enso

/// The space-colour theme engine (SpaceTone.swift): the XCTest port of the
/// colour-into-theme audit (`bun _src/audit.ts tonal`), a cross-check against
/// tonal.js, the picker's continuous palette, and persistence.
struct SpaceToneTests {
    private static let strengths = [1, 2, 3]

    // MARK: Audit

    /// Every pair the chrome draws passes for 9 hues × 3 strengths × light
    /// and dark: text ≥ 4.5:1, icons and glyphs ≥ 3:1.
    @Test func everyTunedPalettePassesEveryCheck() {
        var failures: [String] = []
        var worstText = (ratio: Double.infinity, at: "")
        var worstIcon = (ratio: Double.infinity, at: "")
        var perLabel: [String: (ratio: Double, at: String)] = [:]
        for hue in SpaceHue.allCases {
            for strength in Self.strengths {
                for dark in [false, true] {
                    let palette = SpaceTone.tuned(hue, strength: strength, dark: dark)
                    for check in SpaceTone.checks(palette, dark: dark) {
                        let ratio = check.ratio
                        let at = "\(check.label) — \(hue.name) \(strength) \(dark ? "dark" : "light")"
                        if ratio < (perLabel[check.label]?.ratio ?? .infinity) {
                            perLabel[check.label] = (ratio, "\(hue.name) \(strength) \(dark ? "dark" : "light")")
                        }
                        if ratio < check.minimum - 1e-6 {
                            failures.append("\(at): \(String(format: "%.2f", ratio)) < \(check.minimum)")
                        }
                        if check.minimum >= 4.5 {
                            if ratio < worstText.ratio { worstText = (ratio, at) }
                        } else if ratio < worstIcon.ratio {
                            worstIcon = (ratio, at)
                        }
                    }
                }
            }
        }
        print("SpaceTone audit: worst text \(String(format: "%.2f", worstText.ratio)) (\(worstText.at)), "
            + "worst icon \(String(format: "%.2f", worstIcon.ratio)) (\(worstIcon.at))")
        for (label, worst) in perLabel.sorted(by: { $0.key < $1.key }) {
            print("SpaceTone audit:   \(label): \(String(format: "%.2f", worst.ratio)) at \(worst.at)")
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(worstText.ratio >= 4.5)
        #expect(worstIcon.ratio >= 3)
    }

    /// The picker's drag lands between swatches and strengths: blended
    /// palettes are clamped, so they pass too.
    @Test func continuousPalettesPassAtFractionalHuesAndStrengths() {
        var failures: [String] = []
        for hueStep in 0...32 {
            let hue = Double(hueStep) * 0.25
            for strength in stride(from: 1.0, through: 3.0, by: 0.25) {
                for dark in [false, true] {
                    let palette = SpaceTone.palette(hue: hue, strength: strength, dark: dark)
                    #expect(palette.presence == 1)
                    for check in SpaceTone.checks(palette, dark: dark) where check.ratio < check.minimum - 1e-6 {
                        failures.append("\(check.label) at hue \(hue) strength \(strength) dark \(dark): \(check.ratio)")
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(20).joined(separator: "\n"))")
    }

    @Test func continuousPaletteMatchesTunedAtWholeValues() {
        for hue in SpaceHue.allCases {
            for strength in Self.strengths {
                for dark in [false, true] {
                    let tuned = SpaceTone.tuned(hue, strength: strength, dark: dark)
                    let continuous = SpaceTone.palette(hue: Double(hue.rawValue), strength: Double(strength), dark: dark)
                    #expect(continuous == tuned)
                }
            }
        }
    }

    /// Below Subtle the palette fades in over today's look rather than
    /// changing colour; out-of-range input is clamped, never trapped.
    @Test func strengthBelowOneIsPresence() {
        #expect(SpaceTone.palette(hue: 3, strength: 0, dark: false).presence == 0)
        #expect(SpaceTone.palette(hue: 3, strength: 0.4, dark: true).presence == 0.4)
        #expect(SpaceTone.palette(hue: 3, strength: 7, dark: true) == SpaceTone.tuned(.red, strength: 3, dark: true))
        #expect(SpaceTone.palette(hue: -2, strength: 2, dark: false) == SpaceTone.tuned(.blue, strength: 2, dark: false))
        #expect(SpaceTone.palette(hue: 12, strength: 2, dark: false) == SpaceTone.tuned(.graphite, strength: 2, dark: false))
        #expect(SpaceTone.palette(hue: .nan, strength: .nan, dark: false).presence == 0)
        #expect(SpaceTone.palette(for: .none, dark: false).presence == 0)
        #expect(SpaceChromeTone(colour: .none).isNeutral)
        #expect(!SpaceChromeTone(colour: SpaceColour(hue: .teal, strength: 1)).isNeutral)
    }

    /// Fading from "no colour" only fades presence in; the tokens are the
    /// target's from the first frame (no detour through another hue).
    @Test func crossfadeFromNoneKeepsTargetTokens() {
        let none = SpaceTone.palette(for: .none, dark: true)
        let green = SpaceTone.palette(for: SpaceColour(hue: .green, strength: 3), dark: true)
        let mid = SpaceTonePalette.mix(none, green, 0.3)
        #expect(mid.surface == green.surface)
        #expect(abs(mid.presence - 0.3) < 1e-9)
        let back = SpaceTonePalette.mix(green, none, 0.3)
        #expect(back.t62 == green.t62)
        #expect(abs(back.presence - 0.7) < 1e-9)
        #expect(SpaceTonePalette.mix(green, none, 1) == none)
    }

    // MARK: Terminal tint (x/terminal.js)

    /// terminal.js `tintSrc` for every hue, dumped with bun (`CT.tone(hue,
    /// .62, 1)` light, `CT.tone(hue, .62, 1.1)` dark).
    private static let terminalTintSources: [SpaceHue: (light: ToneRGB, dark: ToneRGB)] = [
        .blue: (ToneRGB(30, 129, 255), ToneRGB(30, 129, 255)),
        .purple: (ToneRGB(177, 84, 224), ToneRGB(181, 75, 232)),
        .pink: (ToneRGB(244, 27, 76), ToneRGB(248, 0, 73)),
        .red: (ToneRGB(242, 43, 35), ToneRGB(251, 0, 10)),
        .orange: (ToneRGB(193, 111, 0), ToneRGB(193, 111, 0)),
        .yellow: (ToneRGB(163, 130, 0), ToneRGB(163, 130, 0)),
        .green: (ToneRGB(0, 162, 61), ToneRGB(0, 162, 61)),
        .teal: (ToneRGB(0, 151, 173), ToneRGB(0, 151, 173)),
        .graphite: (ToneRGB(129, 135, 143), ToneRGB(128, 135, 144)),
    ]

    /// terminal.js `BASE`: the typical themes the mockup checks against.
    private static let terminalThemes: [(name: String, dark: Bool, bg: ToneRGB, fg: ToneRGB)] = [
        ("light", false, ToneRGB(251, 251, 250), ToneRGB(29, 29, 31)),
        ("dark", true, ToneRGB(11, 11, 13), ToneRGB(230, 230, 230)),
        // Enso's fallback background (GhosttyRuntime) with a typical fg.
        ("Enso default", true, ToneRGB(4.59, 4.845, 5.865), ToneRGB(230, 230, 230)),
    ]

    @Test func terminalTintMatchesTerminalJS() {
        for hue in SpaceHue.allCases {
            let ref = Self.terminalTintSources[hue]!
            for dark in [false, true] {
                let expected = dark ? ref.dark : ref.light
                let got = SpaceTone.terminalTintSource(hue, dark: dark)
                #expect(got == expected, "\(hue.name) \(dark ? "dark" : "light"): \(got) vs \(expected)")
                // The tuned palettes carry it, at terminal.js's alphas.
                for strength in Self.strengths {
                    let tint = SpaceTone.tuned(hue, strength: strength, dark: dark).terminalTint
                    #expect(tint.opaque == expected)
                }
            }
        }
    }

    /// Subtle: none. Medium: 1.5% light, 1.8% dark. Strong: 3%. No colour:
    /// clear (the layer hides), whatever the hue.
    @Test func terminalTintPerStrengthAndAppearance() {
        let expected: [(strength: Int, light: Double, dark: Double)] = [
            (0, 0, 0), (1, 0, 0), (2, 0.015, 0.018), (3, 0.03, 0.03),
        ]
        for hue in SpaceHue.allCases {
            for row in expected {
                for dark in [false, true] {
                    let palette = SpaceTone.palette(for: SpaceColour(hue: hue, strength: row.strength), dark: dark)
                    let tint = SpaceTone.terminalTint(in: palette)
                    #expect(abs(tint.a - (dark ? row.dark : row.light)) < 1e-12, "\(hue.name) \(row.strength) \(dark)")
                }
            }
        }
        let none = SpaceChromeTone(colour: .none)
        #expect(SpaceTone.terminalTint(in: none.light).a == 0)
        #expect(SpaceTone.terminalTint(in: none.dark).a == 0)
        // The dev multiplier scales it, and can't push past opaque or below 0.
        let strong = SpaceTone.palette(for: SpaceColour(hue: .teal, strength: 3), dark: false)
        #expect(abs(SpaceTone.terminalTint(in: strong, scale: 2).a - 0.06) < 1e-12)
        #expect(SpaceTone.terminalTint(in: strong, scale: -1).a == 0)
        #expect(SpaceTone.terminalTint(in: SpaceTone.palette(for: .none, dark: true), scale: 4).a == 0)
        // terminal.js's card: Strong blue over the light base.
        let card = SpaceTone.tintedTerminalBackground(ToneRGB(251, 251, 250), palette: SpaceTone.palette(
            for: SpaceColour(hue: .blue, strength: 3), dark: false
        ))
        #expect(abs(card.r - 244.37) < 0.01 && abs(card.g - 247.34) < 0.01 && abs(card.b - 250.15) < 0.01)
    }

    /// The tint crossfades with the chrome: in from no colour by presence
    /// alone (the hue is the target's from the first frame), and through the
    /// picker's in-between strengths.
    @Test func terminalTintCrossfadesAndFollowsThePicker() {
        let none = SpaceTone.palette(for: .none, dark: true)
        let green = SpaceTone.palette(for: SpaceColour(hue: .green, strength: 3), dark: true)
        let mid = SpaceTonePalette.mix(none, green, 0.5)
        let tint = SpaceTone.terminalTint(in: mid)
        #expect(tint.opaque == green.terminalTint.opaque)
        #expect(abs(tint.a - 0.015) < 1e-9)
        #expect(SpaceTone.terminalTint(in: SpaceTonePalette.mix(green, none, 1)).a == 0)

        let between = SpaceTone.palette(hue: 6, strength: 2.5, dark: false)
        #expect(abs(SpaceTone.terminalTint(in: between).a - 0.0225) < 1e-9)
        let fading = SpaceTone.palette(hue: 6, strength: 0.5, dark: false)
        #expect(SpaceTone.terminalTint(in: fading).a == 0)
        #expect(SpaceTone.terminalTint(in: SpaceTone.palette(hue: 6, strength: 0, dark: true)).a == 0)
    }

    /// The README's terminal contrast check: plain text on the tinted card
    /// stays ≥ 4.5:1 for every hue and strength on typical light and dark
    /// themes, including at the picker's in-between hues and the top of the
    /// dev multiplier's range.
    @Test func plainTextHoldsContrastOnTheTintedCard() {
        var worst = (ratio: Double.infinity, at: "")
        for theme in Self.terminalThemes {
            let plain = OKLab.contrast(theme.fg, theme.bg)
            for hueStep in 0...16 {
                let hue = Double(hueStep) * 0.5
                for strength in [0.0, 1, 1.5, 2, 2.5, 3] {
                    let palette = SpaceTone.palette(hue: hue, strength: strength, dark: theme.dark)
                    for scale in [1.0, 4] {
                        let bg = SpaceTone.tintedTerminalBackground(theme.bg, palette: palette, scale: scale)
                        let ratio = OKLab.contrast(theme.fg, bg)
                        let at = "\(theme.name) hue \(hue) strength \(strength) ×\(scale)"
                        if scale == 1, ratio < worst.ratio { worst = (ratio, at) }
                        #expect(ratio >= 4.5, "\(at): \(ratio)")
                        // A tint never costs more than a sliver of the theme's own contrast.
                        if scale == 1 { #expect(ratio > plain * 0.95, "\(at): \(ratio) vs \(plain)") }
                    }
                }
            }
        }
        print("Terminal tint: worst plain-text contrast \(String(format: "%.2f", worst.ratio)) (\(worst.at))")
        #expect(worst.ratio >= 4.5)
    }

    // MARK: Against tonal.js

    private struct Ref {
        let hue: SpaceHue
        let strength: Int
        let dark: Bool
        let tokens: [String: ToneRGB]

        init(_ hue: SpaceHue, _ strength: Int, dark: Bool, _ tokens: [String: ToneRGB]) {
            self.hue = hue
            self.strength = strength
            self.dark = dark
            self.tokens = tokens
        }
    }

    /// Dumped from tonal.js with bun (TONAL.build + TONAL.cell).
    private static let references: [Ref] = [
        Ref(.blue, 2, dark: false, ["surface": ToneRGB(222, 233, 249), "gutter": ToneRGB(213, 226, 244), "chip": ToneRGB(249, 251, 255), "hover": ToneRGB(32, 51, 79), "glass": ToneRGB(243, 248, 255), "accent": ToneRGB(69, 114, 178), "t95": ToneRGB(17, 25, 36), "t90": ToneRGB(25, 34, 47), "t82": ToneRGB(37, 49, 66), "t62": ToneRGB(65, 81, 103), "t40": ToneRGB(93, 109, 132), "glyph": ToneRGB(65, 100, 151), "cell": ToneRGB(65, 100, 151)]),
        Ref(.yellow, 3, dark: false, ["surface": ToneRGB(240, 232, 205), "gutter": ToneRGB(234, 224, 195), "chip": ToneRGB(254, 251, 242), "hover": ToneRGB(70, 45, 0), "glass": ToneRGB(252, 248, 236), "accent": ToneRGB(152, 102, 0), "t95": ToneRGB(33, 22, 5), "t90": ToneRGB(45, 31, 9), "t82": ToneRGB(63, 45, 16), "t62": ToneRGB(99, 75, 40), "t40": ToneRGB(128, 103, 67), "glyph": ToneRGB(133, 89, 0), "cell": ToneRGB(133, 89, 0)]),
        Ref(.yellow, 3, dark: true, ["surface": ToneRGB(46, 36, 19), "gutter": ToneRGB(38, 29, 14), "chip": ToneRGB(72, 60, 39), "hover": ToneRGB(243, 238, 223), "glass": ToneRGB(206, 195, 176), "accent": ToneRGB(187, 163, 89), "t95": ToneRGB(245, 243, 237), "t90": ToneRGB(236, 233, 224), "t82": ToneRGB(223, 219, 207), "t62": ToneRGB(190, 185, 168), "t40": ToneRGB(154, 149, 133), "glyph": ToneRGB(203, 186, 135), "cell": ToneRGB(203, 186, 135)]),
        Ref(.graphite, 1, dark: true, ["surface": ToneRGB(36, 38, 41), "gutter": ToneRGB(29, 31, 33), "chip": ToneRGB(59, 62, 65), "hover": ToneRGB(237, 239, 241), "glass": ToneRGB(194, 196, 199), "accent": ToneRGB(157, 166, 175), "t95": ToneRGB(243, 243, 244), "t90": ToneRGB(232, 234, 235), "t82": ToneRGB(217, 219, 220), "t62": ToneRGB(183, 185, 187), "t40": ToneRGB(147, 149, 152), "glyph": ToneRGB(181, 187, 194), "cell": ToneRGB(181, 187, 194)]),
        Ref(.green, 3, dark: false, ["surface": ToneRGB(217, 238, 221), "gutter": ToneRGB(209, 232, 212), "chip": ToneRGB(246, 253, 247), "hover": ToneRGB(17, 61, 30), "glass": ToneRGB(241, 251, 243), "accent": ToneRGB(21, 136, 65), "t95": ToneRGB(13, 28, 16), "t90": ToneRGB(20, 39, 24), "t82": ToneRGB(31, 55, 36), "t62": ToneRGB(58, 88, 64), "t40": ToneRGB(85, 117, 91), "glyph": ToneRGB(36, 117, 61), "cell": ToneRGB(36, 117, 61)]),
        Ref(.orange, 2, dark: true, ["surface": ToneRGB(48, 35, 25), "gutter": ToneRGB(40, 28, 19), "chip": ToneRGB(74, 58, 46), "hover": ToneRGB(247, 236, 226), "glass": ToneRGB(209, 193, 181), "accent": ToneRGB(201, 154, 108), "t95": ToneRGB(247, 243, 238), "t90": ToneRGB(239, 232, 226), "t82": ToneRGB(226, 217, 209), "t62": ToneRGB(195, 183, 171), "t40": ToneRGB(158, 147, 136), "glyph": ToneRGB(213, 180, 147), "cell": ToneRGB(213, 180, 147)]),
        Ref(.teal, 3, dark: true, ["surface": ToneRGB(0, 44, 50), "gutter": ToneRGB(0, 36, 41), "chip": ToneRGB(12, 70, 77), "hover": ToneRGB(214, 245, 249), "glass": ToneRGB(164, 205, 211), "accent": ToneRGB(0, 186, 201), "t95": ToneRGB(234, 246, 248), "t90": ToneRGB(219, 238, 240), "t82": ToneRGB(200, 224, 227), "t62": ToneRGB(157, 193, 197), "t40": ToneRGB(122, 157, 160), "glyph": ToneRGB(83, 207, 220), "cell": ToneRGB(83, 207, 220)]),
        Ref(.purple, 1, dark: false, ["surface": ToneRGB(235, 230, 238), "gutter": ToneRGB(228, 222, 231), "chip": ToneRGB(252, 250, 253), "hover": ToneRGB(56, 47, 61), "glass": ToneRGB(249, 247, 251), "accent": ToneRGB(125, 104, 137), "t95": ToneRGB(26, 23, 28), "t90": ToneRGB(36, 32, 39), "t82": ToneRGB(51, 46, 55), "t62": ToneRGB(84, 77, 88), "t40": ToneRGB(112, 104, 117), "glyph": ToneRGB(108, 92, 118), "cell": ToneRGB(108, 92, 118)]),
    ]

    private static func token(_ name: String, _ p: SpaceTonePalette) -> ToneRGB {
        switch name {
        case "surface": p.surface
        case "gutter": p.gutter
        case "chip": p.chip
        case "hover": p.hover
        case "glass": p.glass
        case "accent": p.accent
        case "t95": p.t95
        case "t90": p.t90
        case "t82": p.t82
        case "t62": p.t62
        case "t40": p.t40
        case "glyph": p.glyph
        case "cell": p.cell
        default: ToneRGB(0, 0, 0)
        }
    }

    /// The Swift ramp reproduces tonal.js (before and after the app's own
    /// extra clamp). OKLab distance ×100 ≈ ΔE; 1 is a just-noticeable step.
    @Test func swiftRampMatchesTonalJS() {
        var worst = (delta: 0.0, at: "")
        for ref in Self.references {
            let raw = SpaceTone.unclampedPalette(ref.hue, strength: ref.strength, dark: ref.dark)
            let final = SpaceTone.tuned(ref.hue, strength: ref.strength, dark: ref.dark)
            for (name, expected) in ref.tokens {
                if name != "cell" {
                    let rawDelta = OKLab.distance(Self.token(name, raw), expected) * 100
                    #expect(rawDelta < 0.5, "\(ref.hue) \(ref.strength) \(ref.dark) \(name) raw ΔE \(rawDelta)")
                }
                let delta = OKLab.distance(Self.token(name, final), expected) * 100
                if delta > worst.delta { worst = (delta, "\(ref.hue) \(ref.strength) \(ref.dark ? "dark" : "light") \(name)") }
                #expect(delta < 2, "\(ref.hue) \(ref.strength) \(ref.dark) \(name) ΔE \(delta)")
            }
        }
        print("SpaceTone vs tonal.js: worst ΔE \(String(format: "%.2f", worst.delta)) (\(worst.at))")
    }

    @Test func hueAnglesMatchColourJS() {
        let expected: [SpaceHue: (Double, Double)] = [
            .blue: (257.4239, 0.21771), .purple: (312.4106, 0.21292), .pink: (17.8982, 0.23834),
            .red: (28.6592, 0.23214), .orange: (62.5738, 0.17521), .yellow: (90.3816, 0.17683),
            .green: (147.4439, 0.19438), .teal: (212.7198, 0.11091), .graphite: (255, 0.014),
        ]
        for (hue, (h, c)) in expected {
            let got = SpaceTone.hueAngles[hue]!
            #expect(abs(got.h - h) < 0.001)
            #expect(abs(got.c - c) < 0.0001)
        }
    }

    // MARK: Hardest hues

    /// The orange attention dot is never recoloured; on an orange space it
    /// must stay at least as distinct from everything behind it as it is on
    /// today's frost (measured in OKLab, since in light mode it's chroma, not
    /// contrast, that sets it apart).
    @Test func orangeDotStaysDistinctOnOrangeSpaces() {
        let dot = (light: ToneRGB(hex: 0xFF9500), dark: ToneRGB(hex: 0xFF9F0A))
        let frost = (light: ToneRGB(228, 230, 233), dark: ToneRGB(44, 45, 47))
        for dark in [false, true] {
            let d = dark ? dot.dark : dot.light
            let today = OKLab.distance(d, dark ? frost.dark : frost.light)
            for strength in Self.strengths {
                let p = SpaceTone.tuned(.orange, strength: strength, dark: dark)
                for ground in [p.surface, p.hoverGround, p.chip, p.glassGround] {
                    #expect(OKLab.distance(d, ground) >= today * 0.75, "orange \(strength) dark \(dark)")
                }
            }
        }
    }

    /// Yellow ink goes ochre in light (rotated toward amber, darkened), and
    /// graphite is a deliberate cool slate rather than grey.
    @Test func yellowAndGraphiteSpecialCases() {
        let yellowGlyph = OKLab.lch(SpaceTone.tuned(.yellow, strength: 2, dark: false).glyph)
        #expect(yellowGlyph.h < 85 && yellowGlyph.h > 60)
        #expect(yellowGlyph.L < 0.6)
        let slate = OKLab.lch(SpaceTone.tuned(.graphite, strength: 3, dark: true).surface)
        #expect(slate.h > 230 && slate.h < 275)
        #expect(slate.C > 0.005)
    }

    // MARK: The control: no colour draws today's pixels

    private static func resolved(_ style: some ShapeStyle, dark: Bool, tone: SpaceChromeTone = .neutral) -> Color.Resolved {
        var env = EnvironmentValues()
        env.colorScheme = dark ? .dark : .light
        env.spaceTone = tone
        // Resolve the style the way a view does, then the colour it gives.
        let color: Color
        if let tonal = style as? ToneStyle {
            color = tonal.resolve(in: env)
        } else if let cell = style as? SpaceCellStyle {
            color = cell.resolve(in: env)
        } else {
            color = style as! Color
        }
        return color.resolve(in: env)
    }

    private static func same(_ a: Color.Resolved, _ b: Color.Resolved) -> Bool {
        abs(a.red - b.red) < 1e-6 && abs(a.green - b.green) < 1e-6
            && abs(a.blue - b.blue) < 1e-6 && abs(a.opacity - b.opacity) < 1e-6
    }

    /// With no colour every tone style resolves to exactly the colour the
    /// view drew before tones existed, in both appearances.
    @MainActor
    @Test func noColourResolvesToTodaysColours() {
        let opacities = [0, 0.035, 0.04, 0.05, 0.06, 0.07, 0.08, 0.09, 0.1, 0.14, 0.28, 0.38, 0.4, 0.45,
                         0.5, 0.55, 0.6, 0.62, 0.65, 0.7, 0.75, 0.8, 0.82, 0.85, 0.9, 0.92, 0.95, 1]
        for dark in [false, true] {
            var pairs: [(String, ToneStyle, Color)] = []
            for op in opacities {
                pairs.append(("text \(op)", Tone.text(op), Theme.text(op)))
                pairs.append(("ink \(op)", Tone.ink(op), Theme.ink.opacity(op)))
                pairs.append(("glyph \(op)", Tone.glyph(op), Theme.ink.opacity(op)))
                pairs.append(("inkMark \(op)", Tone.inkMark(op), Theme.ink.opacity(op)))
            }
            pairs += [
                ("chip", Tone.chip, Color.white.opacity(dark ? 0.13 : 0.82)),
                ("shadow near", Tone.chipShadowNear, Color.black.opacity(dark ? 0.2 : 0.06)),
                ("shadow far", Tone.chipShadowFar, Color.black.opacity(dark ? 0.22 : 0.13)),
                ("glass tint", Tone.glassTint, Color.black.opacity(dark ? 0.1 : 0.05)),
                ("glass rim", Tone.glassRim, Theme.ink.opacity(0.1)),
                ("accent", Tone.accent(), Color.accentColor),
                ("accent .22", Tone.accent(0.22), Color.accentColor.opacity(0.22)),
                ("surface", Tone.surface, Color.clear),
                ("gutter", Tone.gutter, Color.clear),
                ("glass fill", Tone.glassFill, Color.clear),
                ("thumb tint", Tone.thumbTint, Color.clear),
            ]
            for (label, style, today) in pairs {
                let got = Self.resolved(style, dark: dark)
                let want = Self.resolved(today, dark: dark)
                #expect(Self.same(got, want), "\(label) dark \(dark): \(got) vs \(want)")
            }
        }
        #expect(SpaceChromeTone.neutral.isNeutral)
        // The comparison has teeth: appearance changes the resolved colour,
        // and a colour changes the style's.
        #expect(!Self.same(Self.resolved(Theme.text(0.62), dark: true), Self.resolved(Theme.text(0.62), dark: false)))
        #expect(!Self.same(
            Self.resolved(Tone.text(0.62), dark: true, tone: SpaceChromeTone(colour: SpaceColour(hue: .red, strength: 1))),
            Self.resolved(Theme.text(0.62), dark: true)
        ))
    }

    /// Coloured, a style resolves to its palette token.
    @MainActor
    @Test func colourResolvesToThePalette() {
        let teal = SpaceColour(hue: .teal, strength: 3)
        let tone = SpaceChromeTone(colour: teal)
        for dark in [false, true] {
            let p = SpaceTone.palette(for: teal, dark: dark)
            let cases: [(ToneStyle, ToneRGB)] = [
                (Tone.text(0.62), p.t62), (Tone.text(0.95), p.t95), (Tone.text(0.4), p.t40),
                (Tone.glyph(0.4), p.glyph), (Tone.chip, p.chip),
                (Tone.surface, p.surface.with(alpha: SpaceTone.groundOpacity)),
                (Tone.ink(0.06), p.hover.with(alpha: 0.06)),
            ]
            for (style, rgb) in cases {
                let got = Self.resolved(style, dark: dark, tone: tone)
                let want = Self.resolved(rgb.color, dark: dark)
                #expect(Self.same(got, want))
            }
        }
    }

    // MARK: Persistence

    @Test func spacesSavedBeforeColoursDecodeAsNone() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Old","icon":{"dot":{}},"ephemeralSessions":[],"pinnedItems":[]}
        """
        let space = try JSONDecoder().decode(SidebarSpace.self, from: Data(json.utf8))
        #expect(space.colour == .none)
        #expect(space.colour.isNone)
    }

    @MainActor
    @Test func colourRoundTripsThroughTheStateFile() throws {
        var space = SidebarSpace(name: "Work")
        space.colour = SpaceColour(hue: .teal, strength: 3)
        let plain = SidebarSpace(name: "Plain")
        let data = try JSONEncoder().encode(
            TerminalSessionStore.PersistedState(version: 1, spaces: [space, plain])
        )
        let state = try #require(TerminalSessionStore.decodeState(from: data))
        #expect(state.spaces[0].colour == SpaceColour(hue: .teal, strength: 3))
        #expect(state.spaces[1].colour == .none)
    }

    @Test func unknownHueAndOutOfRangeStrengthDecodeSafely() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"Future","icon":{"dot":{}},"ephemeralSessions":[],"pinnedItems":[],
         "colour":{"hue":42,"strength":9}}
        """
        let space = try JSONDecoder().decode(SidebarSpace.self, from: Data(json.utf8))
        #expect(space.colour == SpaceColour(hue: .blue, strength: 3))
    }

    // MARK: Store wiring

    @MainActor
    @Test func storeDrivesTheToneFromTheActiveSpace() {
        let main = SidebarSpace(name: "Main", ephemeralSessions: [TerminalSession(title: "a", workingDirectory: "~")])
        let work = SidebarSpace(name: "Work", ephemeralSessions: [TerminalSession(title: "b", workingDirectory: "~")])
        let store = TerminalSessionStore(spaces: [main, work], persistToDisk: false)
        #expect(store.toneDriver.tone.isNeutral)

        let teal = SpaceColour(hue: .teal, strength: 2)
        store.setSpaceColour(main.id, to: teal)
        #expect(store.spaces[0].colour == teal)
        #expect(store.toneDriver.target == SpaceChromeTone(colour: teal))

        // The live drag: instant, unsaved.
        store.previewColour = SpaceColourPreview(spaceID: main.id, hue: 4.5, strength: 2.5)
        #expect(store.toneDriver.tone == SpaceChromeTone(hue: 4.5, strength: 2.5))
        #expect(store.spaces[0].colour == teal)

        // A preview for another space is ignored.
        store.previewColour = SpaceColourPreview(spaceID: work.id, hue: 1, strength: 3)
        #expect(store.toneDriver.target == SpaceChromeTone(colour: teal))

        store.previewColour = SpaceColourPreview(spaceID: main.id, hue: 6, strength: 3)
        store.commitSpaceColour(main.id, SpaceColour(hue: .green, strength: 3))
        #expect(store.previewColour == nil)
        #expect(store.spaces[0].colour == SpaceColour(hue: .green, strength: 3))
        #expect(store.toneDriver.target == SpaceChromeTone(colour: SpaceColour(hue: .green, strength: 3)))

        // Switching spaces aims the tone at the new space.
        store.activateSpace(work.id)
        #expect(store.toneDriver.target.isNeutral)
    }

    /// The picker's snap on release, while the colour is still only a
    /// preview: it springs (the drag frames before it were instant), saves
    /// nothing, and clearing it springs back to the saved colour.
    @MainActor
    @Test func settlingPreviewSpringsWithoutSaving() {
        let main = SidebarSpace(name: "Main", ephemeralSessions: [TerminalSession(title: "a", workingDirectory: "~")])
        let store = TerminalSessionStore(spaces: [main], persistToDisk: false)
        let saved = SpaceColour(hue: .teal, strength: 1)
        store.setSpaceColour(main.id, to: saved)
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // A drag frame: on screen at once.
        store.previewColour = SpaceColourPreview(spaceID: main.id, hue: 4.4, strength: 2.6)
        #expect(!store.toneDriver.isAnimating)
        #expect(store.toneDriver.tone == SpaceChromeTone(hue: 4.4, strength: 2.6))

        // The snap: aimed at the whole colour, springing there.
        let snapped = SpaceColour(hue: .orange, strength: 3)
        store.previewColour = .settling(main.id, on: snapped)
        #expect(store.previewColour?.animated == true)
        #expect(store.toneDriver.target == SpaceChromeTone(colour: snapped))
        if animates {
            #expect(store.toneDriver.isAnimating)
            #expect(store.toneDriver.tone == SpaceChromeTone(hue: 4.4, strength: 2.6))
        } else {
            #expect(store.toneDriver.tone == SpaceChromeTone(colour: snapped))
        }
        #expect(store.spaces[0].colour == saved)

        // Another drag frame cuts the spring and is instant again.
        store.previewColour = SpaceColourPreview(spaceID: main.id, hue: 2.2, strength: 1.5)
        #expect(!store.toneDriver.isAnimating)
        #expect(store.toneDriver.tone == SpaceChromeTone(hue: 2.2, strength: 1.5))

        // Cancel: back to the saved colour, springing.
        store.previewColour = nil
        #expect(store.toneDriver.target == SpaceChromeTone(colour: saved))
        #expect(store.toneDriver.isAnimating == animates)
        #expect(store.spaces[0].colour == saved)
    }

    /// The pad's field starts at the untinted frost and gets its colour from
    /// the tonal surface.
    @Test func pickerFieldFadesToTheFrostAtNone() {
        for dark in [false, true] {
            let frost = dark ? SpaceTone.untintedFrost.dark : SpaceTone.untintedFrost.light
            for hue in 0...8 {
                let none = SpaceTone.pickerField(hue: Double(hue), strength: 0, dark: dark)
                #expect(OKLab.distance(none, frost) < 0.01)
                let strong = SpaceTone.pickerField(hue: Double(hue), strength: 3, dark: dark)
                #expect(OKLab.distance(strong, frost) > OKLab.distance(SpaceTone.pickerField(hue: Double(hue), strength: 1, dark: dark), frost))
            }
        }
    }

    // MARK: The live drag's per-frame cost

    /// A pad drag frame must not publish the store: its objectWillChange
    /// re-runs every view observing it (the whole sidebar, the root, the
    /// workspace). Only the tone driver should hear about it.
    @MainActor
    @Test func dragPreviewDoesNotPublishTheStore() {
        let main = SidebarSpace(name: "Main", ephemeralSessions: [TerminalSession(title: "a", workingDirectory: "~")])
        let store = TerminalSessionStore(spaces: [main], persistToDisk: false)
        var storeChanges = 0
        var driverChanges = 0
        let a = store.objectWillChange.sink { storeChanges += 1 }
        let b = store.toneDriver.objectWillChange.sink { driverChanges += 1 }
        defer { a.cancel(); b.cancel() }

        for frame in 0..<60 {
            store.previewColour = SpaceColourPreview(
                spaceID: main.id, hue: Double(frame) / 60 * 8, strength: 1 + Double(frame) / 60 * 2
            )
        }
        store.previewColour = nil
        #expect(storeChanges == 0)
        #expect(driverChanges >= 60)
    }

    /// One drag frame builds one `SpaceChromeTone` (both appearances'
    /// continuous palettes); views then only look tokens up. Measures it, and
    /// a style resolve, so a regression shows up as a number.
    @Test func dragFrameToneCostIsSmall() {
        let frames = 400
        let clock = ContinuousClock()
        var sink = 0.0
        let build = clock.measure {
            for i in 0..<frames {
                let t = Double(i) / Double(frames)
                let tone = SpaceChromeTone(hue: t * 8, strength: 0.5 + t * 2.5)
                sink += tone.light.surface.r
            }
        }
        let tone = SpaceChromeTone(hue: 4.4, strength: 2.6)
        let styles: [ToneStyle] = [Tone.text(0.62), Tone.ink(0.07), Tone.glyph(0.5), Tone.surface, Tone.chip, Tone.glassTint]
        let resolves = 20_000
        let resolve = clock.measure {
            for i in 0..<resolves {
                _ = tone.color(styles[i % styles.count], dark: i % 2 == 0)
            }
        }
        let perTone = build / frames
        let perResolve = resolve / resolves
        print("SpaceChromeTone(hue:strength:) per drag frame: \(perTone); ToneStyle resolve: \(perResolve)")
        #expect(sink > 0)
        // Generous (Debug, unoptimised, shared CI box): a frame is ~8 ms.
        #expect(perTone < .milliseconds(3))
        #expect(perResolve < .microseconds(50))
    }
}
