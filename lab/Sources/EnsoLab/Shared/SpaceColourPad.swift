import AppKit
import SwiftUI

// MARK: - SpaceColourPad
//
// The space-colour picker: a 2D pad with one draggable drop.
//   sideways = hue (9 colours, 0...8), up = stronger (0 none, 1 Subtle, 2 Medium, 3 Strong).
// Drag it, flick it, or click empty pad to make it hop there. On release it snaps to the
// nearest of the 9 x 4 spots.
//
// Ported from internal-docs/2026-11-09-themes-and-settings/space-themes/fidget/blob.html
// (interaction + physics) and blob-styles/liquid-glass.html (the glass look), but the drop is
// made of real Liquid Glass (`.glassEffect`, macOS 26) instead of a shader imitation.
//
// Portable on purpose: no Enso types, no lab types. Everything except `SpaceColourPad` itself is
// `private` to this file.
//
// LAB COPY. The canonical copy is macos/Enso/Views/SpaceColourPad.swift (wired into the Edit Space
// sheet). This one stays for Exp02's squash comparison. They diverge only in plumbing: the Enso
// copy marks its value types `nonisolated` (MainActor-default target) and caches the field
// bitmap in the model instead of an Equatable view. Behaviour changes go to the Enso copy first.
//
// Callbacks:
//   onChange(hue, strength)  every frame while the user drives it (drag / flick). Continuous
//                            values: hue in 0...8, strength in 0...3. Apply with no animation.
//   onCommit(hue, strength)  once per gesture with the snapped spot (on release, or when a flick
//                            decides where it lands, or per arrow-key step). Spring to it.
//   Escape mid-gesture reports onCommit with the spot the gesture started from.
//
// The pad also follows `hue`/`strength` when they change from outside (switching space,
// Cancel) with a small hop, unless the user is mid-gesture.

struct SpaceColourPad: View {
    /// How the drop is built. Lab switches; Enso will pick one and can delete the rest.
    struct Style: Equatable {
        enum Squash: String, CaseIterable, Identifiable {
            /// a. Glass circle + `rotationEffect` / `scaleEffect(x:y:)` / `rotationEffect`.
            case scale
            /// b. Glass circle + one `transformEffect` with blob.html's 2x2 squash matrix.
            case matrix
            /// c. No transform: the glass *shape* is the squashed ellipse, rebuilt every frame.
            case shape
            /// d. (c) inside a `GlassEffectContainer` with a lagging droplet that merges/splits.
            case trail
            /// The pre-macOS 26 drop (painted jelly), selectable for comparison.
            case fallback
            var id: Self { self }
        }
        enum GlassVariant: String, CaseIterable, Identifiable {
            case clear, regular
            var id: Self { self }
        }

        // Default: (c) shape. See the notes on `GlassDrop` for why.
        var squash: Squash = .shape
        var glass: GlassVariant = .clear
        /// A whisper of the current hue in the glass body (`Glass.tint`).
        var tinted = true
        /// `Glass.interactive()`. Needs the drop to hit-test, so it's off by default.
        var interactive = false
        /// Lab switch: behave as if Reduce Motion were on.
        var forceReducedMotion = false
    }

    static let defaultHueNames = ["Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Teal", "Graphite"]
    static let strengthNames = ["No colour", "Subtle", "Medium", "Strong"]

    var hue: Double
    var strength: Double
    /// Pad colour at any continuous point. Sampled once per size/appearance into a bitmap.
    var swatch: (_ hue: Double, _ strength: Double) -> Color
    /// The vivid colour of a hue (glass tint, caustic, fallback drop). Defaults to swatch(hue, 3).
    var accent: ((_ hue: Double) -> Color)?
    var style: Style
    var hueNames: [String]
    var onChange: (_ hue: Double, _ strength: Double) -> Void
    var onCommit: (_ hue: Int, _ strength: Int) -> Void

    init(
        hue: Double,
        strength: Double,
        swatch: @escaping (_ hue: Double, _ strength: Double) -> Color,
        accent: ((_ hue: Double) -> Color)? = nil,
        style: Style = Style(),
        hueNames: [String] = SpaceColourPad.defaultHueNames,
        onChange: @escaping (_ hue: Double, _ strength: Double) -> Void,
        onCommit: @escaping (_ hue: Int, _ strength: Int) -> Void
    ) {
        self.hue = hue
        self.strength = strength
        self.swatch = swatch
        self.accent = accent
        self.style = style
        self.hueNames = hueNames
        self.onChange = onChange
        self.onCommit = onCommit
    }

