#if ENSO_DEVTOOLS
import AppKit
import SwiftUI

/// Temporary tool for tuning the space swipe by feel: speed, fade and blur,
/// live, with the next swipe using the new values. Plain AppKit because the
/// panel must never take the keyboard from the terminal, and these controls
/// work in a window that can't become key.
///
/// Launch arguments, which override saved values for that run without saving:
/// `-EnsoSlideDuration <seconds>`, `-EnsoSlideFade <0-100>`,
/// `-EnsoSlideBlur <0-8>`. `-EnsoSwipeTuner YES` opens the panel at launch.
///
/// Also hosts the terminal card's space-tint multiplier (`TerminalTint`,
/// default `EnsoTerminalTintScale`), applied live.
final class SwipeTuner: NSObject {
    static let shared = SwipeTuner()

    static let durationRange: ClosedRange<Double> = 0.10...0.40
    static let fadeRange: ClosedRange<Double> = 0...100
    static let blurRange: ClosedRange<Double> = 0...8

    private enum Key {
        static let duration = "swipeTunerDuration"
        static let fade = "swipeTunerFade"
        static let blur = "swipeTunerBlur"
    }

    /// Spring duration, seconds.
    private(set) var duration: Double
    /// How dim a page is at distance 1, as a percent.
    private(set) var fadePercent: Double
    /// Blur radius at distance 1.
    private(set) var blur: Double

    private var panelController: SwipeTunerPanelController?
    private var launchArgumentChecked = false

    private override init() {
        let defaults = UserDefaults.standard
        func value(launch: String, saved: String, fallback: Double, range: ClosedRange<Double>) -> Double {
            let raw = defaults.object(forKey: launch) != nil ? defaults.double(forKey: launch)
                : defaults.object(forKey: saved) != nil ? defaults.double(forKey: saved)
                : fallback
            return min(range.upperBound, max(range.lowerBound, raw))
        }
        duration = value(
            launch: "EnsoSlideDuration", saved: Key.duration,
            fallback: SlideTuning.defaultDuration, range: Self.durationRange
        )
        fadePercent = value(
            launch: "EnsoSlideFade", saved: Key.fade,
            fallback: SlideTuning.defaultFade * 100, range: Self.fadeRange
        )
        blur = value(
            launch: "EnsoSlideBlur", saved: Key.blur,
            fallback: SlideTuning.defaultBlur, range: Self.blurRange
        )
        super.init()
    }

    func setDuration(_ value: Double) {
        duration = value
        UserDefaults.standard.set(value, forKey: Key.duration)
    }

    func setFadePercent(_ value: Double) {
        fadePercent = value
        UserDefaults.standard.set(value, forKey: Key.fade)
    }

    func setBlur(_ value: Double) {
        blur = value
        UserDefaults.standard.set(value, forKey: Key.blur)
    }

    func reset() {
        setDuration(SlideTuning.defaultDuration)
        setFadePercent(SlideTuning.defaultFade * 100)
        setBlur(SlideTuning.defaultBlur)
        TerminalTint.setScale(1)
    }

    /// Time for a resting spring to cover 90% of the way, from the same
    /// parameters the slide uses.
    var arrivalMilliseconds: Int {
        let spring = Spring(duration: duration, bounce: SlideTuning.bounce)
        var time = 0.0
        while time < 2 {
            if spring.value(fromValue: 0.0, toValue: 1.0, initialVelocity: 0.0, time: time) >= 0.9 {
                break
            }
            time += 0.001
        }
        return Int((time * 1000).rounded())
    }

    var valuesText: String {
        String(
            format: "speed %.2fs (arrives in ~%d ms), fade %.0f%%, blur %.1f, terminal tint %.2f×",
            duration, arrivalMilliseconds, fadePercent, blur, TerminalTint.scale
        )
    }

    func copyValues() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(valuesText, forType: .string)
    }

    func togglePanel() {
        if let panelController, panelController.isVisible {
            panelController.hide()
        } else {
            showPanel()
        }
    }

    /// Called from the Performance Bar dock's onAppear, whatever the
    /// Developer tools setting says; acts once per launch.
    func openFromLaunchArgumentIfNeeded() {
        guard !launchArgumentChecked else { return }
        launchArgumentChecked = true
        guard UserDefaults.standard.bool(forKey: "EnsoSwipeTuner") else { return }
        // The window usually isn't on screen yet at this point.
        showWhenWindowExists(attemptsLeft: 40)
    }

    private func showWhenWindowExists(attemptsLeft: Int) {
        if Self.appWindow() != nil || attemptsLeft == 0 {
            showPanel()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showWhenWindowExists(attemptsLeft: attemptsLeft - 1)
            }
        }
    }

    private func showPanel() {
        let controller = panelController ?? SwipeTunerPanelController(tuner: self)
        panelController = controller
        controller.show(beside: Self.appWindow())
    }

    fileprivate static func appWindow() -> NSWindow? {
        let candidates = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.windows
        return candidates.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }
    }
}

// MARK: - Panel

private final class SwipeTunerWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class FirstClickSlider: NSSlider {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class SwipeTunerPanelController: NSObject {
    private static let size = NSSize(width: 340, height: 228)
    private static let gap: CGFloat = 12

