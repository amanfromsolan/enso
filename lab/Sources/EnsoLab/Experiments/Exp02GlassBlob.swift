import SwiftUI

/// Experiment 02: the space-colour pad with a real Liquid Glass drop, staged like the Edit Space
/// sheet over the fake Enso window. The bar on top switches how the glass squashes so the
/// methods can be compared by eye; the swatch on the left is a stand-in for the window tint and
/// follows `onChange` live (no animation) and springs on `onCommit`, as Enso would.
struct Exp02GlassBlob: View {
    @State private var style = SpaceColourPad.Style()
    @State private var saved = LabSpot(hue: 0, strength: 2)       // what Cancel goes back to
    @State private var value = LabSpot(hue: 0, strength: 2)       // committed, fed to the pad
    @State private var live = LabLive(hue: 0, strength: 2)        // drives the tint preview
    @State private var name = "Personal"

    var body: some View {
        ZStack {
            EnsoBackdrop(terminal: .filled)
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: 22) {
                controls
                HStack(alignment: .center, spacing: 32) {
                    LabTintPreview(hue: live.hue, strength: live.strength)
                    sheet
                }
                readout
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Squash", selection: $style.squash) {
                Text("a  Scale").tag(SpaceColourPad.Style.Squash.scale)
                Text("b  Matrix").tag(SpaceColourPad.Style.Squash.matrix)
                Text("c  Shape").tag(SpaceColourPad.Style.Squash.shape)
                Text("d  Trail").tag(SpaceColourPad.Style.Squash.trail)
                Text("Fallback").tag(SpaceColourPad.Style.Squash.fallback)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Picker("Glass", selection: $style.glass) {
                Text("Clear").tag(SpaceColourPad.Style.GlassVariant.clear)
                Text("Regular").tag(SpaceColourPad.Style.GlassVariant.regular)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Toggle("Tint", isOn: $style.tinted)
            Toggle("Interactive", isOn: $style.interactive)
            Toggle("Reduce motion", isOn: $style.forceReducedMotion)
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(white: 0.13).opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .overlay(alignment: .bottom) {
            if !glassAvailable {
                Text("Glass needs macOS 26: every method shows the fallback drop")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.9))
                    .offset(y: 20)
            }
        }
    }

    private var glassAvailable: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    private var readout: some View {
        let names = SpaceColourPad.defaultHueNames
        let committed = value.strength == 0
            ? "No colour"
            : "\(names[value.hue]) · \(SpaceColourPad.strengthNames[value.strength])"
        return Text(String(format: "live %.2f · %.2f      committed %@", live.hue, live.strength, committed))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
    }

    // MARK: Sheet

    private var sheet: some View {
        VStack(spacing: 0) {
            LabSheetDisc(hue: live.hue, strength: live.strength)
                .padding(.top, 32)
                .padding(.bottom, 14)

            Text("Edit Space")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.bottom, 14)

            TextField("Name your space", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
                .frame(width: 292)

            SpaceColourPad(
                hue: Double(value.hue),
                strength: Double(value.strength),
                swatch: { h, s in LabSpaceColour.padColour(h, s).color },
                accent: { h in LabSpaceColour.accent(h).color },
                style: style,
                onChange: { h, s in
                    var t = Transaction(animation: nil)
                    t.disablesAnimations = true
                    withTransaction(t) { live = LabLive(hue: h, strength: s) }
                },
                onCommit: { h, s in
                    value = LabSpot(hue: h, strength: s)
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        live = LabLive(hue: Double(h), strength: Double(s))
                    }
                }
            )
            .frame(width: 292, height: 150)
            .padding(.top, 20)

            HStack(spacing: 8) {
                Button {
                    value = saved
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        live = LabLive(hue: Double(saved.hue), strength: Double(saved.strength))
                    }
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.09)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    saved = value
                } label: {
                    Label("Save", systemImage: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color(red: 10 / 255, green: 132 / 255, blue: 1)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .frame(width: 292)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
        .frame(width: 340)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(red: 42 / 255, green: 43 / 255, blue: 45 / 255))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.4), radius: 2, y: 2)
                .shadow(color: .black.opacity(0.55), radius: 35, y: 30)
        )
    }
}

