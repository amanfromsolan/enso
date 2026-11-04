#if ENSO_DEVTOOLS
import AppKit
import Combine
import Darwin
import Foundation
import SwiftUI

// MARK: - Bar state

/// Visibility of the dev Performance Bar: hidden (default), a one-line
/// strip, or the strip plus the four-column breakdown. Persisted across
/// relaunches. Publishes only on state changes, so the root view and the
/// menu can observe it without re-rendering at the sampling rate.
@MainActor
final class PerfBarController: ObservableObject {
    enum State: String {
        case hidden
        case collapsed
        case expanded
    }

    static let shared = PerfBarController()

    static let stateKey = "devtools.perfBar.state"
    static let lastShownKey = "devtools.perfBar.lastShown"
    static let enabledKey = "devtools.enabled"

    /// Short ease for hide/show and collapse/expand (matches the mockup's
    /// cubic-bezier(.2, .8, .2, 1)).
    static let animation: Animation = .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.22)

    @Published private(set) var state: State
    /// The Settings "Developer tools" switch (off by default). Off, the
    /// menu item, its shortcut, and the palette command disappear, and the
    /// bar is hidden with its monitor stopped.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled {
                setState(.hidden)
            }
        }
    }
    /// What ⌥⌘P brings back after hiding: collapsed or expanded.
    private var lastShown: State

    var isVisible: Bool { state != .hidden }
    var isExpanded: Bool { state == .expanded }
    var toggleTitle: String { isVisible ? "Hide Performance Bar" : "Show Performance Bar" }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        state = defaults.string(forKey: Self.stateKey).flatMap(State.init) ?? .hidden
        let remembered = defaults.string(forKey: Self.lastShownKey).flatMap(State.init)
        lastShown = (remembered == .expanded) ? .expanded : .collapsed
        if state != .hidden {
            lastShown = state
        }
        // Developer tools off: never come back up with the bar showing.
        if !isEnabled && state != .hidden {
            state = .hidden
            defaults.set(State.hidden.rawValue, forKey: Self.stateKey)
            defaults.set(lastShown.rawValue, forKey: Self.lastShownKey)
        }
    }

    func toggleVisibility() {
        guard isEnabled else { return }
        setState(isVisible ? .hidden : lastShown)
    }

    func toggleExpanded() {
        guard isVisible else { return }
        setState(isExpanded ? .collapsed : .expanded)
    }

    private func setState(_ newState: State) {
        guard newState != state else { return }
        withAnimation(Self.animation) {
            state = newState
        }
        if newState != .hidden {
            lastShown = newState
        }
        let defaults = UserDefaults.standard
        defaults.set(newState.rawValue, forKey: Self.stateKey)
        defaults.set(lastShown.rawValue, forKey: Self.lastShownKey)
        PerfMonitor.shared.setActive(newState != .hidden)
    }
}

// MARK: - Snapshot

struct PerfHitch: Sendable, Equatable {
    /// When the main thread became responsive again (the stall's end).
    let at: Date
    let ms: Int
}

struct PerfTerminalCounts: Equatable {
    var total = 0
    var onScreen = 0
    var drawingHidden = 0
    var paused = 0
    var asleep = 0

    /// Live surfaces libghostty still renders, on screen or not.
    var drawing: Int { onScreen + drawingHidden }
}

/// Everything the bar draws, produced once per sample.
struct PerfSnapshot: Equatable {
    enum Level: Equatable {
        case good
        case warn
        case bad
    }

    var sampledAt = Date()
    var hasData = false

    var memoryMB: Double = 0
    var memoryPeakMB: Double = 0
    /// Last − first sample of the 60s window.
    var memoryGrowthMB: Double = 0
    var memorySeries: [Double] = []

    /// Nil until two readings exist to diff.
    var cpuPercent: Double?
    var cpuAvg: Double = 0
    var cpuPeak: Double = 0
    var cpuSeries: [Double] = []

    var hitches: [PerfHitch] = []
    var hitchCount: Int { hitches.count }
    var worstHitchMs: Int { hitches.map(\.ms).max() ?? 0 }

    var terminals = PerfTerminalCounts()
    /// Titles of tabs still drawing while off screen, in sidebar order.
    var drawingInBackground: [String] = []

    var level: Level = .good
    var reason = "Healthy"
}

// MARK: - Monitor

/// Samples memory, CPU, main-thread hitches, and terminal render state once
/// per second — only while the Performance Bar is visible. Hidden, it runs
/// no timer and no watchdog. Its own object (not part of the tab store) so
/// the 1 Hz publish redraws only the bar.
@MainActor
final class PerfMonitor: ObservableObject {
    static let shared = PerfMonitor()