    @State private var model = PadModel()
    @FocusState private var focused: Bool
    @GestureState private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.colorScheme) private var scheme

    private var reduced: Bool { systemReduceMotion || style.forceReducedMotion }

    private var propSpot: PadSpot {
        PadSpot(
            hue: Int(padClamp(hue.rounded(), 0, Double(PadGeometry.columns))),
            strength: Int(padClamp(strength.rounded(), 0, Double(PadGeometry.rows)))
        )
    }

    private var accentFor: (Double) -> Color {
        if let accent { return accent }
        let swatch = swatch
        return { swatch($0, 3) }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                PadField(size: geo.size, scheme: scheme, swatch: swatch)
                    .equatable()
                PadDots(model: model, size: geo.size, scheme: scheme)
                PadDropLayer(
                    model: model,
                    style: style,
                    scheme: scheme,
                    accent: accentFor,
                    showRing: focused && model.keyboardFocus,
                    onEvents: dispatch
                )
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): model.hover(at: p)
                case .ended: model.hover(at: nil)
                }
            }
            .onAppear { model.configure(size: geo.size, spot: propSpot, reduced: reduced) }
            .onChange(of: geo.size) { _, size in model.resize(size) }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            let delta: (Int, Int)
            switch press.key {
            case .leftArrow: delta = (-1, 0)
            case .rightArrow: delta = (1, 0)
            case .upArrow: delta = (0, 1)
            default: delta = (0, -1)
            }
            model.keyboardFocus = true
            dispatch(model.step(hue: delta.0, strength: delta.1))
            return .handled
        }
        .onKeyPress(.escape) {
            guard model.isInteracting else { return .ignored }
            dispatch(model.cancel())
            return .handled
        }
        .onChange(of: pressing) { _, isPressing in
            // DragGesture can end without onEnded (e.g. the system cancels it). If the pointer is
            // still held once onEnded has had its chance, release it with no velocity.
            guard !isPressing else { return }
            DispatchQueue.main.async {
                if model.hasPointer { dispatch(model.release(velocity: .zero, time: Date())) }
            }
        }
        .onChange(of: propSpot) { _, spot in model.external(spot) }
        .onChange(of: reduced) { _, value in model.reduced = value }
        .task {
            // Once after it appears: a hop and a wobble, so it reads as something you can pick up.
            try? await Task.sleep(for: .milliseconds(700))
            model.hello()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: dispatch(model.step(hue: 1, strength: 0))
            case .decrement: dispatch(model.step(hue: -1, strength: 0))
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Stronger") { dispatch(model.step(hue: 0, strength: 1)) }
        .accessibilityAction(named: "Weaker") { dispatch(model.step(hue: 0, strength: -1)) }
    }

    private var accessibilityValue: String {
        let spot = model.target
        if spot.strength == 0 { return Self.strengthNames[0] }
        let name = hueNames.indices.contains(spot.hue) ? hueNames[spot.hue] : "Colour \(spot.hue + 1)"
        return "\(name), \(Self.strengthNames[spot.strength])"
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { value in
                if !model.hasPointer {
                    focused = true
                    model.keyboardFocus = false
                    dispatch(model.press(at: value.startLocation, time: value.time, origin: propSpot))
                }
                model.move(to: value.location, time: value.time)
            }
            .onEnded { value in
                dispatch(model.release(velocity: value.velocity, time: value.time))
            }
    }

    private func dispatch(_ events: [PadEvent]) {
        for event in events {
            switch event {
            case .live(let h, let s):
                onChange(h, s)
            case .commit(let spot):
                onCommit(spot.hue, spot.strength)
            case .hueDetent:
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            case .strengthDetent:
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            }
        }
    }
}

// MARK: - Geometry

private func padClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

private struct PadSpot: Equatable {
    var hue: Int
    var strength: Int
}

/// blob.html's pad maths. Points, y down. Margins are to the outer sweet spots.
private struct PadGeometry {
    static let columns = 8          // hues 0...8
    static let rows = 3             // strength 0...3
    static let marginX = 20.0       // MX
    static let marginY = 19.0       // MY
    static let radius = 15.0        // BR: the drop's radius at rest

    var width = 292.0
    var height = 150.0

    var loX: Double { Self.marginX }
    var hiX: Double { width - Self.marginX }
    var loY: Double { Self.marginY }
    var hiY: Double { height - Self.marginY }

    func spotX(_ i: Int) -> Double { Self.marginX + Double(i) * (width - 2 * Self.marginX) / Double(Self.columns) }
    func spotY(_ s: Int) -> Double { height - Self.marginY - Double(s) * (height - 2 * Self.marginY) / Double(Self.rows) }

    func toHS(_ x: Double, _ y: Double) -> (hue: Double, strength: Double) {
        let h = padClamp((x - Self.marginX) / max(1, width - 2 * Self.marginX), 0, 1) * Double(Self.columns)
        let s = padClamp((height - Self.marginY - y) / max(1, height - 2 * Self.marginY), 0, 1) * Double(Self.rows)
        return (h, s)
    }

