import AppKit
import CoreGraphics
import Observation
import SwiftUI

// MARK: - SpaceColourPad
//
// The space-colour picker: a 2D pad with one draggable drop.
//   sideways = hue (9 colours, 0...8), up = stronger (0 none, 1 Subtle, 2 Medium, 3 Strong).
// Drag it, flick it, or click empty pad to make it hop there. On release it snaps to the
// nearest of the 9 x 4 spots.
//
// Ported from internal-docs/2026-11-09-themes-and-settings/space-themes/fidget/blob.html
// (interaction + physics). The drop is a flat, solid disc in the colour under it with a white
// ring and a contact shadow (`SolidDrop`); it still squashes with the jelly. It used to be a Metal
// glass lens (SpaceColourPadGlass.metal, `ensoColourPadGlass`), which is no longer drawn.
//
// Portable on purpose: no Enso types. Everything except `SpaceColourPad` itself is `private` to
// this file. The Edit Space sheet (SidebarView.swift, `SpaceEditorSheet`) wires it to the store.
//
// CANONICAL COPY. The lab copy at lab/Sources/EnsoLab/Shared/SpaceColourPad.swift is frozen and
// no longer tracks this one: it still has the real `.glassEffect` drop variants (a-d), the
// trail droplet, the `Style` switches and the painted macOS 15 fallback, all removed here in
// favour of the shader drop. Port behaviour changes here; don't sync the lab copy back.
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
    static let defaultHueNames = ["Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Green", "Teal", "Graphite"]
    static let strengthNames = ["No colour", "Subtle", "Medium", "Strong"]

    var hue: Double
    var strength: Double
    /// Pad colour at any continuous point. Sampled once per size/appearance into a bitmap.
    var swatch: (_ hue: Double, _ strength: Double) -> Color
    /// The vivid colour of a hue. Unused by the solid drop (it was the glass tint); kept for callers.
    var accent: ((_ hue: Double) -> Color)?
    var hueNames: [String]
    var onChange: (_ hue: Double, _ strength: Double) -> Void
    var onCommit: (_ hue: Int, _ strength: Int) -> Void

    init(
        hue: Double,
        strength: Double,
        swatch: @escaping (_ hue: Double, _ strength: Double) -> Color,
        accent: ((_ hue: Double) -> Color)? = nil,
        hueNames: [String] = SpaceColourPad.defaultHueNames,
        onChange: @escaping (_ hue: Double, _ strength: Double) -> Void,
        onCommit: @escaping (_ hue: Int, _ strength: Int) -> Void
    ) {
        self.hue = hue
        self.strength = strength
        self.swatch = swatch
        self.accent = accent
        self.hueNames = hueNames
        self.onChange = onChange
        self.onCommit = onCommit
    }

    @State private var model = PadModel()
    @State private var pushedCursor: NSCursor?
    @FocusState private var focused: Bool
    @GestureState private var pressing = false
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.colorScheme) private var scheme

    private var propSpot: PadSpot {
        PadSpot(
            hue: Int(padClamp(hue.rounded(), 0, Double(PadGeometry.columns))),
            strength: Int(padClamp(strength.rounded(), 0, Double(PadGeometry.rows)))
        )
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                PadSurface(
                    model: model,
                    size: geo.size,
                    image: model.fieldImage(size: geo.size, scheme: scheme, swatch: swatch),
                    scheme: scheme,
                    swatch: swatch,
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
                updateCursor()
            }
            .onAppear { model.configure(size: geo.size, spot: propSpot, reduced: reduced) }
            .onChange(of: geo.size) { _, size in model.resize(size) }
            .onDisappear { setCursor(nil) }
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
            updateCursor()
            return .handled
        }
        .onChange(of: pressing) { _, isPressing in
            // DragGesture can end without onEnded (e.g. the system cancels it). If the pointer is
            // still held once onEnded has had its chance, release it with no velocity.
            guard !isPressing else { return }
            Task {
                if model.hasPointer { dispatch(model.release(velocity: .zero, time: Date())) }
                updateCursor()
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
                    updateCursor()
                }
                model.move(to: value.location, time: value.time)
            }
            .onEnded { value in
                dispatch(model.release(velocity: value.velocity, time: value.time))
                model.hover(at: value.location)
                updateCursor()
            }
    }

    /// Open hand over the drop, closed hand while holding it, the usual cursor elsewhere.
    private func updateCursor() {
        if model.isGrabbingDrop { setCursor(.closedHand) }
        else if model.isHoveringDrop && !model.hasPointer { setCursor(.openHand) }
        else if !model.hasPointer { setCursor(nil) }
    }

    private func setCursor(_ cursor: NSCursor?) {
        guard cursor !== pushedCursor else { return }
        if pushedCursor != nil { NSCursor.pop() }
        cursor?.push()
        pushedCursor = cursor
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

nonisolated private func padClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

nonisolated private struct PadSpot: Equatable, Sendable {
    var hue: Int
    var strength: Int
}

/// blob.html's pad maths. Points, y down. Margins are to the outer sweet spots.
nonisolated private struct PadGeometry: Sendable {
    static let columns = 8          // hues 0...8
    static let rows = 3             // strength 0...3
    static let marginX = 20.0       // MX
    static let marginY = 19.0       // MY
    static let radius = 12.0        // the drop's radius at rest (blob.html BR was 15)

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
nonisolated private struct DropFrame: Equatable, Sendable {
    var x = 0.0, y = 0.0, z = 0.0       // centre on the pad, hop height
    var sc = 1.0                        // lift scale
    var dp = 0.0, dq = 0.0              // traceless squash tensor [[dp, dq], [dq, -dp]]
    var up = 0.0                        // how far it's "off" the pad (shadow)
    var hue = 0.0, strength = 0.0       // continuous, at the drop's position

    var centre: CGPoint { CGPoint(x: x, y: y - z) }
    /// The full matrix sc * (I + T), as blob.html's CSS `matrix(a, c, c, d, 0, 0)`.
    var a: Double { sc * (1 + dp) }
    var c: Double { sc * dq }
    var d: Double { sc * (1 - dp) }
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
    @ObservationIgnored private var mode: Mode = .settle
    @ObservationIgnored private var ptr: Pointer?
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var driving = false       // user-initiated motion: show the near dot
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var detent: PadSpot?
    @ObservationIgnored private var origin: PadSpot?
    @ObservationIgnored private var configured = false

    @ObservationIgnored private var fieldCache: (size: CGSize, scheme: ColorScheme, image: CGImage?)?
    @ObservationIgnored private var dotCache: (scheme: ColorScheme, tints: [Color])?

    /// The pad field, rendered once per size and appearance (the swatch is assumed to be a pure
    /// function of hue, strength and appearance; give the pad a new `.id` if the palette changes).
    func fieldImage(size: CGSize, scheme: ColorScheme, swatch: (Double, Double) -> Color) -> CGImage? {
        if let cache = fieldCache, cache.size == size, cache.scheme == scheme { return cache.image }
        let image = renderPadField(size: size, scheme: scheme, swatch: swatch)
        fieldCache = (size, scheme, image)
        return image
    }

    /// The 36 sweet-spot dot colours, resolved once per appearance (same purity assumption as
    /// `fieldImage`). Indexed as `PadDots` lays them out: `strength * (columns + 1) + hue`.
    func dotTints(scheme: ColorScheme, swatch: (Double, Double) -> Color) -> [Color] {
        if let cache = dotCache, cache.scheme == scheme { return cache.tints }
        let tints = renderDotTints(scheme: scheme, swatch: swatch)
        dotCache = (scheme, tints)
        return tints
    }

    var hasPointer: Bool { ptr != nil }
    /// The pointer is over the drop (not pressed).
    var isHoveringDrop: Bool { hovering }
    /// The user is holding the drop itself (not a click on empty pad).
    var isGrabbingDrop: Bool { ptr.map { $0.onBlob && !$0.cancelled } ?? false }
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
    }

    private func atRest() -> Bool {
        if mode == .drag || mode == .flick || hopState != nil || ptr != nil { return false }
        return abs(x - tx) < 0.05 && abs(y - ty) < 0.05 && hypot(vx, vy) < 1.5
            && abs(dp) < 0.002 && abs(dq) < 0.002 && abs(vdp) < 0.03 && abs(vdq) < 0.03
            && abs(lift - liftT) < 0.003 && abs(vlift) < 0.02
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

    /// How much of the simulated squash the drop shows (1 = blob.html's full jelly).
    private static let squashScale = 0.7

    private func publish() {
        let hs = geo.toHS(x, y)
        frame = DropFrame(
            x: x, y: y, z: z,
            sc: 1 + 0.075 * lift + 0.012 * z,
            dp: dp * Self.squashScale, dq: dq * Self.squashScale,
            up: lift * 2.5 + z,
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

/// The colour field: a bitmap the model renders from `swatch` (see `PadModel.fieldImage`), drawn
/// smoothed under a hairline frame.
private struct PadField: View {
    let size: CGSize
    let image: CGImage?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let ink: Color = scheme == .dark ? .white.opacity(0.09) : Color(white: 0.08).opacity(0.16)
        ZStack {
            if let image {
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
}

/// How much more saturated the pad field is drawn than `swatch` (the real tint). 1 = as is.
private let fieldSaturation: Float = 1.35

/// Samples `swatch` at half resolution, as blob.html does; the image is drawn smoothed.
private func renderPadField(size: CGSize, scheme: ColorScheme, swatch: (Double, Double) -> Color) -> CGImage? {
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
            // Display only: the pad shows the colours a bit richer than the sidebar tint they
            // pick, so the field reads clearly. Greys stay grey (luma-preserving).
            let l = 0.3 * c.red + 0.59 * c.green + 0.11 * c.blue
            func rich(_ v: Float) -> Float { l + (v - l) * fieldSaturation }
            let o = (j * w + i) * 4
            px[o] = byte(rich(c.red))
            px[o + 1] = byte(rich(c.green))
            px[o + 2] = byte(rich(c.blue))
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

/// The dot colours for one appearance: the pad colour at each spot, saturated a touch and pushed
/// toward black (light) or white (dark). See `PadModel.dotTints` for the index order.
private func renderDotTints(scheme: ColorScheme, swatch: (Double, Double) -> Color) -> [Color] {
    var env = EnvironmentValues()
    env.colorScheme = scheme
    let dark = scheme == .dark
    let toward: Float = dark ? 1 : 0, amount: Float = dark ? 0.3 : 0.35
    return (0..<((PadGeometry.rows + 1) * (PadGeometry.columns + 1))).map { index in
        let s = index / (PadGeometry.columns + 1), i = index % (PadGeometry.columns + 1)
        let c = swatch(Double(i), Double(s)).resolve(in: env)
        let l = 0.3 * c.red + 0.59 * c.green + 0.11 * c.blue
        func channel(_ v: Float) -> Double {
            let sat = min(1, max(0, l + (v - l) * 1.8))
            return Double(sat + (toward - sat) * amount)
        }
        return Color(.sRGB, red: channel(c.red), green: channel(c.green), blue: channel(c.blue))
    }
}

/// The 9 x 4 sweet-spot dots, all filled and tinted: a deeper shade of the pad colour under each dot
/// (lighter in dark appearance), so they read as part of the field rather than grey specks on it.
/// The bottom row (no colour) comes out neutral grey. The one the drop will land on grows
/// while you drive it.
///
/// Not inside the drop's clock: it re-evaluates only when `model.near` changes (a few times per
/// drag), and the colours come from the model's per-appearance cache.
private struct PadDots: View {
    let model: PadModel
    let size: CGSize
    let scheme: ColorScheme
    let swatch: (Double, Double) -> Color

    var body: some View {
        let near = model.near
        let geo = PadGeometry(width: size.width, height: size.height)
        let tints = model.dotTints(scheme: scheme, swatch: swatch)
        ZStack(alignment: .topLeading) {
            ForEach(0..<((PadGeometry.rows + 1) * (PadGeometry.columns + 1)), id: \.self) { index in
                let s = index / (PadGeometry.columns + 1), i = index % (PadGeometry.columns + 1)
                let isNear = near == PadSpot(hue: i, strength: s)
                Circle()
                    .fill(tints[index].opacity(isNear ? 0.95 : 0.75))
                    .frame(width: 4, height: 4)
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

/// The pad and its drop. Owns the clock: `TimelineView(.animation)` is paused whenever the model
/// is at rest, so nothing runs per frame when the drop is still.
///
/// The drop is a flat, solid disc in the colour under it, with a white ring and a contact shadow.
/// It still squashes with the jelly (the model's matrix is applied to its outline).
///
/// Only the drop is inside the clock. The field is the model's cached bitmap and the dots follow
/// `model.near` through their own observation, so a drop frame re-evaluates and redraws the drop
/// alone, not 36 dots and the field with it.
private struct PadSurface: View {
    let model: PadModel
    let size: CGSize
    let image: CGImage?
    let scheme: ColorScheme
    let swatch: (Double, Double) -> Color
    let showRing: Bool
    let onEvents: ([PadEvent]) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            PadField(size: size, image: image)
            PadDots(model: model, size: size, scheme: scheme, swatch: swatch)
            TimelineView(.animation(minimumInterval: nil, paused: !model.running)) { context in
                let frame = model.frame
                let fill = swatch(
                    padClamp(frame.hue, 0, Double(PadGeometry.columns)),
                    padClamp(frame.strength, 0, Double(PadGeometry.rows))
                )
                SolidDrop(frame: frame, size: size, dark: scheme == .dark, fill: fill, showRing: showRing)
                    .onChange(of: context.date) { _, date in
                        onEvents(model.tick(date))
                    }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Purely visual: the pad's own gesture takes every hit.
        .allowsHitTesting(false)
    }
}

/// The drop itself: contact shadow, solid fill, white ring, and the keyboard focus ring.
private struct SolidDrop: View {
    let frame: DropFrame
    let size: CGSize
    let dark: Bool
    let fill: Color
    let showRing: Bool

    @Environment(\.self) private var environment

    private var r: Double { PadGeometry.radius }

    /// The pad colour under the drop, pushed a little more saturated so the drop reads as the pick.
    private var richFill: Color {
        let c = fill.resolve(in: environment)
        let l = 0.3 * c.red + 0.59 * c.green + 0.11 * c.blue
        func channel(_ v: Float) -> Double { Double(min(1, max(0, l + (v - l) * fieldSaturation * 1.35))) }
        return Color(.sRGB, red: channel(c.red), green: channel(c.green), blue: channel(c.blue))
    }

    /// A faint glass sheen: light from the top fading out by the middle of the drop.
    private var sheen: LinearGradient {
        let w = max(1, size.width), h = max(1, size.height)
        let c = frame.centre, reach = r * frame.sc
        return LinearGradient(
            stops: [
                .init(color: .white.opacity(dark ? 0.16 : 0.24), location: 0),
                .init(color: .white.opacity(0), location: 1),
            ],
            startPoint: UnitPoint(x: (c.x - reach * 0.3) / w, y: (c.y - reach) / h),
            endPoint: UnitPoint(x: c.x / w, y: (c.y + reach * 0.1) / h)
        )
    }

    var body: some View {
        let shape = DropShape(centre: frame.centre, a: frame.a, c: frame.c, d: frame.d, radius: r)
        ZStack(alignment: .topLeading) {
            shadow
            shape.fill(richFill)
            shape.fill(sheen)
            shape.stroke(Color.white.opacity(dark ? 0.92 : 1), lineWidth: 2.5)
            DropShape(centre: frame.centre, a: frame.a, c: frame.c, d: frame.d, radius: r + 1.25)
                .stroke(Color.black.opacity(dark ? 0.35 : 0.14), lineWidth: 0.5)
            if showRing {
                Circle()
                    .strokeBorder(Color.accentColor.opacity(0.85), lineWidth: 2)
                    .frame(width: 2 * r * frame.sc + 10, height: 2 * r * frame.sc + 10)
                    .position(frame.centre)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
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
            ], center: .center, startRadius: 0, endRadius: 16))
            .frame(width: 32, height: 32)
            .scaleEffect(1 + up * 0.028)
            .opacity(max(0, 1 - up * 0.035))
            .position(x: frame.x, y: frame.y + 3 + up * 0.35)
    }
}

/// The squashed drop: the circle of `radius` through blob.html's matrix, at `centre`.
nonisolated private struct DropShape: Shape {
    var centre: CGPoint
    var a: Double, c: Double, d: Double, radius: Double

    func path(in rect: CGRect) -> Path {
        let m = CGAffineTransform(a: a, b: c, c: c, d: d, tx: centre.x, ty: centre.y)
        return Path(ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius)).applying(m)
    }
}
