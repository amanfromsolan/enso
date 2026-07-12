import AppKit
import SwiftUI

/// Appearance-aware semantic colors for Enso's app *chrome* — the sidebar,
/// window frame, settings panel, and owned modals. These follow the system
/// light/dark setting.
///
/// The terminal surface is deliberately excluded: its colors come from the
/// Ghostty theme, not from these tokens, so the terminal card (and the header
/// strip that blends into it) stays dark in both appearances.
///
/// Almost every chrome color in the app was authored as `.white.opacity(x)`
/// (foreground text, hairlines, hover washes) over a near-black panel. Those
/// map mechanically onto ``ink`` — a dynamic color that is white in dark mode
/// and near-black in light mode — with the original opacity preserved, so a
/// call like `Theme.ink.opacity(0.6)` renders correctly in both modes.
enum Theme {
    /// Universal foreground / overlay ink: white on dark, near-black on light.
    /// Replaces `.white.opacity(x)` for text, hairlines, borders, and the
    /// low-opacity hover / selection washes.
    static let ink = Color(nsColor: dynamic(dark: .white, light: NSColor(white: 0.08, alpha: 1)))

    /// The opposite of ``ink``: black on dark, white on light. For a label or
    /// glyph that must contrast a solid ``ink`` fill (the modal primary button,
    /// the shuffle button).
    static let inverseInk = Color(nsColor: dynamic(dark: .black, light: .white))

    /// Solid chrome panel fill — settings window, owned modals, the icon
    /// picker popover. Was the hard-coded `Color(red: 0.094, 0.096, 0.105)`.
    static let panel = Color(nsColor: dynamic(
        dark: NSColor(red: 0.094, green: 0.096, blue: 0.105, alpha: 1),
        light: NSColor(red: 0.965, green: 0.965, blue: 0.972, alpha: 1)
    ))

    /// Recessed well behind the space editor's icon preview. Dark mode keeps
    /// the original black well (`inverseInk × 0.32`) sunk into the near-black
    /// panel. Light mode uses a soft grey instead — a white well would vanish
    /// on the light panel, so this reads as a visible disc in both.
    static let iconWell = Color(nsColor: dynamic(
        dark: NSColor(white: 0, alpha: 0.32),
        light: NSColor(white: 0, alpha: 0.12)
    ))

    /// Wash laid over the frosted window/sidebar material. In dark mode it
    /// deepens the too-light blur toward near-black; in light mode it brightens
    /// the blur toward white so the sidebar reads as light chrome. Replaces the
    /// window/sidebar `Color.black.opacity(0.38)` overlays.
    static let windowWash = Color(nsColor: dynamic(
        dark: NSColor(white: 0, alpha: 0.38),
        // Light and airy: let the `.sidebar` behind-window blur show through.
        // The frost picks up the desktop, so the sidebar can darken where the
        // backdrop is dark — an accepted trade for the translucent look.
        light: NSColor(white: 1, alpha: 0.10)
    ))