    func nearest(_ x: Double, _ y: Double) -> PadSpot {
        let (h, s) = toHS(x, y)
        return PadSpot(hue: Int(h.rounded()), strength: Int(s.rounded()))
    }
}

// MARK: - Model (per-frame spring integrator)

private enum PadEvent {
    case live(Double, Double)
    case commit(PadSpot)
    case hueDetent
    case strengthDetent
}

/// What the drop layer draws this frame. Published once per frame.
private struct DropFrame: Equatable {
    var x = 0.0, y = 0.0, z = 0.0       // centre on the pad, hop height
    var sc = 1.0                        // lift scale
    var dp = 0.0, dq = 0.0              // traceless squash tensor [[dp, dq], [dq, -dp]]
    var up = 0.0                        // how far it's "off" the pad (shadow)
    var trailX = 0.0, trailY = 0.0
    var hue = 0.0, strength = 0.0       // continuous, at the drop's position

    var centre: CGPoint { CGPoint(x: x, y: y - z) }
    /// The full matrix sc * (I + T), as blob.html's CSS `matrix(a, c, c, d, 0, 0)`.
    var a: Double { sc * (1 + dp) }
    var c: Double { sc * dq }
    var d: Double { sc * (1 - dp) }
    /// Eigen form of the same matrix: R(phi) * diag(major, minor) * R(-phi).
    var magnitude: Double { (dp * dp + dq * dq).squareRoot() }
    var phi: Double { atan2(dq, dp) / 2 }
    var major: Double { sc * (1 + magnitude) }
    var minor: Double { sc * (1 - magnitude) }

    func centredTransform(side: Double) -> CGAffineTransform {
        let m = CGAffineTransform(a: a, b: c, c: c, d: d, tx: 0, ty: 0)
        return CGAffineTransform(translationX: -side / 2, y: -side / 2)
            .concatenating(m)
            .concatenating(CGAffineTransform(translationX: side / 2, y: side / 2))
    }
}

@Observable
private final class PadModel {
    // Observed: only what views need. `frame` changes once per animation frame; the rest rarely.
    var frame = DropFrame()
    var running = false
    var near: PadSpot?
    var target = PadSpot(hue: 0, strength: 0)
    var keyboardFocus = false

    enum Mode { case drag, flick, settle, follow }
    struct Pointer {
        var x, y, sx, sy, ox, oy: Double
        var onBlob: Bool
        var moved = false
        var lastMove: Date
        var cancelled = false
    }
    struct Hop { var t: Double; var dur: Double; var h: Double }

    @ObservationIgnored var geo = PadGeometry()
    @ObservationIgnored var reduced = false
    @ObservationIgnored private var x = 0.0
    @ObservationIgnored private var y = 0.0
    @ObservationIgnored private var vx = 0.0
    @ObservationIgnored private var vy = 0.0
    @ObservationIgnored private var tx = 0.0
    @ObservationIgnored private var ty = 0.0
    @ObservationIgnored private var dp = 0.0
    @ObservationIgnored private var dq = 0.0
    @ObservationIgnored private var vdp = 0.0
    @ObservationIgnored private var vdq = 0.0
    @ObservationIgnored private var lift = 0.0
    @ObservationIgnored private var vlift = 0.0
    @ObservationIgnored private var liftT = 0.0
    @ObservationIgnored private var z = 0.0
    @ObservationIgnored private var hopState: Hop?
    @ObservationIgnored private var trailX = 0.0
    @ObservationIgnored private var trailY = 0.0
    @ObservationIgnored private var tvx = 0.0
    @ObservationIgnored private var tvy = 0.0
    @ObservationIgnored private var mode: Mode = .settle
    @ObservationIgnored private var ptr: Pointer?
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var driving = false       // user-initiated motion: show the near dot
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var detent: PadSpot?
    @ObservationIgnored private var origin: PadSpot?
    @ObservationIgnored private var configured = false

    var hasPointer: Bool { ptr != nil }
    var isInteracting: Bool { (ptr.map { !$0.cancelled } ?? false) || mode == .flick }

    // ---- springs (blob.html: SPRING, crit) ----
    private static func crit(_ k: Double) -> Double { 2 * k.squareRoot() }
    private func spring(_ m: Mode) -> (k: Double, c: Double) {
        if reduced {
            switch m {
            case .drag: return (900, Self.crit(900))
            default: return (420, Self.crit(420))
            }
        }
        switch m {
        case .drag: return (520, 34)
        case .follow: return (230, 25)
        default: return (300, 17)
        }
    }

    // ---- setup ----
    func configure(size: CGSize, spot: PadSpot, reduced: Bool) {
        geo.width = size.width
        geo.height = size.height
        self.reduced = reduced
        guard !configured else { resize(size); return }
        configured = true
        setTarget(spot)
        snap()
        publish()
    }

