#if ENSO_DEVTOOLS
import AppKit
import Combine
import SwiftUI

// MARK: - Dock

/// The dev Performance Bar, docked full width under both the sidebar and
/// the terminal: 0pt hidden, 30pt collapsed, 200pt expanded, with the
/// height animated by PerfBarController. Observes only the controller (rare
/// state changes); the 1 Hz samples redraw PerfBarView alone.
struct PerfDock: View {
    /// Handed to the monitor for sample-time reads. A plain reference, not
    /// observed: the tab store publishes constantly and the dock must not
    /// re-render with it.
    let store: TerminalSessionStore
    @ObservedObject private var controller = PerfBarController.shared

    private var height: CGFloat {
        switch controller.state {
        case .hidden: 0
        case .collapsed: PerfBarMetrics.lineHeight
        case .expanded: PerfBarMetrics.expandedHeight
        }
    }

    var body: some View {
        PerfBarView(isExpanded: controller.isExpanded, store: store)
            // Bottom-aligned and clipped: the status line stays pinned to
            // the window's bottom edge while the height grows or shrinks
            // above it.
            .frame(maxWidth: .infinity)
            .frame(height: height, alignment: .bottom)
            .clipped()
            .background(Theme.ink.opacity(0.035))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Theme.ink.opacity(controller.isVisible ? 0.08 : 0))
                    .frame(height: 1)
            }
            .allowsHitTesting(controller.isVisible)
            .accessibilityHidden(!controller.isVisible)
            .onAppear {
                PerfMonitor.shared.attach(to: store)
                // Restores a bar left visible at quit; hidden stays free.
                PerfMonitor.shared.setActive(controller.isVisible)
                // No-op unless launched with -EnsoSwitchTest.
                SpaceSwitchTest.shared.startFromLaunchArgumentsIfNeeded()
                // No-op unless launched with -EnsoSwipeTuner YES.
                SwipeTuner.shared.openFromLaunchArgumentIfNeeded()
            }
    }
}

extension View {
    /// Stacks the Performance Bar under this view: the window content
    /// becomes body + dock, so the bar runs full width beneath both the
    /// sidebar and the terminal.
    func perfDock(store: TerminalSessionStore) -> some View {
        VStack(spacing: 0) {
            self
            PerfDock(store: store)
        }
    }
}

enum PerfBarMetrics {
    static let lineHeight: CGFloat = 30
    static let expandedHeight: CGFloat = 200
}

/// Status and series colors, light/dark like the mockup's tokens. Neutral
/// text, hairlines and washes come from Theme.ink / Theme.text.
enum PerfColors {
    static let good = Color(nsColor: Theme.dynamic(dark: NSColor(hex: 0x4CC38A), light: NSColor(hex: 0x1F9D63)))
    static let warn = Color(nsColor: Theme.dynamic(dark: NSColor(hex: 0xF0B33F), light: NSColor(hex: 0xB7791F)))
    static let bad = Color(nsColor: Theme.dynamic(dark: NSColor(hex: 0xEF5F5F), light: NSColor(hex: 0xD64545)))
    static let accent = Color(nsColor: Theme.dynamic(dark: NSColor(hex: 0x6AA8FF), light: NSColor(hex: 0x2F6FDB)))
    static let violet = Color(nsColor: Theme.dynamic(dark: NSColor(hex: 0xA68BFF), light: NSColor(hex: 0x6B4FD8)))

    static func level(_ level: PerfSnapshot.Level) -> Color {
        switch level {
        case .good: good
        case .warn: warn
        case .bad: bad
        }
    }
}

private enum PerfFont {
    static let line = Font.system(size: 11.5, design: .monospaced)
    static let header = Font.system(size: 10.5)
    static let big = Font.system(size: 20, weight: .semibold, design: .monospaced)
    static let bigUnit = Font.system(size: 11, weight: .medium)
    static let sub = Font.system(size: 11, design: .monospaced)
}

// MARK: - Bar

