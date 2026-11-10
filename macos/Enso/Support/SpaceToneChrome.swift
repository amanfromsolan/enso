import AppKit
import Combine
import SwiftUI

// The SwiftUI side of space colour (the maths and the API notes are in
// SpaceTone.swift). One value, `SpaceChromeTone`, travels down the
// environment of every hosting graph that draws chrome (the window root, each
// space page, the titlebar toggle). Views never branch on colour: they hand a
// `ToneStyle` to `foregroundStyle`/`fill` (it resolves itself from the
// environment) or, where SwiftUI wants a plain `Color` (glass tints, shadows,
// gradients), ask the tone for one.
//
// Every style names what it draws today (`neutral`) and its tonal role. With
// no colour (presence 0) a style resolves to exactly today's Color, so an
// uncoloured space renders pixel-for-pixel as before.

/// The chrome's current tone: both appearances' palettes, so each view
/// resolves against its own colour scheme.
nonisolated struct SpaceChromeTone: Equatable, Sendable {
    var light: SpaceTonePalette
    var dark: SpaceTonePalette

    static let neutral = SpaceChromeTone(colour: .none)

    init(colour: SpaceColour) {
        light = SpaceTone.palette(for: colour, dark: false)
        dark = SpaceTone.palette(for: colour, dark: true)
    }

    /// The picker's continuous tone (see `SpaceTone.palette(hue:strength:dark:)`).
    init(hue: Double, strength: Double) {
        light = SpaceTone.palette(hue: hue, strength: strength, dark: false)
        dark = SpaceTone.palette(hue: hue, strength: strength, dark: true)
    }

    init(light: SpaceTonePalette, dark: SpaceTonePalette) {
        self.light = light
        self.dark = dark
    }

    var isNeutral: Bool { light.presence <= 0 && dark.presence <= 0 }

    func palette(dark isDark: Bool) -> SpaceTonePalette { isDark ? dark : light }

    /// The crossfade: an OKLab mix of the two tones.
    static func mix(_ a: SpaceChromeTone, _ b: SpaceChromeTone, _ t: Double) -> SpaceChromeTone {
        SpaceChromeTone(
            light: SpaceTonePalette.mix(a.light, b.light, t),
            dark: SpaceTonePalette.mix(a.dark, b.dark, t)
        )
    }

    /// The colour a style draws in one appearance.
    func color(_ style: ToneStyle, dark isDark: Bool) -> Color {
        let p = palette(dark: isDark)
        guard p.presence > 0 else { return style.neutral.color(dark: isDark) }
        let toned = style.toned(in: p, dark: isDark)
        if p.presence >= 1 { return toned.color }
        let base = style.neutral.rgba(dark: isDark)
        var mixed: ToneRGB
        if base.a <= 0 {
            mixed = toned
        } else if toned.a <= 0 {
            mixed = base
        } else {
            mixed = OKLab.mix(base, toned, p.presence)
        }
        mixed.a = base.a + (toned.a - base.a) * p.presence
        return mixed.color
    }
}

extension EnvironmentValues {
    nonisolated var spaceTone: SpaceChromeTone {
        get { self[SpaceToneKey.self] }
        set { self[SpaceToneKey.self] = newValue }
    }
}

private nonisolated struct SpaceToneKey: EnvironmentKey {
    static let defaultValue = SpaceChromeTone.neutral
}

nonisolated extension ToneRGB {
    var color: Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: a)
    }
}

// MARK: - Styles