    func resize(_ size: CGSize) {
        guard size.width != geo.width || size.height != geo.height else { return }
        geo.width = size.width
        geo.height = size.height
        setTarget(target)
        if !running { snap(); publish() }
    }

    // ---- inputs ----
    func press(at p: CGPoint, time: Date, origin: PadSpot) -> [PadEvent] {
        guard ptr == nil else { return [] }
        self.origin = origin
        let px = Double(p.x), py = Double(p.y)
        let onBlob = hypot(px - x, py - y) <= PadGeometry.radius + 5
        ptr = Pointer(x: px, y: py, sx: px, sy: py,
                      ox: onBlob ? px - x : 0, oy: onBlob ? py - y : 0,
                      onBlob: onBlob, lastMove: time)
        mode = .drag
        liftT = 1
        driving = true
        detent = geo.nearest(x, y)
        if !onBlob { hop(13, 0.34) } else if !reduced { vdp -= 0.9 }   // pressed: a little squish
        wake()
        return []
    }

    func move(to p: CGPoint, time: Date) {
        guard var q = ptr, !q.cancelled else { return }
        let px = Double(p.x), py = Double(p.y)
        if px != q.x || py != q.y { q.lastMove = time }
        q.x = px
        q.y = py
        if hypot(q.x - q.sx, q.y - q.sy) > 3 { q.moved = true }
        ptr = q
    }

    func release(velocity: CGSize, time: Date) -> [PadEvent] {
        guard let q = ptr else { return [] }
        ptr = nil
        guard !q.cancelled else { return [] }
        liftT = hovering ? 0.5 : 0
        // Only trust the gesture's velocity if the pointer was still moving at release.
        let fresh = time.timeIntervalSince(q.lastMove) < 0.06
        let fvx = fresh ? Double(velocity.width) : 0
        let fvy = fresh ? Double(velocity.height) : 0
        var events: [PadEvent] = []
        if !q.moved {
            if q.onBlob {
                if !reduced { vdp += 2.2 }                        // poke: it wobbles
                setTarget(geo.nearest(x, y))
            } else {
                setTarget(geo.nearest(q.sx, q.sy))                // click: hop there
            }
            mode = .settle
            events.append(.commit(target))
        } else if !reduced, hypot(fvx, fvy) > 420 {
            let speed = hypot(fvx, fvy), cap = min(1, 2600 / speed)
            vx = fvx * 0.9 * cap
            vy = fvy * 0.9 * cap
            mode = .flick                                         // commits when it decides where to land
        } else {
            setTarget(geo.nearest(x + vx * 0.05, y + vy * 0.05))
            mode = .settle
            events.append(.commit(target))
        }
        wake()
        return events
    }

    /// Escape mid-gesture: put it back where the gesture started.
    func cancel() -> [PadEvent] {
        guard isInteracting else { return [] }
        let o = origin ?? target
        ptr?.cancelled = true
        liftT = hovering ? 0.5 : 0
        follow(o)
        // Commit only (no live jump): the consumer springs back, as it does on any commit.
        return [.commit(o)]
    }

    /// Arrow keys and VoiceOver: one spot per press, committed at once.
    func step(hue dh: Int, strength ds: Int) -> [PadEvent] {
        guard !isInteracting else { return [] }
        let base = (mode == .settle || mode == .follow) ? target : geo.nearest(x, y)
        let next = PadSpot(
            hue: min(PadGeometry.columns, max(0, base.hue + dh)),
            strength: min(PadGeometry.rows, max(0, base.strength + ds))
        )
        guard next != base else { return [] }
        setTarget(next)
        mode = .settle
        driving = true
        wake()
        return [.commit(next)]
    }

    /// `hue`/`strength` changed from outside (space switch, Cancel).
    func external(_ spot: PadSpot) {
        guard configured, !isInteracting, spot != target else { return }
        follow(spot)
    }

    func hover(at p: CGPoint?) {
        hovering = p.map { hypot(Double($0.x) - x, Double($0.y) - y) <= PadGeometry.radius + 5 } ?? false
        guard ptr == nil else { return }
        let t = hovering ? 0.5 : 0
        if t != liftT { liftT = t; wake() }
    }

    func hello() {
        guard !reduced, ptr == nil, mode != .flick else { return }
        hop(8, 0.32)
        vdq += 1.2
        wake()
    }