// MARK: - Lab state

private struct LabSpot: Equatable {
    var hue: Int
    var strength: Int
}

private struct LabLive: Equatable {
    var hue: Double
    var strength: Double
}

// MARK: - Tint preview (stand-in for the window wash)

/// A mini window: the frost plus the live wash, with sidebar-ish rows so the 4.5:1 clamp is visible.
/// Animatable on hue/strength so `withAnimation` on commit springs the colour like Enso would.
private struct LabTintPreview: View, Animatable {
    var hue: Double
    var strength: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(hue, strength) }
        set { hue = newValue.first; strength = newValue.second }
    }

    var body: some View {
        let wash = LabSpaceColour.wash(hue, strength)
        let chip = LabSpaceColour.chip(over: wash)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) { c in
                    Circle().fill(c).frame(width: 10, height: 10)
                }
            }
            .padding(.bottom, 10)
            row("Portfolio", opacity: 0.82, weight: .medium)
            row("Website preview", opacity: 0.95, selected: chip.color)
            row("Claude Code", opacity: 0.62)
            row("Photos backup", opacity: 0.82, weight: .medium)
            row("Downloads", opacity: 0.62)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: 230, height: 300, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(wash.color)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.32), radius: 25, y: 22)
    }

    private func row(_ title: String, opacity: Double, weight: Font.Weight = .regular, selected: Color? = nil) -> some View {
        Text(title)
            .font(.system(size: 13, weight: weight))
            .foregroundStyle(.white.opacity(opacity))
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background {
                if let selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                }
            }
    }
}

/// The sheet's big icon disc, tinted the way blob.html's `paintDisc` does (dark appearance).
private struct LabSheetDisc: View, Animatable {
    var hue: Double
    var strength: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(hue, strength) }
        set { hue = newValue.first; strength = newValue.second }
    }

    var body: some View {
        let sf = SIMD3<Double>(42, 43, 45)
        let well = LabSpaceColour.mix(sf, .zero, 0.32)
        let t = labClamp(strength, 0, 1), k = labClamp((strength - 1) / 2, 0, 1)
        let tinted = LabSpaceColour.mix(sf, LabSpaceColour.accent(hue), 0.26 * (0.7 + 0.6 * k))
        let ink = LabSpaceColour.mix(sf, SIMD3(255, 255, 255), 0.9)
        Circle()
            .fill(LabSpaceColour.mix(well, tinted, t).color)
            .frame(width: 84, height: 84)
            .overlay(
                Image(systemName: "house.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(LabSpaceColour.mix(ink, LabSpaceColour.glyph(hue), t).color)
            )
    }
}

// MARK: - Colour model (blob.html, dark appearance only; the lab is always dark)

private func labClamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, v)) }

private extension SIMD3 where Scalar == Double {
    var color: Color { Color(.sRGB, red: x / 255, green: y / 255, blue: z / 255, opacity: 1) }
}

private enum LabSpaceColour {
    typealias RGB = SIMD3<Double>

    struct Hue {
        let sw: RGB          // the colour itself (macOS accent, dark)
        let glyph: RGB       // icon colour on the frost
        let c: RGB           // wash overlay colour
        let a: [Double]      // wash opacity for Subtle / Medium / Strong
    }