/// What a token draws today, exactly as the views wrote it before tones.
nonisolated enum ToneNeutral: Hashable, Sendable {
    /// `Theme.text(opacity)`
    case text(Double)
    /// `Theme.ink.opacity(opacity)`
    case ink(Double)
    /// `Color.white.opacity(…)`, per appearance
    case white(light: Double, dark: Double)
    /// `Color.black.opacity(…)`, per appearance
    case black(light: Double, dark: Double)
    /// `Color.accentColor.opacity(opacity)`
    case accent(Double)
    /// Nothing (a layer that only exists when tinted)
    case clear

    func color(dark: Bool) -> Color {
        switch self {
        case .text(let op): Theme.text(op)
        case .ink(let op): Theme.ink.opacity(op)
        case .white(let l, let d): Color.white.opacity(dark ? d : l)
        case .black(let l, let d): Color.black.opacity(dark ? d : l)
        case .accent(let op): Color.accentColor.opacity(op)
        case .clear: Color.clear
        }
    }

    /// The same colour as numbers, for crossfading out of it.
    func rgba(dark: Bool) -> ToneRGB {
        let inkLight = 0.08 * 255
        switch self {
        case .text(let op):
            return dark ? ToneRGB(255, 255, 255, op) : ToneRGB(inkLight, inkLight, inkLight, min(1, pow(op, 0.6)))
        case .ink(let op):
            return dark ? ToneRGB(255, 255, 255, op) : ToneRGB(inkLight, inkLight, inkLight, op)
        case .white(let l, let d):
            return ToneRGB(255, 255, 255, dark ? d : l)
        case .black(let l, let d):
            return ToneRGB(0, 0, 0, dark ? d : l)
        case .accent(let op):
            let c = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
            return ToneRGB(c.redComponent * 255, c.greenComponent * 255, c.blueComponent * 255, op)
        case .clear:
            return ToneRGB(0, 0, 0, 0)
        }
    }
}

/// The palette token a style draws when tinted.
nonisolated enum ToneRole: Hashable, Sendable {
    case surface, gutter, chip, chipRim, shadow, hover, glass, glassRim
    case t95, t90, t82, t62, t40, glyph, cardRim, accent

    /// The text step an opacity from the old `Theme.text` ramp maps to.
    static func textStep(_ opacity: Double) -> ToneRole {
        switch opacity {
        case 0.93...: .t95
        case 0.86...: .t90
        case 0.72...: .t82
        case 0.5...: .t62
        default: .t40
        }
    }

    func rgb(in p: SpaceTonePalette) -> ToneRGB {
        switch self {
        case .surface: p.surface
        case .gutter: p.gutter
        case .chip: p.chip
        case .chipRim: p.chipRim
        case .shadow: p.shadow
        case .hover: p.hover
        case .glass: p.glass
        case .glassRim: p.glassRim
        case .t95: p.t95
        case .t90: p.t90
        case .t82: p.t82
        case .t62: p.t62
        case .t40: p.t40
        case .glyph: p.glyph
        case .cardRim: p.cardRim
        case .accent: p.accent
        }
    }
}

/// A chrome colour that follows the active space's tone. A `ShapeStyle`, so
/// it resolves at render time from the environment: a tone change (or a
/// crossfade frame) updates only the views that draw with it, never their
/// parents' bodies.
nonisolated struct ToneStyle: ShapeStyle, Hashable {
    var neutral: ToneNeutral
    var role: ToneRole
    /// Multiplies the token's own alpha when tinted, per appearance.
    var lightAlpha: Double = 1
    var darkAlpha: Double = 1

    init(neutral: ToneNeutral, role: ToneRole, alpha: Double = 1) {
        self.neutral = neutral
        self.role = role
        lightAlpha = alpha
        darkAlpha = alpha
    }

    init(neutral: ToneNeutral, role: ToneRole, lightAlpha: Double, darkAlpha: Double) {
        self.neutral = neutral
        self.role = role
        self.lightAlpha = lightAlpha
        self.darkAlpha = darkAlpha
    }

    func toned(in p: SpaceTonePalette, dark: Bool) -> ToneRGB {
        var c = role.rgb(in: p)
        c.a *= dark ? darkAlpha : lightAlpha
        return c
    }

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.spaceTone.color(self, dark: environment.colorScheme == .dark)
    }
}