struct PerfBarView: View {
    let isExpanded: Bool
    let store: TerminalSessionStore
    @ObservedObject private var monitor = PerfMonitor.shared
    @State private var copiedToken: UUID?

    private var s: PerfSnapshot { monitor.snapshot }

    var body: some View {
        VStack(spacing: 0) {
            if isExpanded {
                columns
                    .frame(height: PerfBarMetrics.expandedHeight - PerfBarMetrics.lineHeight)
                    .overlay(alignment: .bottom) { hairline(horizontal: true) }
                    .transition(.opacity)
            }
            statusLine
        }
        .contentShape(Rectangle())
        // Double-clicking empty bar space toggles collapsed ⇄ expanded;
        // the buttons keep their own clicks.
        .onTapGesture(count: 2) {
            PerfBarController.shared.toggleExpanded()
            restoreTerminalFocus()
        }
        .simultaneousGesture(TapGesture().onEnded { restoreTerminalFocus() })
    }

    // MARK: Status line

    private var statusLine: some View {
        HStack(spacing: 2) {
            ViewThatFits(in: .horizontal) {
                lineItems(showTerminals: true, showHitches: true)
                lineItems(showTerminals: false, showHitches: true)
                lineItems(showTerminals: false, showHitches: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            copyButton
            chevronButton
        }
        .font(PerfFont.line)
        .foregroundStyle(Theme.text(0.88))
        .lineLimit(1)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: PerfBarMetrics.lineHeight)
    }

    private func lineItems(showTerminals: Bool, showHitches: Bool) -> some View {
        HStack(spacing: 2) {
            lineItem {
                Circle()
                    .fill(PerfColors.level(s.level))
                    .frame(width: 8, height: 8)
                Text(verbatim: s.hasData ? s.reason : "Sampling…")
            }
            hairline(horizontal: false)
            lineItem {
                key("Memory")
                Text(verbatim: "\(Int(s.memoryMB.rounded())) MB")
                if !isExpanded {
                    memoryGraph(fill: false).frame(width: 46, height: 14)
                }
            }
            hairline(horizontal: false)
            lineItem {
                key("CPU")
                Text(verbatim: cpuText(s.cpuPercent) + "%")
                if !isExpanded {
                    cpuGraph.frame(width: 46, height: 14)
                }
            }
            if showHitches {
                hairline(horizontal: false)
                lineItem {
                    key("Hitches")
                    if s.hitchCount > 0 {
                        Text(verbatim: "\(s.hitchCount)/min").foregroundStyle(PerfColors.warn)
                        Text(verbatim: "· worst \(s.worstHitchMs)ms").foregroundStyle(Theme.text(0.45))
                    } else {
                        Text(verbatim: "0/min")
                    }
                }
            }
            if showTerminals {
                hairline(horizontal: false)
                lineItem {
                    key("Terminals")
                    Text(verbatim: "\(s.terminals.drawing) drawing")
                        .foregroundStyle(s.terminals.drawingHidden > 0 ? PerfColors.warn : Theme.text(0.88))
                    Text(verbatim: "· \(s.terminals.onScreen) on screen · \(s.terminals.total) total")
                        .foregroundStyle(Theme.text(0.45))
                    if !isExpanded {
                        PerfStackBar(counts: s.terminals, trackOpacity: 0.08)
                            .frame(width: 54, height: 6)
                    }
                }
            }
        }
        .fixedSize()
    }

    private func lineItem<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.horizontal, 8)
    }

    private func key(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Theme.text(0.45))
    }

    private var copyButton: some View {
        Button {
            monitor.copyDiagnostics()
            let token = UUID()
            copiedToken = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedToken == token { copiedToken = nil }
            }
            restoreTerminalFocus()
        } label: {
            Text(verbatim: copiedToken == nil ? "⧉ Copy" : "✓ Copied")
                .font(.system(size: 11.5, design: .monospaced))
                .padding(.horizontal, 8)
                .frame(height: 22)
        }
        .buttonStyle(PerfBarButtonStyle(tint: copiedToken == nil ? nil : PerfColors.good))
        .help("Copy diagnostics")
        .fixedSize()
    }

    private var chevronButton: some View {
        Button {
            PerfBarController.shared.toggleExpanded()
            restoreTerminalFocus()
        } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 9.5, weight: .semibold))
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .animation(.easeOut(duration: 0.2), value: isExpanded)
                .frame(width: 24, height: 22)
        }
        .buttonStyle(PerfBarButtonStyle(tint: nil))
        .help("Expand / collapse (double-click the bar)")
    }

    // MARK: Expanded columns

    private var columns: some View {
        GeometryReader { geo in
            // Mockup grid: 1fr 1fr 1fr 1.35fr, with three 1pt dividers.
            let unit = max(0, geo.size.width - 3) / 4.35
            HStack(spacing: 0) {
                memoryColumn.frame(width: unit)
                hairline(horizontal: false, fullHeight: true)
                cpuColumn.frame(width: unit)
                hairline(horizontal: false, fullHeight: true)
                hitchesColumn.frame(width: unit)
                hairline(horizontal: false, fullHeight: true)
                terminalsColumn.frame(width: unit * 1.35)
            }
        }
    }

    private func column<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 8, trailing: 14))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .lineLimit(1)
    }

    private func header(_ title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 0) {
            Text(verbatim: title.uppercased())
                .font(PerfFont.header)
                .tracking(0.5)
            Spacer(minLength: 4)
            if let trailing {
                Text(verbatim: trailing).font(.system(size: 10.5, design: .monospaced))
            }
        }
        .foregroundStyle(Theme.text(0.5))
    }

    private func big(_ value: String, unit: String, color: Color? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: value)
                .font(PerfFont.big)
                .foregroundStyle(color ?? Theme.text(0.92))
            Text(verbatim: unit)
                .font(PerfFont.bigUnit)
                .foregroundStyle(Theme.text(0.5))
        }
        .padding(.top, 2)
    }

    private func sub(_ text: String) -> some View {
        Text(verbatim: text)
            .font(PerfFont.sub)
            .foregroundStyle(Theme.text(0.5))
            .truncationMode(.tail)
    }

    private var memoryColumn: some View {
        column {
            header("Memory")
            big("\(Int(s.memoryMB.rounded()))", unit: "MB")
            sub("peak \(Int(s.memoryPeakMB.rounded())) · \(s.memoryGrowthMB >= 0 ? "+" : "")\(Int(s.memoryGrowthMB.rounded())) MB/min")
            memoryGraph(fill: true)
                .padding(.top, 6)
        }
    }

    private var cpuColumn: some View {
        column {
            header("CPU")
            big(cpuText(s.cpuPercent), unit: "%")
            sub("avg \(cpuText(s.cpuAvg)) · peak \(cpuText(s.cpuPeak))")
            cpuGraph
                .padding(.top, 6)
        }
    }

    private var hitchesColumn: some View {
        column {
            header("Hitches")
            big("\(s.hitchCount)", unit: "/ min", color: s.hitchCount > 0 ? PerfColors.warn : nil)
            sub(s.hitchCount > 0 ? "worst \(s.worstHitchMs)ms" : "none in the last minute")
            PerfHitchTimeline(hitches: s.hitches, now: s.sampledAt)
                .padding(.top, 6)
        }
    }

    private var terminalsColumn: some View {
        let t = s.terminals
        return column {
            header("Terminals", trailing: "\(t.total) total")
            big(
                "\(t.drawing)",
                unit: "drawing · \(t.onScreen) on screen",
                color: t.drawingHidden > 0 ? PerfColors.warn : nil
            )
            PerfStackBar(counts: t, trackOpacity: 0.06)
                .frame(height: 8)
                .padding(.top, 8)
                .padding(.bottom, 7)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow {
                    legendItem(.onScreen, t.onScreen, "on screen")
                    legendItem(.drawingHidden, t.drawingHidden, "drawing hidden", warn: t.drawingHidden > 0)
                }
                GridRow {
                    legendItem(.paused, t.paused, "paused")
                    legendItem(.asleep, t.asleep, "asleep")
                }
            }
            .font(PerfFont.line)
            offenders
                .padding(.top, 8)
        }
    }

    private func legendItem(_ kind: PerfStackKind, _ count: Int, _ label: String, warn: Bool = false) -> some View {
        HStack(spacing: 6) {
            PerfSwatch(kind: kind).frame(width: 8, height: 8)
            Text(verbatim: "\(count)")
                .fontWeight(.semibold)
                .foregroundStyle(warn ? PerfColors.warn : Theme.text(0.88))
                .frame(minWidth: 22, alignment: .trailing)
            Text(verbatim: label)
                .foregroundStyle(Theme.text(0.7))
        }
    }

    /// Names only the tabs drawing in the background — never paused or
    /// asleep ones — capped at four plus a count, so 120+ tabs still fit.
    private var offenders: some View {
        var text: AttributedString
        let names = s.drawingInBackground
        if names.isEmpty {
            var mark = AttributedString("✓")
            mark.foregroundColor = PerfColors.good
            text = mark + AttributedString(" Nothing is drawing in the background.")
        } else {
            let shown = names.prefix(4)
            var lead = AttributedString("Drawing in the background:")
            lead.foregroundColor = PerfColors.warn
            text = lead + AttributedString(" " + shown.joined(separator: ", "))
            if names.count > shown.count {
                var more = AttributedString(" +\(names.count - shown.count) more")
                more.foregroundColor = Theme.text(0.45)
                text += more
            }
        }
        return Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.text(0.7))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Graphs

    private func memoryGraph(fill: Bool) -> some View {
        let values = s.memorySeries
        let lo = (values.min() ?? 0) - 4
        let hi = (values.max() ?? 0) + 4
        return PerfLineGraph(
            values: values,
            lo: lo,
            hi: hi,
            color: PerfColors.violet,
            fillOpacity: fill ? 0.12 : nil
        )
    }

    private var cpuGraph: some View {
        let values = s.cpuSeries
        let hi = max(20, values.max() ?? 0) * 1.05
        return PerfLineGraph(values: values, lo: 0, hi: hi, color: PerfColors.accent, fillOpacity: 0.15)
    }

    // MARK: Helpers

    private func cpuText(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: "%.1f", value)
    }

    @ViewBuilder
    private func hairline(horizontal: Bool, fullHeight: Bool = false) -> some View {
        if horizontal {
            Rectangle().fill(Theme.ink.opacity(0.08)).frame(height: 1)
        } else if fullHeight {
            Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 1)
        } else {
            Rectangle().fill(Theme.ink.opacity(0.08)).frame(width: 1, height: 14)
        }
    }

    /// The bar is chrome: a click on it must never leave the keyboard
    /// stranded away from the terminal. Hands focus back to the selected
    /// tab only when nothing text-editable holds it (so an in-progress
    /// rename or find field isn't yanked).
    private func restoreTerminalFocus() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow else { return }
            let responder = window.firstResponder
            if responder is GhosttySurfaceView || responder is NSText { return }
            GhosttySurfaceManager.shared.restoreFocus(to: store.selection)
        }
    }
}