    // ---- frame ----
    func tick(_ date: Date) -> [PadEvent] {
        guard running else { return [] }
        var dt = lastTick.map { date.timeIntervalSince($0) } ?? (1.0 / 120)
        lastTick = date
        dt = min(0.05, max(0, dt))
        var events: [PadEvent] = []
        while dt > 1e-6 {
            let d = min(1.0 / 240, dt)
            integrate(d, &events)
            dt -= d
        }
        publish()

        let userDriving = (ptr.map { !$0.cancelled } ?? false) || mode == .flick
        if userDriving {
            let hs = geo.toHS(x, y)
            events.append(.live(hs.hue, hs.strength))
            let n = geo.nearest(x, y)
            if let last = detent {
                if n.hue != last.hue { events.append(.hueDetent) }
                if n.strength != last.strength { events.append(.strengthDetent) }
            }
            detent = n
        }
        if driving {
            let n = mode == .settle ? target : geo.nearest(x, y)
            if near != n { near = n }
        }
        if atRest() { finish() }
        return events
    }

    private func integrate(_ d: Double, _ events: inout [PadEvent]) {
        if mode == .flick {
            x += vx * d
            y += vy * d
            let fr = exp(-2.8 * d)
            vx *= fr
            vy *= fr
            if x < geo.loX || x > geo.hiX { x = padClamp(x, geo.loX, geo.hiX); vdp -= abs(vx) * 0.0045; vx *= -0.55 }
            if y < geo.loY || y > geo.hiY { y = padClamp(y, geo.loY, geo.hiY); vdp += abs(vy) * 0.0045; vy *= -0.55 }
            if hypot(vx, vy) < 160 {
                setTarget(geo.nearest(x + vx * 0.12, y + vy * 0.12))
                mode = .settle
                events.append(.commit(target))
            }
        } else {
            if mode == .drag, let q = ptr {
                tx = rub(q.x - q.ox, geo.loX, geo.hiX)
                ty = rub(q.y - q.oy, geo.loY, geo.hiY)
            }
            let p = spring(mode)
            vx += (-p.k * (x - tx) - p.c * vx) * d
            vy += (-p.k * (y - ty) - p.c * vy) * d
            x += vx * d
            y += vy * d
        }
        if !reduced {
            // Squash & stretch follows velocity through an underdamped spring, so it wobbles when it stops.
            let sp = hypot(vx, vy), m = min(0.26, sp * 0.0003), th = atan2(vy, vx)
            let tp = m * cos(2 * th), tq = m * sin(2 * th)
            vdp += (-380 * (dp - tp) - 8.5 * vdp) * d
            vdq += (-380 * (dq - tq) - 8.5 * vdq) * d
            dp += vdp * d
            dq += vdq * d
            let dm = hypot(dp, dq)
            if dm > 0.36 { dp *= 0.36 / dm; dq *= 0.36 / dm }
        } else {
            dp = 0; dq = 0; vdp = 0; vdq = 0
        }
        vlift += (-320 * (lift - liftT) - (reduced ? Self.crit(320) : 22) * vlift) * d
        lift += vlift * d
        if var h = hopState {
            h.t += d
            let f = h.t / h.dur
            if f >= 1 { z = 0; hopState = nil; vdp += reduced ? 0 : 2.4 } else { z = h.h * sin(.pi * f); hopState = h }
        }
        // Trail droplet (method d): lags behind the drop on a softer spring, kept within reach.
        let cy = y - z
        if reduced {
            trailX = x; trailY = cy; tvx = 0; tvy = 0
        } else {
            tvx += (-170 * (trailX - x) - 16 * tvx) * d
            tvy += (-170 * (trailY - cy) - 16 * tvy) * d
            trailX += tvx * d
            trailY += tvy * d
            let ddx = trailX - x, ddy = trailY - cy, dist = hypot(ddx, ddy), reach = PadGeometry.radius * 2.2
            if dist > reach { trailX = x + ddx / dist * reach; trailY = cy + ddy / dist * reach }
        }
    }

    private func atRest() -> Bool {
        if mode == .drag || mode == .flick || hopState != nil || ptr != nil { return false }
        return abs(x - tx) < 0.05 && abs(y - ty) < 0.05 && hypot(vx, vy) < 1.5
            && abs(dp) < 0.002 && abs(dq) < 0.002 && abs(vdp) < 0.03 && abs(vdq) < 0.03
            && abs(lift - liftT) < 0.003 && abs(vlift) < 0.02
            && abs(trailX - x) < 0.05 && abs(trailY - y) < 0.05 && hypot(tvx, tvy) < 1.5
    }

    private func finish() {
        snap()
        lift = liftT
        vlift = 0
        driving = false
        if near != nil { near = nil }
        mode = .settle
        publish()
        running = false
        lastTick = nil
    }

    // ---- helpers ----
    private func snap() {
        x = tx; y = ty; vx = 0; vy = 0
        dp = 0; dq = 0; vdp = 0; vdq = 0
        trailX = tx; trailY = ty; tvx = 0; tvy = 0
    }

    private func setTarget(_ spot: PadSpot) {
        tx = geo.spotX(spot.hue)
        ty = geo.spotY(spot.strength)
        if target != spot { target = spot }
    }