/// The chrome's tokens, by what they replace.
nonisolated enum Tone {
    /// Text and text-like glyphs: `Theme.text(opacity)` today, the tonal
    /// text step for that opacity when tinted.
    static func text(_ opacity: Double) -> ToneStyle {
        ToneStyle(neutral: .text(opacity), role: .textStep(opacity))
    }

    /// Hover / selection washes, hairlines: `Theme.ink.opacity(opacity)`
    /// today, the tonal hover ink at the same opacity when tinted.
    static func ink(_ opacity: Double) -> ToneStyle {
        ToneStyle(neutral: .ink(opacity), role: .hover, alpha: opacity)
    }

    /// Folder and tab glyphs, badges: `Theme.ink.opacity(opacity)` today,
    /// the solid tonal glyph colour when tinted.
    static func glyph(_ opacity: Double) -> ToneStyle {
        ToneStyle(neutral: .ink(opacity), role: .glyph)
    }

    /// An ink-drawn mark that should read as text when tinted (the pill's
    /// dot icon).
    static func inkMark(_ opacity: Double) -> ToneStyle {
        ToneStyle(neutral: .ink(opacity), role: .textStep(opacity))
    }

    /// Drop indicators: the system accent today, the tonal accent tinted.
    static func accent(_ opacity: Double = 1) -> ToneStyle {
        ToneStyle(neutral: .accent(opacity), role: .accent, alpha: opacity)
    }

    /// The sidebar ground and the window gutter: nothing today; the tonal
    /// surface over the frost when tinted.
    static let surface = ToneStyle(neutral: .clear, role: .surface, alpha: SpaceTone.groundOpacity)
    static let gutter = ToneStyle(neutral: .clear, role: .gutter, alpha: SpaceTone.groundOpacity)

    /// The raised chip (selected row, pre-glass thumbs).
    static let chip = ToneStyle(neutral: .white(light: 0.82, dark: 0.13), role: .chip)

    /// The chip's two shadows.
    static let chipShadowNear = ToneStyle(
        neutral: .black(light: 0.06, dark: 0.2), role: .shadow, lightAlpha: 0.08, darkAlpha: 0.25
    )
    static let chipShadowFar = ToneStyle(
        neutral: .black(light: 0.13, dark: 0.22), role: .shadow, lightAlpha: 0.15, darkAlpha: 0.3
    )

    /// The glass bases' tint.
    static let glassTint = ToneStyle(neutral: .black(light: 0.05, dark: 0.1), role: .glass)
    /// The pre-glass fallback's rim.
    static let glassRim = ToneStyle(neutral: .ink(0.1), role: .glassRim)
    /// The pre-glass fallback's tinted layer over the material.
    static let glassFill = ToneStyle(neutral: .clear, role: .glass)
    /// The Liquid Glass thumbs' tint. Kept partial so they stay glass.
    static let thumbTint = ToneStyle(neutral: .clear, role: .chip, alpha: 0.6)
}

/// Another space's own colour, for its icon in the pill while it isn't the
/// active one. Not tied to the active tone.
nonisolated struct SpaceCellStyle: ShapeStyle, Hashable {
    let colour: SpaceColour

    func resolve(in environment: EnvironmentValues) -> Color {
        SpaceTone.palette(for: colour, dark: environment.colorScheme == .dark).cell.color
    }
}

// MARK: - Driver

/// Owns the tone the chrome shows and animates it. The store tells it the
/// target; it crossfades in OKLab (SwiftUI's own Color animation isn't
/// perceptual) by publishing a blended tone per frame, with every such
/// publish free of SwiftUI animation.
@MainActor
final class SpaceToneDriver: ObservableObject {
    enum Transition {
        /// Snap (the picker's live drag, launch).
        case instant
        /// Space switch: ~0.35s ease-in-out.
        case crossfade
        /// A saved colour changed (picker commit, the menu): a critically
        /// damped spring, so it settles without overshooting the colour.
        case spring
    }

    @Published private(set) var tone: SpaceChromeTone = .neutral