// MARK: - Button style

private struct PerfBarButtonStyle: ButtonStyle {
    let tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, tint: tint)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color?
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(tint ?? Theme.text(isHovering ? 0.95 : 0.55))
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.ink.opacity(configuration.isPressed ? 0.12 : (isHovering ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
                .focusEffectDisabled()
        }
    }
}

// MARK: - Graph primitives

/// A 60-slot line graph, right-aligned so a fresh window fills in from the
/// right edge as samples arrive.
private struct PerfLineGraph: View {
    let values: [Double]
    let lo: Double
    let hi: Double
    let color: Color
    /// Nil draws the line only.
    let fillOpacity: Double?

    var body: some View {
        GeometryReader { geo in
            let points = Self.points(values, size: geo.size, lo: lo, hi: hi)
            ZStack {
                if let fillOpacity, points.count >= 2 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geo.size.height))
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(color.opacity(fillOpacity))
                }
                if points.count >= 2 {
                    Path { path in path.addLines(points) }
                        .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    static func points(_ values: [Double], size: CGSize, lo: Double, hi: Double) -> [CGPoint] {
        guard size.width > 0, size.height > 0 else { return [] }
        let pad: CGFloat = 2
        let range = hi - lo == 0 ? 1 : hi - lo
        let step = size.width / CGFloat(PerfMonitor.windowSize - 1)
        let count = values.count
        return values.enumerated().map { index, value in
            let x = size.width - CGFloat(count - 1 - index) * step
            let y = size.height - pad - CGFloat((value - lo) / range) * (size.height - pad * 2)
            return CGPoint(x: x, y: y)
        }
    }
}

/// The last 60 seconds as a strip: a dashed baseline and one mark per
/// hitch at the moment it ended, its width proportional to its duration.
private struct PerfHitchTimeline: View {
    let hitches: [PerfHitch]
    let now: Date

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: h / 2))
                    path.addLine(to: CGPoint(x: w, y: h / 2))
                }
                .stroke(Theme.ink.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))

                ForEach(Array(hitches.enumerated()), id: \.offset) { _, hitch in
                    let x = w - CGFloat(now.timeIntervalSince(hitch.at) / PerfMonitor.hitchWindow) * w
                    let width = max(w / 220, CGFloat(hitch.ms) / 1000 * (w / 60))
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(hitch.ms >= 500 ? PerfColors.bad : PerfColors.warn)
                        .frame(width: width, height: h)
                        .offset(x: x - width)
                }
            }
        }
        .clipped()
    }
}