    private func follow(_ spot: PadSpot) {
        driving = false
        if near != nil { near = nil }
        mode = .follow
        setTarget(spot)
        if hypot(x - tx, y - ty) > 2 { hop(9, 0.36) }
        wake()
    }

    private func hop(_ h: Double, _ dur: Double) {
        if !reduced { hopState = Hop(t: 0, dur: dur, h: h) }
    }

    private func wake() {
        if !running {
            lastTick = nil
            running = true
        }
    }

    private func publish() {
        let hs = geo.toHS(x, y)
        frame = DropFrame(
            x: x, y: y, z: z,
            sc: 1 + 0.075 * lift + 0.012 * z,
            dp: dp, dq: dq,
            up: lift * 2.5 + z,
            trailX: trailX, trailY: trailY,
            hue: hs.hue, strength: hs.strength
        )
    }

    /// Rubber band past the outer spots (blob.html `rub`).
    private func rub(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        if v < lo { return lo - 12 * (lo - v) / (lo - v + 24) }
        if v > hi { return hi + 12 * (v - hi) / (v - hi + 24) }
        return v
    }
}

// MARK: - Pad surface

/// The rainbow field, sampled from `swatch` at half resolution (as blob.html does) and drawn
/// smoothed. Equatable on size + appearance so the per-frame re-renders of the pad skip it.
/// If the palette changes for another reason, give the pad a new `.id`.
private struct PadField: View, Equatable {
    let size: CGSize
    let scheme: ColorScheme
    let swatch: (Double, Double) -> Color