    private let tuner: SwipeTuner
    private let panel: SwipeTunerWindow

    private let durationSlider = FirstClickSlider()
    private let fadeSlider = FirstClickSlider()
    private let blurSlider = FirstClickSlider()
    private let tintSlider = FirstClickSlider()
    private let durationValue = NSTextField(labelWithString: "")
    private let fadeValue = NSTextField(labelWithString: "")
    private let blurValue = NSTextField(labelWithString: "")
    private let tintValue = NSTextField(labelWithString: "")
    private let arrivalLabel = NSTextField(labelWithString: "")

    init(tuner: SwipeTuner) {
        self.tuner = tuner
        panel = SwipeTunerWindow(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = "Swipe Tuner"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = NSColor(Theme.panel)

        configure(durationSlider, range: SwipeTuner.durationRange, action: #selector(durationChanged))
        configure(fadeSlider, range: SwipeTuner.fadeRange, action: #selector(fadeChanged))
        configure(blurSlider, range: SwipeTuner.blurRange, action: #selector(blurChanged))
        configure(tintSlider, range: TerminalTint.scaleRange, action: #selector(tintChanged))

        arrivalLabel.font = .systemFont(ofSize: 11)
        arrivalLabel.textColor = NSColor(Theme.text(0.55))

        let resetButton = button("Reset", action: #selector(resetPressed))
        let copyButton = button("Copy values", action: #selector(copyPressed))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [arrivalLabel, spacer, resetButton, copyButton])
        buttons.orientation = .horizontal
        buttons.spacing = 6

        let stack = NSStackView(views: [
            row("Speed", durationSlider, durationValue),
            row("Fade", fadeSlider, fadeValue),
            row("Blur", blurSlider, blurValue),
            row("Tint", tintSlider, tintValue),
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        panel.contentView = stack
        refresh()
    }

    var isVisible: Bool { panel.isVisible }

    func hide() {
        panel.orderOut(nil)
    }

    func show(beside window: NSWindow?) {
        refresh()
        panel.setFrameOrigin(origin(beside: window))
        // Never makeKey: the terminal keeps the keyboard.
        panel.orderFront(nil)
    }

    /// Right of the window, else left of it; with no room on either side,
    /// the terminal's bottom corner, because the sidebar is on the left.
    private func origin(beside window: NSWindow?) -> NSPoint {
        let frame = panel.frame.size
        guard let window else {
            let screen = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: screen.maxX - frame.width - Self.gap, y: screen.maxY - frame.height - Self.gap)
        }
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? window.frame
        let top = min(window.frame.maxY, screen.maxY) - frame.height
        if window.frame.maxX + Self.gap + frame.width <= screen.maxX {
            return NSPoint(x: window.frame.maxX + Self.gap, y: top)
        }
        if window.frame.minX - Self.gap - frame.width >= screen.minX {
            return NSPoint(x: window.frame.minX - Self.gap - frame.width, y: top)
        }
        return NSPoint(
            x: window.frame.maxX - frame.width - Self.gap * 2,
            y: window.frame.minY + Self.gap * 2
        )
    }

    private func configure(_ slider: NSSlider, range: ClosedRange<Double>, action: Selector) {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.isContinuous = true
        slider.target = self
        slider.action = action
    }

    private func button(_ title: String, action: Selector) -> NSButton {
        let button = FirstClickButton(title: title, target: self, action: action)
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11)
        return button
    }

    private func row(_ title: String, _ slider: NSSlider, _ value: NSTextField) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor(Theme.text(0.85))
        label.widthAnchor.constraint(equalToConstant: 44).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        value.textColor = NSColor(Theme.text(0.85))
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 48).isActive = true
        slider.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(views: [label, slider, value])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func refresh() {
        durationSlider.doubleValue = tuner.duration
        fadeSlider.doubleValue = tuner.fadePercent
        blurSlider.doubleValue = tuner.blur
        durationValue.stringValue = String(format: "%.2fs", tuner.duration)
        fadeValue.stringValue = String(format: "%.0f%%", tuner.fadePercent)
        blurValue.stringValue = String(format: "%.1f", tuner.blur)
        tintSlider.doubleValue = TerminalTint.scale
        tintValue.stringValue = String(format: "%.2f×", TerminalTint.scale)
        arrivalLabel.stringValue = "arrives in ~\(tuner.arrivalMilliseconds) ms"
    }

    @objc private func durationChanged() {
        tuner.setDuration((durationSlider.doubleValue * 100).rounded() / 100)
        refresh()
    }

    @objc private func fadeChanged() {
        tuner.setFadePercent(fadeSlider.doubleValue.rounded())
        refresh()
    }

    @objc private func blurChanged() {
        tuner.setBlur((blurSlider.doubleValue * 2).rounded() / 2)
        refresh()
    }

    /// The terminal tint's opacity multiplier; the cards follow live.
    @objc private func tintChanged() {
        TerminalTint.setScale((tintSlider.doubleValue * 20).rounded() / 20)
        refresh()
    }

    @objc private func resetPressed() {
        tuner.reset()
        refresh()
    }

    @objc private func copyPressed() {
        tuner.copyValues()
    }
}
#endif