    static let windowSize = 60
    static let hitchWindow: TimeInterval = 60
    static let memoryClimbThresholdMB: Double = 20

    @Published private(set) var snapshot = PerfSnapshot()

    /// Read at sample time only — never observed, since the store publishes
    /// constantly and the bar must not re-render with it.
    private(set) weak var store: TerminalSessionStore?

    private var timer: Timer?
    private var watchdog: HitchWatchdog?
    private(set) var isActive = false

    private var memorySeries: [Double] = []
    private var cpuSeries: [Double] = []
    private var memoryPeakMB: Double = 0
    private var hitches: [PerfHitch] = []
    private var lastCPU: (cpuSeconds: Double, wallSeconds: Double)?
    private(set) var sessionStart = Date()

    private init() {}

    func attach(to store: TerminalSessionStore) {
        self.store = store
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        if active {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        memorySeries = []
        cpuSeries = []
        memoryPeakMB = 0
        hitches = []
        lastCPU = nil
        sessionStart = Date()

        let watchdog = HitchWatchdog { [weak self] at, ms in
            self?.recordHitch(PerfHitch(at: at, ms: ms))
        }
        watchdog.start()
        self.watchdog = watchdog

        // Common modes: keep sampling through live resize and menu tracking.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sample()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        sample()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        watchdog?.stop()
        watchdog = nil
    }

    private func recordHitch(_ hitch: PerfHitch) {
        // A ping already in flight when the bar hid can still land.
        guard isActive else { return }
        hitches.append(hitch)
    }

    // MARK: Sampling

    private func sample() {
        guard isActive else { return }
        let now = Date()

        if let bytes = Self.physicalFootprintBytes() {
            let mb = Double(bytes) / 1_048_576
            append(mb, to: &memorySeries)
            memoryPeakMB = max(memoryPeakMB, mb)
        }

        var cpuNow: Double?
        let wall = Self.monotonicSeconds()
        if let cpuSeconds = Self.processCPUSeconds() {
            if let lastCPU, wall > lastCPU.wallSeconds {
                let percent = max(0, (cpuSeconds - lastCPU.cpuSeconds) / (wall - lastCPU.wallSeconds) * 100)
                cpuNow = percent
                append(percent, to: &cpuSeries)
            }
            lastCPU = (cpuSeconds, wall)
        }

        hitches.removeAll { now.timeIntervalSince($0.at) > Self.hitchWindow }

        let (terminals, background) = sampleTerminals()

        var next = PerfSnapshot()
        next.sampledAt = now
        next.hasData = true
        next.memoryMB = memorySeries.last ?? 0
        next.memoryPeakMB = memoryPeakMB
        next.memoryGrowthMB = (memorySeries.last ?? 0) - (memorySeries.first ?? 0)
        next.memorySeries = memorySeries
        next.cpuPercent = cpuNow
        next.cpuAvg = cpuSeries.isEmpty ? 0 : cpuSeries.reduce(0, +) / Double(cpuSeries.count)
        next.cpuPeak = cpuSeries.max() ?? 0
        next.cpuSeries = cpuSeries
        next.hitches = hitches
        next.terminals = terminals
        next.drawingInBackground = background
        (next.level, next.reason) = Self.status(for: next)
        snapshot = next
    }

    private func append(_ value: Double, to series: inout [Double]) {
        series.append(value)
        if series.count > Self.windowSize {
            series.removeFirst(series.count - Self.windowSize)
        }
    }

    /// Classifies every tab into exactly one bucket: on screen, drawing
    /// while hidden, paused (live but libghostty told it's occluded), or
    /// asleep (no live surface — slept, or dormant since relaunch).
    private func sampleTerminals() -> (PerfTerminalCounts, [String]) {
        var counts = PerfTerminalCounts()
        var background: [String] = []
        guard let store else { return (counts, background) }
        let manager = GhosttySurfaceManager.shared
        for session in store.sessions {
            counts.total += 1
            guard let view = manager.existingView(for: session.id), view.surface != nil else {
                counts.asleep += 1
                continue
            }
            if Self.isOnScreen(view) {
                counts.onScreen += 1
            } else if view.occlusionVisible {
                counts.drawingHidden += 1
                background.append(Self.name(for: session))
            } else {
                counts.paused += 1
            }
        }
        return (counts, background)
    }

    /// In a visible, unoccluded window and not hidden by an ancestor. Split
    /// panes each count — several surfaces can be on screen at once.
    private static func isOnScreen(_ view: GhosttySurfaceView) -> Bool {
        guard let window = view.window else { return false }
        return window.isVisible
            && window.occlusionState.contains(.visible)
            && !view.isHiddenOrHasHiddenAncestor
    }

    private static func name(for session: TerminalSession) -> String {
        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        return (session.workingDirectory as NSString).lastPathComponent
    }

    /// Same precedence as the mockup: red when janky, else the first amber
    /// reason that applies, else green.
    private static func status(for s: PerfSnapshot) -> (PerfSnapshot.Level, String) {
        if s.hitchCount >= 3 { return (.bad, "Janky") }
        if s.terminals.drawingHidden > 0 { return (.warn, "Hidden tabs drawing") }
        if s.hitchCount >= 1 { return (.warn, "Recent hitch") }
        if s.memoryGrowthMB > memoryClimbThresholdMB { return (.warn, "Memory climbing") }
        return (.good, "Healthy")
    }

    // MARK: Process metrics

    /// `phys_footprint` from TASK_VM_INFO — the "Memory" column in
    /// Activity Monitor.
    nonisolated static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    /// Total user + system CPU time this process has consumed, all threads.
    nonisolated static func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        func seconds(_ time: timeval) -> Double {
            Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    nonisolated static func monotonicSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    // MARK: Diagnostics

    private struct Diagnostics: Encodable {
        struct Terminals: Encodable {
            let total: Int
            let onScreen: Int
            let drawingHidden: Int
            let paused: Int
            let asleep: Int
        }

        let app: String
        let version: String
        let build: String
        let macOS: String
        let barUptimeSeconds: Int
        let memoryMB: Int
        let memoryPeakMB: Int
        let cpuPercent: Double?
        let cpuAvg: Double
        let cpuPeak: Double
        let hitchesLastMinute: Int
        let worstHitchMs: Int
        let terminals: Terminals
        let drawingInBackground: [String]
    }

    /// Pretty JSON of the current snapshot for pasting into a bug report.
    func diagnosticsJSON() -> String {
        let s = snapshot
        let info = Bundle.main.infoDictionary ?? [:]
        let round1 = { (value: Double) in (value * 10).rounded() / 10 }
        let diagnostics = Diagnostics(
            app: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? "Enso",
            version: (info["CFBundleShortVersionString"] as? String) ?? "?",
            build: (info["CFBundleVersion"] as? String) ?? "?",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            barUptimeSeconds: Int(Date().timeIntervalSince(sessionStart)),
            memoryMB: Int(s.memoryMB.rounded()),
            memoryPeakMB: Int(s.memoryPeakMB.rounded()),
            cpuPercent: s.cpuPercent.map(round1),
            cpuAvg: round1(s.cpuAvg),
            cpuPeak: round1(s.cpuPeak),
            hitchesLastMinute: s.hitchCount,
            worstHitchMs: s.worstHitchMs,
            terminals: .init(
                total: s.terminals.total,
                onScreen: s.terminals.onScreen,
                drawingHidden: s.terminals.drawingHidden,
                paused: s.terminals.paused,
                asleep: s.terminals.asleep
            ),
            drawingInBackground: s.drawingInBackground
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(diagnostics) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func copyDiagnostics() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsJSON(), forType: .string)
    }
}

// MARK: - Hitch watchdog

/// Detects main-thread stalls longer than 250ms: a background thread pings
/// the main queue every 50ms and times how long each ping waits. A stall is
/// recorded with its full duration once the main thread finally runs the
/// ping (so it reads up to one ping interval short). Runs only while the
/// Performance Bar is visible.
nonisolated final class HitchWatchdog: @unchecked Sendable {
    static let threshold: Double = 0.25
    static let pingInterval: TimeInterval = 0.05

    private let lock = NSLock()
    /// Bumped by start/stop; a loop exits once its generation is stale, so
    /// a quick stop → start can never leave two threads pinging.
    private var generation = 0
    private let onHitch: @MainActor @Sendable (Date, Int) -> Void

    init(onHitch: @escaping @MainActor @Sendable (Date, Int) -> Void) {
        self.onHitch = onHitch
    }

    func start() {
        let current = lock.withLock {
            generation += 1
            return generation
        }
        let thread = Thread { [self] in
            run(generation: current)
        }
        thread.name = "Enso.HitchWatchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() {
        lock.withLock { generation += 1 }
    }

    private func isCurrent(_ value: Int) -> Bool {
        lock.withLock { generation == value }
    }

    private func run(generation value: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        let onHitch = onHitch
        let threshold = Self.threshold
        while isCurrent(value) {
            let sent = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                let waited = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000_000
                if waited > threshold {
                    MainActor.assumeIsolated {
                        onHitch(Date(), Int((waited * 1000).rounded()))
                    }
                }
                semaphore.signal()
            }
            semaphore.wait()
            Thread.sleep(forTimeInterval: Self.pingInterval)
        }
    }
}
#endif