    static let crossfadeDuration: TimeInterval = 0.35
    private static let spring = Spring(duration: 0.35, bounce: 0)

    private(set) var target: SpaceChromeTone = .neutral
    private var from: SpaceChromeTone = .neutral
    private var transition: Transition = .instant
    private var start: CFTimeInterval = 0
    private var timer: Timer?

    var isAnimating: Bool { timer != nil }

    func show(_ next: SpaceChromeTone, transition: Transition) {
        guard next != target || (timer == nil && tone != next) else { return }
        target = next
        if transition == .instant
            || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || tone == next {
            stop()
            publish(next)
            return
        }
        // Retargeting mid-fade starts from what's on screen, so a quick
        // swipe back and forth never jumps.
        from = tone
        self.transition = transition
        start = CACurrentMediaTime()
        if timer == nil {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func tick() {
        let elapsed = CACurrentMediaTime() - start
        let progress: Double
        switch transition {
        case .instant:
            progress = 1
        case .crossfade:
            let t = min(1, elapsed / Self.crossfadeDuration)
            progress = t >= 1 ? 1 : (t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
        case .spring:
            let settle = min(Self.spring.settlingDuration, 0.6)
            progress = elapsed >= settle ? 1 : min(1, max(0, Self.spring.value(target: 1.0, time: elapsed)))
        }
        if progress >= 1 {
            stop()
            publish(target)
        } else {
            publish(SpaceChromeTone.mix(from, target, progress))
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func publish(_ value: SpaceChromeTone) {
        guard value != tone else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            tone = value
        }
    }
}

/// Puts the driver's tone into a hosting graph's environment. A modifier
/// with its own observation, so a tone frame re-runs only this and the
/// views that draw with tone styles, never the content's body.
struct SpaceToneScope: ViewModifier {
    @ObservedObject var driver: SpaceToneDriver

    func body(content: Content) -> some View {
        content.environment(\.spaceTone, driver.tone)
    }
}

extension View {
    func spaceTone(from driver: SpaceToneDriver) -> some View {
        modifier(SpaceToneScope(driver: driver))
    }
}

/// The sidebar ground and the gutter: the tonal surface laid over the frost
/// under the sidebar, the deeper gutter step everywhere else (around the
/// terminal card). Draws nothing for an uncoloured space.
struct SpaceToneGround: View {
    var sidebarWidth: CGFloat
    @Environment(\.spaceTone) private var tone

    var body: some View {
        if !tone.isNeutral {
            HStack(spacing: 0) {
                Rectangle().fill(Tone.surface).frame(width: sidebarWidth)
                Rectangle().fill(Tone.gutter)
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Terminal card tint

/// The terminal card's space tint (x/terminal.js): a translucent fill in the
/// hue laid over each card's content. Drawn by plain AppKit layers fed
/// straight from the tone driver (`TerminalTintFeed`), so crossfade and drag
/// frames never touch the terminal's NSViewRepresentable or any SwiftUI body.
enum TerminalTint {
    /// The palette whose tint applies: the terminal theme's background
    /// decides, not the system appearance (same threshold as the pane
    /// headers' ink, `GhosttyRuntime.terminalColorScheme`).
    static var terminalIsDark: Bool {
        GhosttyRuntime.shared.terminalColorScheme == .dark
    }

    /// The overlay colour for a tone; alpha 0 = no tint.
    static func tint(for tone: SpaceChromeTone) -> ToneRGB {
        SpaceTone.terminalTint(in: tone.palette(dark: terminalIsDark), scale: scale)
    }

    /// Paints `tint` onto an overlay layer with implicit animations off (the
    /// driver already animates). No tint hides the layer outright, so an
    /// uncoloured space composites exactly as before.
    static func apply(_ tint: ToneRGB, to layer: CALayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if tint.a > 0 {
            layer.backgroundColor = CGColor(
                srgbRed: tint.r / 255, green: tint.g / 255, blue: tint.b / 255, alpha: tint.a
            )
            layer.isHidden = false
        } else {
            layer.isHidden = true
            layer.backgroundColor = nil
        }
        CATransaction.commit()
    }

    #if ENSO_DEVTOOLS
    /// Dev tuning: a multiplier on the tint's opacity, read from the
    /// `EnsoTerminalTintScale` default (a launch argument works too) and set
    /// live from the Swipe Tuner panel's Tint slider.
    static let scaleDefaultsKey = "EnsoTerminalTintScale"
    static let scaleRange: ClosedRange<Double> = 0...4
    static let scaleDidChange = Notification.Name("EnsoTerminalTintScaleDidChange")

    private(set) static var scale: Double = {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: scaleDefaultsKey) != nil else { return 1 }
        let value = defaults.double(forKey: scaleDefaultsKey)
        return value.isFinite ? min(scaleRange.upperBound, max(scaleRange.lowerBound, value)) : 1
    }()

    static func setScale(_ value: Double) {
        scale = min(scaleRange.upperBound, max(scaleRange.lowerBound, value))
        UserDefaults.standard.set(scale, forKey: scaleDefaultsKey)
        NotificationCenter.default.post(name: scaleDidChange, object: nil)
    }
    #else
    static let scale: Double = 1
    #endif
}

/// Follows the tone driver for one owner of tint layers and reports each
/// distinct tint once. A Combine subscription, not SwiftUI: a crossfade
/// publishes ~120 tones a second and the terminal host must not re-render.
@MainActor
final class TerminalTintFeed {
    private(set) var tint = ToneRGB(0, 0, 0, 0)
    var onChange: ((ToneRGB) -> Void)?

    private weak var driver: SpaceToneDriver?
    private var subscriptions: Set<AnyCancellable> = []

    /// Subscribes once per driver; repeat calls with the same one are free.
    func attach(to driver: SpaceToneDriver) {
        guard driver !== self.driver else { return }
        self.driver = driver
        subscriptions = []
        // `$tone` emits the current value straight away, then every frame.
        driver.$tone
            .sink { [weak self] tone in self?.update(tone) }
            .store(in: &subscriptions)
        #if ENSO_DEVTOOLS
        NotificationCenter.default.publisher(for: TerminalTint.scaleDidChange)
            .sink { [weak self] _ in
                guard let self, let driver = self.driver else { return }
                self.update(driver.tone)
            }
            .store(in: &subscriptions)
        #endif
    }

    private func update(_ tone: SpaceChromeTone) {
        let next = TerminalTint.tint(for: tone)
        // Every alpha-0 tint is the same "nothing".
        guard next != tint, next.a > 0 || tint.a > 0 else { return }
        tint = next
        onChange?(next)
    }
}

/// The tint as a SwiftUI background, for a card with no pane card in it
/// (an unsplit sleeping tab, the No Tabs state). Gets the driver once; tone
/// frames go to its layer directly. Never hit-tests.
struct TerminalTintBackground: NSViewRepresentable {
    let driver: SpaceToneDriver

    func makeNSView(context: Context) -> TerminalTintView {
        TerminalTintView()
    }

    func updateNSView(_ view: TerminalTintView, context: Context) {
        view.attach(to: driver)
    }
}

final class TerminalTintView: NSView {
    private let feed = TerminalTintFeed()
    /// A sublayer, not the backing layer: AppKit owns the backing layer's
    /// hidden state.
    private let tintLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        tintLayer.isHidden = true
        layer?.addSublayer(tintLayer)
        feed.onChange = { [weak self] tint in
            guard let self else { return }
            TerminalTint.apply(tint, to: self.tintLayer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func attach(to driver: SpaceToneDriver) {
        feed.attach(to: driver)
    }

    override func layout() {
        super.layout()
        fitTintLayer()
    }

    /// A plain NSView gets no reliable layout() after SwiftUI sets its
    /// frame (see PaneCardView), so chase the size here too.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitTintLayer()
    }

    private func fitTintLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tintLayer.frame = bounds
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