    static func == (l: PadField, r: PadField) -> Bool { l.size == r.size && l.scheme == r.scheme }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let ink: Color = scheme == .dark ? .white.opacity(0.09) : Color(white: 0.08).opacity(0.16)
        ZStack {
            if let image = render() {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ink, lineWidth: 0.5))
        .allowsHitTesting(false)
    }

    private func render() -> CGImage? {
        guard size.width >= 2, size.height >= 2 else { return nil }
        let w = Int(size.width / 2), h = Int(size.height / 2)
        let geo = PadGeometry(width: size.width, height: size.height)
        var env = EnvironmentValues()
        env.colorScheme = scheme
        var px = [UInt8](repeating: 255, count: w * h * 4)
        func byte(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255 + 0.5) }
        for j in 0..<h {
            for i in 0..<w {
                let hs = geo.toHS((Double(i) + 0.5) / Double(w) * size.width, (Double(j) + 0.5) / Double(h) * size.height)
                let c = swatch(hs.hue, hs.strength).resolve(in: env)
                let o = (j * w + i) * 4
                px[o] = byte(c.red)
                px[o + 1] = byte(c.green)
                px[o + 2] = byte(c.blue)
                px[o + 3] = 255
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return px.withUnsafeMutableBytes { buf -> CGImage? in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
    }
}

/// The 9 x 4 sweet-spot dots; the bottom row (no colour) as tiny rings. The one the drop will land
/// on grows while you drive it.
private struct PadDots: View {
    let model: PadModel
    let size: CGSize
    let scheme: ColorScheme

    var body: some View {
        let near = model.near
        let geo = PadGeometry(width: size.width, height: size.height)
        let ink: Color = scheme == .dark ? .white : Color(white: 0.08)
        ZStack(alignment: .topLeading) {
            ForEach(0..<((PadGeometry.rows + 1) * (PadGeometry.columns + 1)), id: \.self) { index in
                let s = index / (PadGeometry.columns + 1), i = index % (PadGeometry.columns + 1)
                let isNear = near == PadSpot(hue: i, strength: s)
                Group {
                    if s == 0 {
                        Circle()
                            .strokeBorder(ink.opacity(isNear ? 0.45 : 0.22), lineWidth: isNear ? 0.8 : 1)
                            .frame(width: 5, height: 5)
                    } else {
                        Circle()
                            .fill(ink.opacity(isNear ? 0.38 : 0.2))
                            .frame(width: 4, height: 4)
                    }
                }
                .scaleEffect(isNear ? 1.9 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.55), value: isNear)
                .position(x: geo.spotX(i), y: geo.spotY(s))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - The drop

/// Owns the clock. `TimelineView(.animation)` is paused whenever the model is at rest, so nothing
/// runs per frame when the drop is still.
private struct PadDropLayer: View {
    let model: PadModel
    let style: SpaceColourPad.Style
    let scheme: ColorScheme
    let accent: (Double) -> Color
    let showRing: Bool
    let onEvents: ([PadEvent]) -> Void

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !model.running)) { context in
            DropView(frame: model.frame, size: CGSize(width: model.geo.width, height: model.geo.height),
                     style: style, scheme: scheme, accent: accent, showRing: showRing)
                .onChange(of: context.date) { _, date in
                    onEvents(model.tick(date))
                }
        }
        // Interactive glass needs hits; otherwise the drop is purely visual and the pad takes them.
        .allowsHitTesting(style.interactive)
    }
}

private struct DropView: View {
    let frame: DropFrame
    let size: CGSize
    let style: SpaceColourPad.Style
    let scheme: ColorScheme
    let accent: (Double) -> Color
    let showRing: Bool

    private var dark: Bool { scheme == .dark }
    private var r: Double { PadGeometry.radius }

    var body: some View {
        let hueColour = accent(padClamp(frame.hue, 0, Double(PadGeometry.columns)))
        ZStack(alignment: .topLeading) {
            shadow
            caustic(hueColour)
            drop(hueColour)
            if showRing {
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
                    .frame(width: 2 * r * frame.sc + 8, height: 2 * r * frame.sc + 8)
                    .position(frame.centre)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func drop(_ hueColour: Color) -> some View {
        if style.squash == .fallback {
            JellyDrop(frame: frame, colour: hueColour, dark: dark)
        } else if #available(macOS 26, *) {
            GlassDrop(frame: frame, size: size, style: style, tint: glassTint(hueColour))
        } else {
            JellyDrop(frame: frame, colour: hueColour, dark: dark)
        }
    }

    /// "A whisper of the hue": more as strength rises, nothing at none.
    private func glassTint(_ hueColour: Color) -> Color? {
        guard style.tinted else { return nil }
        let t = padClamp(frame.strength, 0, 1), k = padClamp((frame.strength - 1) / 2, 0, 1)
        let amount = (dark ? 0.16 + 0.14 * k : 0.22 + 0.16 * k) * t
        return amount > 0.005 ? hueColour.opacity(amount) : nil
    }

    /// Contact shadow under the drop: drifts down, grows and fades as it lifts.
    private var shadow: some View {
        let up = frame.up
        let a0 = dark ? 0.42 : 0.26, a1 = dark ? 0.18 : 0.10
        return Circle()
            .fill(RadialGradient(stops: [
                .init(color: .black.opacity(a0), location: 0),
                .init(color: .black.opacity(a1), location: 0.55),
                .init(color: .black.opacity(0), location: 1),
            ], center: .center, startRadius: 0, endRadius: 14))
            .frame(width: 28, height: 28)
            .scaleEffect(1 + up * 0.028)
            .opacity(max(0, 1 - up * 0.035))
            .position(x: frame.x, y: frame.y + 7 + up * 0.35)
    }

    /// The light the drop focuses lands on the pad down-right, in the colour it's on.
    private func caustic(_ hueColour: Color) -> some View {
        let up = frame.up
        let blur = 1 + up * 0.08
        let alpha = (dark ? 0.34 : 0.4) / blur
        let radius = 9.5 * blur
        let cc = hueColour.mix(with: .white, by: dark ? 0.3 : 0.35)
        return Circle()
            .fill(RadialGradient(stops: [
                .init(color: cc.opacity(alpha), location: 0),
                .init(color: cc.opacity(alpha * 0.6), location: 0.35),
                .init(color: cc.opacity(0), location: 1),
            ], center: .center, startRadius: 0, endRadius: radius))
            .frame(width: 2 * radius, height: 2 * radius)
            .scaleEffect(x: 1, y: 0.62)
            .rotationEffect(.radians(0.62))
            .blendMode(dark ? .screen : .normal)
            .position(x: frame.x + r * 0.5 + up * 0.5, y: frame.y - frame.z + r * 0.78 + up * 0.75)
    }
}

/// The squashed drop outline: the unit circle (radius r) through blob.html's matrix, centred in rect.
/// Used as the glass *shape* in methods c and d, so no transform is applied to the glass itself.
private struct SquashedDisc: Shape {
    var a: Double, c: Double, d: Double, radius: Double

    func path(in rect: CGRect) -> Path {
        let m = CGAffineTransform(a: a, b: c, c: c, d: d, tx: rect.midX, ty: rect.midY)
        return Path(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)).applying(m)
    }
}

/// Real Liquid Glass, four ways to make it squash. What we know / suspect (unverified by eye):
///
/// a. scale: `rotationEffect(-phi).scaleEffect(x:y:).rotationEffect(phi)` on a glass circle.
///    These are render-time transforms on the layer, not relayout. SwiftUI's own `.interactive()`
///    glass scales on press, so the compositor does honour scale on glass. Expect the *rendered*
///    glass to be stretched: rim highlight and edge refraction get thicker along the long axis,
///    thinner along the short one, like a squished photo of a lens. Cheapest per frame (no shape
///    rebuild). Risk: the backdrop sample may be taken in the unscaled bounds, so refraction near
///    the stretched ends could look slightly off or clipped.
/// b. matrix: the same transform as one `transformEffect(CGAffineTransform)` built from blob.html's
///    symmetric 2x2. Mathematically identical to (a); differs only in which modifier path the
///    renderer takes. If (a) and (b) look the same, (b) is the simpler port of the mockup.
/// c. shape (default): no transform at all. The glass is given the squashed ellipse as its shape
///    (`SquashedDisc`), rebuilt every frame in a fixed, unrotated box. The glass re-renders at the
///    real geometry, so the rim stays an even width and the light direction stays put on screen
///    (a rotated glass view might spin its highlight). Cost: a new shape per frame while moving;
///    for a ~50pt view that should be negligible, and the clock is paused at rest. Risk: glass may
///    light an arbitrary path less nicely than a built-in Circle/Capsule.
/// d. trail: (c) plus a small glass droplet on its own lagging spring, both in a
///    `GlassEffectContainer(spacing:)` so they blend like metaballs when close and split when the
///    drop moves fast. Liquid, but busier; at rest the droplet hides inside the drop.
@available(macOS 26, *)
private struct GlassDrop: View {
    let frame: DropFrame
    let size: CGSize
    let style: SpaceColourPad.Style
    let tint: Color?

    private var r: Double { PadGeometry.radius }
    /// Fixed box for the shape methods: big enough for the most stretched, lifted, hopping drop
    /// (1.36 squash x ~1.24 lift scale).
    private var box: Double { 2 * r * 1.8 }

    private var glass: Glass {
        var g: Glass = style.glass == .clear ? .clear : .regular
        if let tint { g = g.tint(tint) }
        if style.interactive { g = g.interactive() }
        return g
    }

    var body: some View {
        switch style.squash {
        case .scale:
            Color.clear
                .frame(width: 2 * r, height: 2 * r)
                .glassEffect(glass, in: Circle())
                .rotationEffect(.radians(-frame.phi))
                .scaleEffect(x: frame.major, y: frame.minor)
                .rotationEffect(.radians(frame.phi))
                .position(frame.centre)
        case .matrix:
            Color.clear
                .frame(width: 2 * r, height: 2 * r)
                .glassEffect(glass, in: Circle())
                .transformEffect(frame.centredTransform(side: 2 * r))
                .position(frame.centre)
        case .shape, .fallback:
            shapeDrop
        case .trail:
            GlassEffectContainer(spacing: 18) {
                ZStack(alignment: .topLeading) {
                    shapeDrop
                    let tr = r * 0.5
                    Color.clear
                        .frame(width: 2 * tr, height: 2 * tr)
                        .glassEffect(glass, in: Circle())
                        .position(x: frame.trailX, y: frame.trailY)
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
        }
    }

    private var shapeDrop: some View {
        Color.clear
            .frame(width: box, height: box)
            .glassEffect(glass, in: SquashedDisc(a: frame.a, c: frame.c, d: frame.d, radius: r))
            .position(frame.centre)
    }
}

/// Fallback drop for macOS 15 (no `.glassEffect`): blob.html's jelly, painted, squashed by the
/// same matrix through `transformEffect`.
private struct JellyDrop: View {
    let frame: DropFrame
    let colour: Color
    let dark: Bool

    var body: some View {
        let side = 2 * PadGeometry.radius
        let t = padClamp(frame.strength, 0, 1), k = padClamp((frame.strength - 1) / 2, 0, 1)
        let neutral = dark ? Color(red: 112 / 255, green: 114 / 255, blue: 120 / 255)
                           : Color(red: 250 / 255, green: 250 / 255, blue: 252 / 255)
        ZStack {
            Circle().fill(neutral)
            Circle().fill(colour).opacity(t * (0.52 + 0.4 * k))
            Circle().fill(RadialGradient(colors: [.white.opacity(0.42), .white.opacity(0)],
                                         center: UnitPoint(x: 0.32, y: 0.26), startRadius: 0, endRadius: side * 0.47))
            Circle().fill(RadialGradient(colors: [.black.opacity(0.2), .black.opacity(0)],
                                         center: UnitPoint(x: 0.66, y: 0.86), startRadius: 0, endRadius: side * 0.5))
            Ellipse()
                .fill(RadialGradient(stops: [
                    .init(color: .white.opacity(0.95), location: 0),
                    .init(color: .white.opacity(0.55), location: 0.45),
                    .init(color: .white.opacity(0), location: 1),
                ], center: .center, startRadius: 0, endRadius: 5.5))
                .frame(width: 11, height: 7)
                .rotationEffect(.degrees(-28))
                .position(x: 11.5, y: 8)
            Circle().strokeBorder(.black.opacity(0.22), lineWidth: 0.5)
        }
        .frame(width: side, height: side)
        .transformEffect(frame.centredTransform(side: side))
        .position(frame.centre)
    }
}