    static func hex(_ v: UInt32) -> RGB { RGB(Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255)) }

    static let frost = RGB(44, 45, 47)
    static let hues: [Hue] = [
        Hue(sw: hex(0x0a84ff), glyph: hex(0x8dbaff), c: RGB(46, 82, 150), a: [0.18, 0.34, 0.52]),   // blue
        Hue(sw: hex(0xbf5af2), glyph: hex(0xcfa0f5), c: RGB(88, 60, 148), a: [0.18, 0.34, 0.52]),   // purple
        Hue(sw: hex(0xff375f), glyph: hex(0xff9cb2), c: RGB(140, 50, 88), a: [0.16, 0.31, 0.48]),   // pink
        Hue(sw: hex(0xff453a), glyph: hex(0xff9a92), c: RGB(140, 48, 42), a: [0.16, 0.31, 0.48]),   // red
        Hue(sw: hex(0xff9f0a), glyph: hex(0xffbe6b), c: RGB(140, 80, 34), a: [0.16, 0.31, 0.48]),   // orange
        Hue(sw: hex(0xffd60a), glyph: hex(0xf3d26a), c: RGB(120, 102, 34), a: [0.16, 0.31, 0.48]),  // yellow
        Hue(sw: hex(0x30d158), glyph: hex(0x86dc9b), c: RGB(40, 108, 66), a: [0.18, 0.34, 0.50]),   // green
        Hue(sw: hex(0x40c8e0), glyph: hex(0x86d8e6), c: RGB(32, 104, 116), a: [0.18, 0.34, 0.50]),  // teal
        Hue(sw: hex(0x98989d), glyph: hex(0xc2c2c8), c: RGB(84, 88, 96), a: [0.18, 0.34, 0.50]),    // graphite
    ]

    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a * (1 - t) + b * t }

    /// Hue is clamped (not wrapped) to the pad's 0...8 so spring overshoot can't flash graphite to blue.
    static func parts(_ h: Double) -> (Hue, Hue, Double) {
        let h = labClamp(h, 0, Double(hues.count - 1))
        let i = min(Int(h.rounded(.down)), hues.count - 1)
        return (hues[i], hues[min(i + 1, hues.count - 1)], h - Double(i))
    }

    static func accent(_ h: Double) -> RGB { let (a, b, f) = parts(h); return mix(a.sw, b.sw, f) }
    static func glyph(_ h: Double) -> RGB { let (a, b, f) = parts(h); return mix(a.glyph, b.glyph, f) }

    // Contrast (WCAG), as blob.html.
    static func lum(_ c: RGB) -> Double {
        func f(_ v: Double) -> Double { let v = v / 255; return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.x) + 0.7152 * f(c.y) + 0.0722 * f(c.z)
    }
    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let x = lum(a), y = lum(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func chip(over wash: RGB) -> RGB { mix(wash, RGB(255, 255, 255), 0.13) }
    static func worstContrast(_ wash: RGB) -> Double {
        let ink = RGB(255, 255, 255), chip = chip(over: wash)
        return min(
            ratio(mix(wash, ink, 0.90), wash),
            ratio(mix(wash, ink, 0.82), wash),
            ratio(mix(wash, ink, 0.62), wash),
            ratio(mix(chip, ink, 0.95), chip)
        )
    }

    /// The window wash: frost + hue at strength, pulled back until sidebar text is >= 4.5:1.
    static func wash(_ h: Double, _ s: Double) -> RGB {
        let (A, B, f) = parts(h)
        let c = mix(A.c, B.c, f)
        let steps = [0] + (0..<3).map { A.a[$0] * (1 - f) + B.a[$0] * f }
        let s = labClamp(s, 0, 3)
        let k = min(2, Int(s.rounded(.down)))
        var a = steps[k] + (steps[k + 1] - steps[k]) * (s - Double(k))
        var w = mix(frost, c, a)
        while a > 0 && worstContrast(w) < 4.5 {
            a -= 0.005
            w = mix(frost, c, a)
        }
        return w
    }

    /// The pad field: the real wash, nudged a touch toward the swatch so the pad reads as colour.
    static func padColour(_ h: Double, _ s: Double) -> RGB {
        mix(wash(h, s), accent(h), 0.16 * s / 3)
    }
}