    /// Foreground *text* ink at a given weight. Dark mode keeps the original
    /// airy white ramp (`white × opacity`); light mode uses a gamma-boosted
    /// black ramp, because dark ink needs more weight than light ink to read
    /// at the same nominal opacity — the faded look that works on black is too
    /// pale on a light frost. Use this for text and text-like glyphs; keep the
    /// plain ``ink`` for hairlines, borders, and hover/selection washes.
    static func text(_ opacity: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua:
                return NSColor(white: 1, alpha: opacity)
            default:
                // Gamma < 1 lifts the low/mid range so secondary text darkens
                // without the near-solid values changing much.
                return NSColor(white: 0.08, alpha: min(1, pow(opacity, 0.6)))
            }
        })
    }

    /// The palette / HUD card fill, top and bottom of its vertical gradient.
    /// Dark: the original near-black card. Light: a bright frosted card, so
    /// the ⌘T palette reads light-on-light like the rest of the chrome (it
    /// still floats over the always-dark terminal).
    static let paletteCardTop = Color(nsColor: dynamic(
        dark: NSColor(white: 0, alpha: 0.8),
        light: NSColor(white: 1, alpha: 0.80)
    ))
    static let paletteCardBottom = Color(nsColor: dynamic(
        dark: NSColor(white: 0, alpha: 0.6),
        light: NSColor(white: 1, alpha: 0.66)
    ))

    /// Foreground ink for content laid *directly over the terminal theme
    /// background* — the header strip. Unlike the appearance-driven ``ink``,
    /// this follows the actual color under it: white on a dark terminal theme,
    /// near-black on a light one. Picked from the background's own luminance,
    /// never from the theme name (see ``Color/isLight``). Comparable opacities
    /// on both sides so the dark-theme look is unchanged from the old
    /// `.white.opacity(x)`.
    static func headerInk(_ opacity: Double, over background: Color) -> Color {
        background.isLight ? Color.black.opacity(opacity) : Color.white.opacity(opacity)
    }

    /// Builds a dynamic NSColor that resolves per light/dark appearance.
    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: dark
            default: light
            }
        }
    }
}

extension Font.Weight {
    /// Nudges a weight one visual step heavier for light mode. The airy thin
    /// weights that look right as light-on-dark read too frail as dark-on-light,
    /// so light mode firms them up a notch; dark mode keeps the original.
    func bumped(for scheme: ColorScheme) -> Font.Weight {
        guard scheme == .light else { return self }
        switch self {
        case .ultraLight: return .thin
        case .thin: return .light
        case .light: return .regular
        case .regular: return .medium
        case .medium: return .semibold
        case .semibold: return .bold
        default: return self
        }
    }
}

extension Color {
    /// WCAG relative luminance (sRGB-linearized), 0…1. Computed off the real
    /// sRGB components via NSColor so it works for any color — used to decide
    /// whether ink laid over this color should be light or dark.
    var relativeLuminance: Double {
        let resolved = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(white: 0, alpha: 1)
        func linear(_ component: CGFloat) -> Double {
            let c = Double(component)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(resolved.redComponent)
            + 0.7152 * linear(resolved.greenComponent)
            + 0.0722 * linear(resolved.blueComponent)
    }

    /// True when the color is light enough that dark ink reads better on top
    /// (threshold at the luminance midpoint).
    var isLight: Bool { relativeLuminance > 0.5 }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Appearance preference

/// User appearance preference: follow the system, or pin the app light/dark.
/// Applied app-wide via NSApplication.appearance, which every Theme color
/// and material already tracks.
enum AppAppearance: String, CaseIterable {
    case system
    case light
    case dark

    static let defaultsKey = "appAppearance"

    static var current: AppAppearance {
        UserDefaults.standard.string(forKey: defaultsKey)
            .flatMap(AppAppearance.init) ?? .system
    }

    static func set(_ value: AppAppearance) {
        UserDefaults.standard.set(value.rawValue, forKey: defaultsKey)
        apply(value)
    }

    static func applyStored() {
        apply(current)
    }

    /// Flips between light and dark; from .system it flips away from the
    /// current effective appearance.
    static func toggle() {
        let isDark = NSApplication.shared.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        set(isDark ? .light : .dark)
    }

    private static func apply(_ value: AppAppearance) {
        switch value {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Owned-modal frost chrome

/// Backdrop for owned frosted modals (What's New, the space editor): the
/// sidebar's material under the window wash, 24pt corners, a dark-mode
/// hairline, and the standard modal shadow pair. Pair it with a matching
/// 24pt clipShape on the modal's content.
struct ModalFrostBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        FrostMaterial()
            .overlay(Theme.windowWash)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.05 : 0))
            )
            .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
            .shadow(color: .black.opacity(0.65), radius: 70, y: 30)
    }
}

/// The sidebar's frosted material blended within the window.
private struct FrostMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