enum PerfStackKind: CaseIterable {
    case onScreen
    case drawingHidden
    case paused
    case asleep
}

/// Fill for one stacked-bar bucket; asleep is hatched like the mockup.
private struct PerfSwatch: View {
    let kind: PerfStackKind
    var cornerRadius: CGFloat = 2

    var body: some View {
        switch kind {
        case .onScreen:
            RoundedRectangle(cornerRadius: cornerRadius).fill(PerfColors.good)
        case .drawingHidden:
            RoundedRectangle(cornerRadius: cornerRadius).fill(PerfColors.warn)
        case .paused:
            RoundedRectangle(cornerRadius: cornerRadius).fill(Theme.ink.opacity(0.22))
        case .asleep:
            PerfHatch()
                .stroke(Theme.ink.opacity(0.16), lineWidth: 1.4)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

/// 135° stripes on a 4pt period.
private struct PerfHatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let period: CGFloat = 4
        var x = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += period
        }
        return path
    }
}

/// On screen / drawing hidden / paused / asleep as one proportional bar;
/// scales to any tab count.
private struct PerfStackBar: View {
    let counts: PerfTerminalCounts
    let trackOpacity: Double

    var body: some View {
        GeometryReader { geo in
            let segments: [(PerfStackKind, Int)] = [
                (.onScreen, counts.onScreen),
                (.drawingHidden, counts.drawingHidden),
                (.paused, counts.paused),
                (.asleep, counts.asleep),
            ].filter { $0.1 > 0 }
            let total = max(1, segments.reduce(0) { $0 + $1.1 })
            HStack(spacing: 0) {
                ForEach(segments, id: \.0) { kind, count in
                    PerfSwatch(kind: kind, cornerRadius: 0)
                        .frame(width: geo.size.width * CGFloat(count) / CGFloat(total))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
        }
        .background(Theme.ink.opacity(trackOpacity))
        .clipShape(Capsule())
        .animation(.easeOut(duration: 0.4), value: counts)
    }
}
#endif
