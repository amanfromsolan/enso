#if ENSO_DEVTOOLS
import AppKit
import Combine
import Foundation
import QuartzCore
import SwiftUI

/// Repeatable space-switch performance test: drives the same animated
/// `activateSpace` call the sidebar's space indicators make, times every
/// display-link callback around it, and writes one JSON report so several
/// builds can be compared.
///
/// Holds no timers, display link or buffers unless a run is in progress.
///
/// What it measures: gaps between display-link callbacks show main-thread
/// pacing. The render server composites on its own, so a frame it drops
/// while the main thread stays on time does not show up here.
final class SpaceSwitchTest: NSObject {
    static let shared = SpaceSwitchTest()

    enum Mode: String {
        case paced
        case burst
        /// Performs no switches: records for `count` seconds while something
        /// else (a real trackpad, or the swipe tool) drives the app.
        case observe

        var defaultCount: Int {
            switch self {
            case .paced: 30
            case .burst: 50
            case .observe: 60
            }
        }

        /// Observe: seconds per `count`, so the buffer estimate holds.
        var interval: TimeInterval {
            switch self {
            case .paced, .observe: 1
            case .burst: 0.05
            }
        }

        /// Wait after the last switch, so its window can close and paced
        /// runs end as settled as they ran.
        var tail: TimeInterval {
            switch self {
            case .paced: 1
            case .burst: SpaceSwitchTest.measureWindow + 0.05
            case .observe: 0
            }
        }
    }

    private struct Options {
        /// Raw mode text, so an invalid launch argument can be reported.
        var modeName: String
        var count: Int
        var label: String
        var outputPath: String?
        var copiesToPasteboard: Bool
        var bringsAppForward: Bool
    }

    private struct SwitchRecord {
        let index: Int
        let fromSpace: String
        let toSpace: String
        let firstVisit: Bool
        /// Index of the first callback after the switch, so the callback
        /// before it opens the gap that spans the switch.
        let frameIndex: Int
        let startTime: CFTimeInterval
        let activateMs: Double
        var terminalAttachedMs: Double?
    }

    /// One run's state; nil whenever no test is running.
    private final class Run {
        let mode: Mode
        let options: Options
        weak var store: TerminalSessionStore?
        weak var window: NSWindow?
        let startedAt = Date()
        let startTime = CACurrentMediaTime()
        let startSpaceID: SidebarSpace.ID
        let startSelection: TerminalSession.ID?
        let memoryStart: UInt64?
        let perfBarVisible: Bool
        var link: CADisplayLink?
        /// The current phase's timer: baseline, then switches, then tail.
        var timer: Timer?

        /// `link.timestamp` of each callback: the display's frame time, so
        /// these gaps count whole missed refreshes.
        var frameTimes: [CFTimeInterval] = []
        /// When each callback actually ran.
        var arrivalTimes: [CFTimeInterval] = []
        var frameDurations: [CFTimeInterval] = []

        var baselineEndIndex: Int?
        var baselineCPU: (cpuSeconds: Double, wallSeconds: Double)?
        var baselineCPUPercent: Double?
        var switchCPU: (cpuSeconds: Double, wallSeconds: Double)?
        var visited: Set<SidebarSpace.ID>
        var switches: [SwitchRecord] = []
        /// The latest switch, while its terminal isn't attached yet.
        var pendingAttach: (switchIndex: Int, deadline: CFTimeInterval)?
        /// Sampled at each switch: either one makes the numbers suspect.
        var appWentInactive = false
        var windowWasOccluded = false
        /// Observe only: `store.activeSpaceID` changes as they happen.
        var spaceChanges: AnyCancellable?
        var scroll = ScrollDiagnostics()
        /// Sessions live when recording started, load included.
        var liveAtStart = 0

        init(mode: Mode, options: Options, store: TerminalSessionStore, window: NSWindow) {
            self.mode = mode
            self.options = options
            self.store = store
            self.window = window
            startSpaceID = store.activeSpaceID
            startSelection = store.selection
            memoryStart = PerfMonitor.physicalFootprintBytes()
            perfBarVisible = PerfBarController.shared.isVisible
            visited = [store.activeSpaceID]
        }
    }

    static let baselineDuration: TimeInterval = 3
    /// Measured window after a switch (burst: until the next switch).
    static let measureWindow: TimeInterval = 0.45
    static let lateFactor = 1.5
    /// Observe: how long before a change counts as the drag leading up to it.
    static let preChangeWindow: TimeInterval = 0.6
    static let worstGapCount = 10
    /// Spawning is staggered, like the app's own eager restore, so it doesn't
    /// stall the launch. Shells need a few seconds after that to settle.
    static let loadSpawnInterval: TimeInterval = 0.2
    static let loadMinimumSettle: TimeInterval = 5
    /// Lets the palette finish closing before the idle baseline starts.
    private static let paletteSettleDelay: TimeInterval = 1
    private static let windowRetryInterval: TimeInterval = 0.25
    private static let windowRetryLimit = 120

    private var run: Run?
    /// True from the moment a run is requested, including its start delay.
    private var isBusy = false
    private var launchArgumentsChecked = false
    private var load: LoadState?

    private override init() {
        super.init()
    }

    // MARK: Triggers

    func startFromPalette(_ mode: Mode) {
        guard !isBusy else {
            NSLog("Enso space switch test: already running, ignoring request")
            return
        }
        isBusy = true
        let options = Options(
            modeName: mode.rawValue,
            count: mode.defaultCount,
            label: "manual",
            outputPath: nil,
            copiesToPasteboard: true,
            bringsAppForward: false
        )
        schedule(after: Self.paletteSettleDelay) { [weak self] in
            self?.begin(options, attemptsLeft: Self.windowRetryLimit)
        }
    }

    /// `-EnsoSwitchTest paced|burst`, `-EnsoSwitchTestCount <n>`,
    /// `-EnsoSwitchTestLabel <text>`, `-EnsoSwitchTestDelay <seconds>`,
    /// `-EnsoSwitchTestOutput <path>`, `-EnsoSwitchTestLoad <live>,<streaming>`.
    /// Works regardless of the Developer tools setting: passing the argument
    /// is already explicit. Called from the Performance Bar dock's onAppear;
    /// acts once per launch. `-EnsoSwitchTest observe` makes count a number of
    /// seconds. The delay runs from when the load starts spawning, and is
    /// extended (with a warning) if it would end before the load has settled.
    func startFromLaunchArgumentsIfNeeded() {
        guard !launchArgumentsChecked else { return }
        launchArgumentsChecked = true
        guard !isBusy, let modeName = Self.argument("EnsoSwitchTest") else { return }
        isBusy = true

        let outputPath = Self.argument("EnsoSwitchTestOutput").map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).path
        }
        // A marker left by an earlier run would end the script's wait early.
        if let outputPath {
            try? FileManager.default.removeItem(atPath: Self.markerPath(for: outputPath))
        }
        let mode = Mode(rawValue: modeName)
        let count = Self.argument("EnsoSwitchTestCount").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        let options = Options(
            modeName: modeName,
            count: count ?? mode?.defaultCount ?? 0,
            label: Self.argument("EnsoSwitchTestLabel") ?? "manual",
            outputPath: outputPath,
            copiesToPasteboard: false,
            bringsAppForward: true
        )
        var delay = max(0, Self.argument("EnsoSwitchTestDelay").flatMap(Double.init) ?? 5)
        if let text = Self.argument("EnsoSwitchTestLoad") {
            let state = LoadState(requested: text)
            load = state
            startLoad(state)
            let needed = state.spawnSeconds + Self.loadMinimumSettle
            if delay < needed {
                state.warnings.append("Delay raised from \(delay)s to \(needed)s so the load can settle")
                delay = needed
            }
            state.effectiveDelaySeconds = delay
        }
        schedule(after: delay) { [weak self] in
            self?.begin(options, attemptsLeft: Self.windowRetryLimit)
        }
    }

    private static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-" + name),
              arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    // MARK: Run

    private func begin(_ options: Options, attemptsLeft: Int) {
        guard let mode = Mode(rawValue: options.modeName) else {
            finishWithError("Unknown mode \"\(options.modeName)\" (expected paced, burst or observe)", options: options)
            return
        }
        guard let store = PerfMonitor.shared.store,
              let window = Self.findWindow(for: store),
              let contentView = window.contentView else {
            if attemptsLeft > 0 {
                schedule(after: Self.windowRetryInterval) { [weak self] in
                    self?.begin(options, attemptsLeft: attemptsLeft - 1)
                }
            } else {
                finishWithError("No store or window to test", options: options)
            }
            return
        }
        guard store.spaces.count >= 2 else {
            finishWithError("Needs at least 2 spaces, found \(store.spaces.count)", options: options)
            return
        }

        if options.bringsAppForward {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }

        let run = Run(mode: mode, options: options, store: store, window: window)
        self.run = run

        let maxFPS = window.screen?.maximumFramesPerSecond ?? 120
        let expectedSeconds = Self.baselineDuration + Double(options.count) * mode.interval + mode.tail + 1
        let capacity = Int(expectedSeconds * Double(max(maxFPS, 60)))
        run.frameTimes.reserveCapacity(capacity)
        run.arrivalTimes.reserveCapacity(capacity)
        run.frameDurations.reserveCapacity(capacity)
        run.switches.reserveCapacity(options.count)

        let link = contentView.displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        // A variable-refresh display may otherwise call back slower than the
        // link's `duration` says, making every gap look late.
        if maxFPS > 0 {
            let fps = Float(maxFPS)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        }
        link.add(to: .main, forMode: .common)
        run.link = link
        run.liveAtStart = store.sessions.filter {
            GhosttySurfaceManager.shared.existingView(for: $0.id) != nil
        }.count
        load?.sampleStreamingScreens()
        if mode == .observe {
            // @Published fires in willSet, so the store still reads the old
            // space here; the new one comes in as the value.
            run.spaceChanges = store.$activeSpaceID.dropFirst().sink { [weak self] newSpace in
                MainActor.assumeIsolated {
                    self?.recordObservedChange(to: newSpace)
                }
            }
        }

        if let cpu = PerfMonitor.processCPUSeconds() {
            run.baselineCPU = (cpu, PerfMonitor.monotonicSeconds())
        }
        run.timer = schedule(after: Self.baselineDuration) { [weak self] in
            self?.baselineFinished()
        }
    }

    private func baselineFinished() {
        guard let run else { return }
        run.baselineEndIndex = run.frameTimes.count
        let cpu = PerfMonitor.processCPUSeconds()
        let wall = PerfMonitor.monotonicSeconds()
        if let cpu, let start = run.baselineCPU {
            run.baselineCPUPercent = Self.cpuPercent(from: start, toCPU: cpu, toWall: wall)
        }
        if let cpu {
            run.switchCPU = (cpu, wall)
        }

        if run.mode == .observe {
            run.timer = schedule(after: TimeInterval(run.options.count)) { [weak self] in
                self?.finish(abortReason: nil)
            }
            return
        }

        performSwitch()
        guard self.run != nil, run.switches.count < run.options.count else { return }
        let timer = Timer(timeInterval: run.mode.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.performSwitch()
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        run.timer = timer
    }

    private func performSwitch() {
        guard let run else { return }
        guard let store = run.store else {
            finish(abortReason: "Store went away")
            return
        }
        guard let window = run.window, window.isVisible else {
            finish(abortReason: "Window went away")
            return
        }
        let spaces = store.spaces
        guard spaces.count >= 2 else {
            finish(abortReason: "Fewer than 2 spaces left")
            return
        }
        if !NSApp.isActive { run.appWentInactive = true }
        if !window.occlusionState.contains(.visible) { run.windowWasOccluded = true }

        // The pager can be ahead of the store while a commit is pending.
        let current = SpacePager.current?.targetSpaceID ?? store.activeSpaceID
        let fromIndex = spaces.firstIndex { $0.id == current } ?? 0
        let target = spaces[(fromIndex + 1) % spaces.count]
        let firstVisit = run.visited.insert(target.id).inserted
        let frameIndex = run.frameTimes.count

        // The same call as the sidebar's space indicators (SidebarView).
        let start = CACurrentMediaTime()
        if let pager = SpacePager.current {
            pager.switchSpace(to: target.id)
        } else {
            store.activateSpace(target.id)
        }
        let end = CACurrentMediaTime()

        run.switches.append(SwitchRecord(
            index: run.switches.count,
            fromSpace: spaces[fromIndex].name,
            toSpace: target.name,
            firstVisit: firstVisit,
            frameIndex: frameIndex,
            startTime: start,
            activateMs: (end - start) * 1000,
            terminalAttachedMs: nil
        ))

        let isLast = run.switches.count >= run.options.count
        // Burst: the next switch replaces this; the last one has no next.
        let deadline = (run.mode == .paced || isLast) ? start + Self.measureWindow : CFTimeInterval.infinity
        run.pendingAttach = (run.switches.count - 1, deadline)

        if isLast {
            run.timer?.invalidate()
            run.timer = schedule(after: run.mode.tail) { [weak self] in
                self?.finish(abortReason: nil)
            }
        }
    }

    /// Observe mode's version of a switch: same record, driven from outside.
    private func recordObservedChange(to newSpace: SidebarSpace.ID) {
        guard let run, let store = run.store else { return }
        if !NSApp.isActive { run.appWentInactive = true }
        if let window = run.window, !window.occlusionState.contains(.visible) {
            run.windowWasOccluded = true
        }
        let name: (SidebarSpace.ID) -> String = { id in
            store.spaces.first { $0.id == id }?.name ?? "?"
        }
        let now = CACurrentMediaTime()
        let index = run.switches.count
        run.switches.append(SwitchRecord(
            index: index,
            fromSpace: name(store.activeSpaceID),
            toSpace: name(newSpace),
            firstVisit: run.visited.insert(newSpace).inserted,
            frameIndex: run.frameTimes.count,
            startTime: now,
            activateMs: 0,
            terminalAttachedMs: nil
        ))
        run.pendingAttach = (index, now + Self.measureWindow)
    }

    /// Every scroll event the app receives during an observe run, before the
    /// sidebar's swipe capture can swallow it. Shows whether a synthetic or
    /// replayed gesture reached the app with the deltas and phases it was
    /// sent with. A single comparison when no observe run is active.
    func noteScrollEvent(_ event: NSEvent) {
        guard let run, run.mode == .observe else { return }
        run.scroll.add(event)
    }

    /// Runs on every frame during a run, so it only appends to reserved
    /// buffers and does one dictionary lookup while an attach is pending.
    @objc private func displayLinkFired(_ link: CADisplayLink) {
        guard let run else { return }
        let now = CACurrentMediaTime()
        run.frameTimes.append(link.timestamp)
        run.arrivalTimes.append(now)
        run.frameDurations.append(link.duration)

        guard let pending = run.pendingAttach else { return }
        // Until the store has moved, the selection is still the old space's.
        if run.store?.activeSpace.name == run.switches[pending.switchIndex].toSpace,
           let selection = run.store?.selection,
           GhosttySurfaceManager.shared.existingView(for: selection)?.window != nil {
            let startTime = run.switches[pending.switchIndex].startTime
            run.switches[pending.switchIndex].terminalAttachedMs = (now - startTime) * 1000
            run.pendingAttach = nil
        } else if now >= pending.deadline {
            run.pendingAttach = nil
        }
    }

    private func finish(abortReason: String?) {
        guard let run else { return }
        run.timer?.invalidate()
        run.timer = nil
        run.link?.invalidate()
        run.link = nil
        run.spaceChanges = nil

        let report = makeReport(for: run, abortReason: abortReason)

        // Back to where the run started, after the measurements are in.
        // Observe mode leaves the app where the driver left it.
        if run.mode != .observe, let store = run.store, store.spaces.contains(where: { $0.id == run.startSpaceID }) {
            let selection = run.startSelection.flatMap { id in
                store.spaces
                    .first { $0.id == run.startSpaceID }?
                    .sessions.contains { $0.id == id } == true ? id : nil
            }
            store.activateSpace(run.startSpaceID, selecting: selection)
        }

        self.run = nil
        write(report, options: run.options)
        isBusy = false
    }

    private func finishWithError(_ message: String, options: Options) {
        let report = Self.baseReport(options: options, startedAt: Date(), error: message)
        write(report, options: options)
        isBusy = false
    }

    // MARK: Window

    /// The window showing a terminal, falling back to the main window while
    /// every tab is asleep. Panels (the sidebar peek) are never the target.
    private static func findWindow(for store: TerminalSessionStore) -> NSWindow? {
        let manager = GhosttySurfaceManager.shared
        if let selection = store.selection,
           let window = manager.existingView(for: selection)?.window, window.isVisible {
            return window
        }
        for session in store.sessions {
            if let window = manager.existingView(for: session.id)?.window, window.isVisible {
                return window
            }
        }
        let candidates = [NSApp.mainWindow, NSApp.keyWindow].compactMap { $0 } + NSApp.windows
        return candidates.first { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }
    }

    // MARK: Metrics

    private struct WindowMetrics {
        var longestGapMs: Double?
        var longestCallbackGapMs: Double?
        var lateFrames = 0
        var lateGaps: [LateGap] = []
    }

    /// Gaps for switch `index`. A gap is indexed by the callback that closes
    /// it, and the first one spans the switch itself, so a stall at the
    /// switch always counts. Burst: everything up to the callback before the
    /// next switch. Otherwise: up to and including the first callback past
    /// the window, so a stall straddling the window's end counts in full.
    private func metrics(forSwitch index: Int, in run: Run) -> WindowMetrics {
        var result = WindowMetrics()
        let record = run.switches[index]
        let frameCount = run.frameTimes.count
        let first = record.frameIndex
        guard first < frameCount else { return result }

        var last = first
        if run.mode == .burst, run.switches.indices.contains(index + 1) {
            last = max(first, run.switches[index + 1].frameIndex - 1)
        } else {
            let windowEnd = record.startTime + Self.measureWindow
            while last < frameCount - 1, run.arrivalTimes[last] < windowEnd {
                last += 1
            }
        }
        last = min(last, frameCount - 1)

        let lowest = max(first, 1)
        guard lowest <= last else { return result }
        for frame in lowest...last {
            let gap = run.frameTimes[frame] - run.frameTimes[frame - 1]
            let callbackGap = run.arrivalTimes[frame] - run.arrivalTimes[frame - 1]
            result.longestGapMs = max(result.longestGapMs ?? 0, gap * 1000)
            result.longestCallbackGapMs = max(result.longestCallbackGapMs ?? 0, callbackGap * 1000)
            if gap > Self.lateFactor * run.frameDurations[frame] {
                result.lateFrames += 1
                result.lateGaps.append(LateGap(
                    startMs: Self.rounded((run.frameTimes[frame - 1] - record.startTime) * 1000),
                    gapMs: Self.rounded(gap * 1000)
                ))
            }
        }
        result.longestGapMs = result.longestGapMs.map(Self.rounded)
        result.longestCallbackGapMs = result.longestCallbackGapMs.map(Self.rounded)
        return result
    }

    /// The 600ms before an observed change, when the fingers were on the
    /// trackpad and the page was tracking them.
    private func preChangeMetrics(forSwitch index: Int, in run: Run) -> (longest: Double?, late: Int) {
        let record = run.switches[index]
        let windowStart = record.startTime - Self.preChangeWindow
        var longest: Double?
        var late = 0
        var frame = min(record.frameIndex, run.frameTimes.count) - 1
        while frame >= 1, run.arrivalTimes[frame] >= windowStart {
            let gap = run.frameTimes[frame] - run.frameTimes[frame - 1]
            longest = max(longest ?? 0, gap * 1000)
            if gap > Self.lateFactor * run.frameDurations[frame] {
                late += 1
            }
            frame -= 1
        }
        return (longest.map(Self.rounded), late)
    }

    private func wholeRunStats(for run: Run) -> WholeRun {
        var gaps: [Double] = []
        var late = 0
        if run.frameTimes.count >= 2 {
            gaps.reserveCapacity(run.frameTimes.count - 1)
            for frame in 1..<run.frameTimes.count {
                let gap = run.frameTimes[frame] - run.frameTimes[frame - 1]
                gaps.append(gap * 1000)
                if gap > Self.lateFactor * run.frameDurations[frame] {
                    late += 1
                }
            }
        }
        let worst = gaps.indices.sorted { gaps[$0] > gaps[$1] }.prefix(Self.worstGapCount).map { index in
            WholeRun.Gap(
                atMs: Self.rounded((run.arrivalTimes[index] - run.startTime) * 1000),
                gapMs: Self.rounded(gaps[index])
            )
        }
        let sorted = gaps.sorted()
        let rank: (Double) -> Double? = { fraction in
            sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int(fraction * Double(sorted.count)))]
        }
        return WholeRun(
            frames: run.frameTimes.count,
            lateFrames: late,
            medianGapMs: Self.median(gaps).map(Self.rounded),
            p95GapMs: rank(0.95).map(Self.rounded),
            p99GapMs: rank(0.99).map(Self.rounded),
            maxGapMs: sorted.last.map(Self.rounded),
            worstGaps: Array(worst)
        )
    }

    private func baselineSummary(for run: Run) -> Baseline {
        let end = run.baselineEndIndex ?? run.frameTimes.count
        var gaps: [Double] = []
        var lateFrames = 0
        if end >= 2 {
            gaps.reserveCapacity(end - 1)
            for frame in 1..<end {
                let gap = run.frameTimes[frame] - run.frameTimes[frame - 1]
                gaps.append(gap * 1000)
                if gap > Self.lateFactor * run.frameDurations[frame] {
                    lateFrames += 1
                }
            }
        }
        return Baseline(
            frameCount: end,
            medianGapMs: Self.median(gaps).map(Self.rounded),
            maxGapMs: gaps.max().map(Self.rounded),
            lateFrames: lateFrames,
            cpuPercent: run.baselineCPUPercent.map(Self.rounded)
        )
    }

    private func makeReport(for run: Run, abortReason: String?) -> Report {
        let cpuEnd = PerfMonitor.processCPUSeconds()
        let wallEnd = PerfMonitor.monotonicSeconds()
        let memoryEnd = PerfMonitor.physicalFootprintBytes()

        let results: [SwitchResult] = run.switches.indices.map { index in
            let record = run.switches[index]
            let metrics = metrics(forSwitch: index, in: run)
            let pre = run.mode == .observe ? preChangeMetrics(forSwitch: index, in: run) : (nil, 0)
            return SwitchResult(
                index: record.index,
                atMs: Self.rounded((record.startTime - run.startTime) * 1000),
                fromSpace: record.fromSpace,
                toSpace: record.toSpace,
                firstVisit: record.firstVisit,
                activateMs: Self.rounded(record.activateMs),
                longestGapMs: metrics.longestGapMs,
                longestCallbackGapMs: metrics.longestCallbackGapMs,
                lateFrames: metrics.lateFrames,
                lateGaps: metrics.lateGaps,
                terminalAttachedMs: record.terminalAttachedMs.map(Self.rounded),
                preChangeLongestGapMs: pre.0,
                preChangeLateFrames: run.mode == .observe ? pre.1 : nil
            )
        }

        let durationsMs = run.frameDurations.map { $0 * 1000 }
        let frameIntervalMs = Self.median(durationsMs)
        let baseline = baselineSummary(for: run)

        var cpuPercent: Double?
        if let cpuEnd, let start = run.switchCPU {
            cpuPercent = Self.cpuPercent(from: start, toCPU: cpuEnd, toWall: wallEnd)
        }

        var achieved: Double?
        if let first = run.switches.first, let last = run.switches.last, run.switches.count >= 2 {
            let elapsed = last.startTime - first.startTime
            if elapsed > 0 {
                achieved = Self.rounded(Double(run.switches.count - 1) / elapsed)
            }
        }

        var warnings: [String] = []
        if run.appWentInactive { warnings.append("App was not frontmost during the run") }
        if run.windowWasOccluded { warnings.append("Window was occluded during the run") }
        if Double(baseline.frameCount) < 30 * Self.baselineDuration {
            warnings.append("Only \(baseline.frameCount) callbacks in the \(Int(Self.baselineDuration))s baseline")
        }
        if let median = baseline.medianGapMs, let interval = frameIntervalMs,
           median > Self.lateFactor * interval {
            warnings.append("Idle callbacks ran slower than the frame interval, so lateFrames overcounts")
        }
        if let lo = durationsMs.min(), let hi = durationsMs.max(), hi - lo > 1 {
            warnings.append("Frame interval changed during the run (\(Self.rounded(lo))-\(Self.rounded(hi))ms)")
        }

        var report = Self.baseReport(options: run.options, startedAt: run.startedAt, error: nil)
        report.abortReason = abortReason
        report.frameIntervalMs = frameIntervalMs.map(Self.rounded)
        report.requestedIntervalMs = run.mode == .observe ? nil : run.mode.interval * 1000
        report.switchesPerformed = results.count
        report.achievedSwitchesPerSecond = achieved
        report.perfBarVisible = run.perfBarVisible
        if let load {
            warnings += load.warnings
            report.load = load.report(liveAtStart: run.liveAtStart)
        }
        report.warnings = warnings
        report.wholeRun = wholeRunStats(for: run)
        if run.mode == .observe {
            report.scroll = run.scroll.report
        }
        report.summary = Summary(
            repeatVisits: Self.groupStats(results.filter { !$0.firstVisit }),
            firstVisits: Self.groupStats(results.filter(\.firstVisit)),
            baseline: baseline,
            cpuPercent: cpuPercent.map(Self.rounded),
            memoryStartMB: run.memoryStart.map(Self.megabytes),
            memoryEndMB: memoryEnd.map(Self.megabytes),
            spaces: run.store?.spaces.count ?? 0,
            tabs: run.store?.sessions.count ?? 0
        )
        report.switches = results
        return report
    }

    private static func groupStats(_ results: [SwitchResult]) -> GroupStats {
        GroupStats(
            count: results.count,
            longestGapMs: stats(results.compactMap(\.longestGapMs)),
            activateMs: stats(results.map(\.activateMs)),
            terminalAttachedMs: stats(results.compactMap(\.terminalAttachedMs)),
            longestCallbackGapMs: stats(results.compactMap(\.longestCallbackGapMs)),
            medianLateFrames: median(results.map { Double($0.lateFrames) })
        )
    }

    private static func stats(_ values: [Double]) -> Stats {
        guard !values.isEmpty else { return Stats(count: 0, median: nil, p95: nil, max: nil) }
        let sorted = values.sorted()
        // Nearest rank, so p95 is always a value that really occurred.
        let rank = Int((0.95 * Double(sorted.count)).rounded(.up)) - 1
        return Stats(
            count: sorted.count,
            median: median(sorted).map(rounded),
            p95: rounded(sorted[min(max(rank, 0), sorted.count - 1)]),
            max: sorted.last.map(rounded)
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private static func cpuPercent(
        from start: (cpuSeconds: Double, wallSeconds: Double),
        toCPU cpu: Double,
        toWall wall: Double
    ) -> Double? {
        guard wall > start.wallSeconds else { return nil }
        return max(0, (cpu - start.cpuSeconds) / (wall - start.wallSeconds) * 100)
    }

    nonisolated private static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    nonisolated private static func megabytes(_ bytes: UInt64) -> Double {
        rounded(Double(bytes) / 1_048_576)
    }

    // MARK: Output

    private func write(_ report: Report, options: Options) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(report)) ?? Data("{\"error\":\"Could not encode the report\"}".utf8)

        let fileManager = FileManager.default
        let url = options.outputPath.map { URL(fileURLWithPath: $0) } ?? Self.defaultOutputURL(options: options)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var failure: String?
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            failure = error.localizedDescription
        }
        // Written even after a failed write: a script is waiting on it.
        fileManager.createFile(atPath: Self.markerPath(for: url.path), contents: Data())

        if options.copiesToPasteboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(String(decoding: data, as: UTF8.self), forType: .string)
        }

        if let failure {
            NSLog("Enso space switch test: could not write %@: %@", url.path, failure)
        } else {
            NSLog("Enso space switch test: wrote %@", url.path)
        }
    }

    private static func markerPath(for path: String) -> String {
        path + ".done"
    }

    private static func defaultOutputURL(options: Options) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "space-switch-\(fileSafe(options.modeName))-\(fileSafe(options.label))-\(formatter.string(from: Date())).json"
        return EnsoAppSupport.directory
            .appendingPathComponent("perf-tests", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func fileSafe(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let mapped = text.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        return mapped.isEmpty ? "manual" : mapped
    }

    private static func baseReport(options: Options, startedAt: Date, error: String?) -> Report {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "ReleaseNext"
        #endif
        return Report(
            label: options.label,
            mode: options.modeName,
            error: error,
            abortReason: nil,
            appVersion: (info["CFBundleShortVersionString"] as? String) ?? "?",
            appBuild: (info["CFBundleVersion"] as? String) ?? "?",
            buildConfiguration: configuration,
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            startedAt: ISO8601DateFormatter().string(from: startedAt),
            frameIntervalMs: nil,
            requestedIntervalMs: nil,
            switchesRequested: options.count,
            switchesPerformed: 0,
            achievedSwitchesPerSecond: nil,
            perfBarVisible: PerfBarController.shared.isVisible,
            warnings: [],
            load: nil,
            wholeRun: nil,
            scroll: nil,
            summary: nil,
            switches: []
        )
    }

    // MARK: Background load

    /// Makes sessions live the way visiting them would, and has some print
    /// like an agent. Never touches a tab that has a restore pending, so a
    /// run against real state can't resume an agent.
    private func startLoad(_ state: LoadState) {
        guard let request = state.request else {
            state.warnings.append("Could not read -EnsoSwitchTestLoad \"\(state.requestedText)\" (expected <live>,<streaming>), no load started")
            return
        }
        guard let store = PerfMonitor.shared.store else {
            state.warnings.append("No store when the load started, no load started")
            return
        }
        let manager = GhosttySurfaceManager.shared
        let agents = AgentSessionStore.shared
        func eligible(_ session: TerminalSession) -> Bool {
            !session.isSleeping && !agents.hasPendingRestore(forTab: session.id)
        }

        // Each space's landing tab first: a space's first visit would create
        // it anyway, and the run shouldn't measure that one spawn.
        let landings: [TerminalSession.ID] = store.spaces.compactMap { space in
            let awake = space.sessions.filter(eligible)
            return (awake.first { $0.id == space.lastSelection } ?? awake.first)?.id
        }
        let others: [[TerminalSession]] = store.spaces.map { space in
            space.sessions.filter { eligible($0) && !landings.contains($0.id) }
        }
        func roundRobin(_ lists: [[TerminalSession]]) -> [TerminalSession.ID] {
            var result: [TerminalSession.ID] = []
            var row = 0
            while lists.contains(where: { row < $0.count }) {
                for list in lists where row < list.count {
                    result.append(list[row].id)
                }
                row += 1
            }
            return result
        }

        // Streaming tabs sit off the active space and, while there are enough
        // others, off the landing tabs: nothing should stream into view.
        let activeIDs = Set(store.activeSpace.sessions.map(\.id))
        let offActive = store.spaces.indices
            .filter { store.spaces[$0].id != store.activeSpaceID }
            .map { others[$0] }
        var streamCandidates = roundRobin(offActive)
        streamCandidates += landings.filter { !activeIDs.contains($0) }
        streamCandidates = streamCandidates.filter { manager.existingView(for: $0) == nil }
        let streamingWanted = min(request.streaming, request.live)
        let streaming = Array(streamCandidates.prefix(streamingWanted))
        if request.streaming > request.live {
            state.warnings.append("Asked for \(request.streaming) streaming tabs but only \(request.live) live ones")
        }
        if streaming.count < streamingWanted {
            state.warnings.append("Only \(streaming.count) of \(streamingWanted) streaming tabs available off the active space")
        }

        var order: [TerminalSession.ID] = []
        for id in landings + streaming + roundRobin(others) where !order.contains(id) {
            order.append(id)
        }
        // The selected tab is live regardless and takes one of the slots.
        let alreadyLive = store.sessions.filter { manager.existingView(for: $0.id) != nil }.map(\.id)
        let selected = store.selection.map { [$0] } ?? []
        let reserved = Set(alreadyLive + selected)
        let spawnCount = max(0, request.live - reserved.count)
        // Streaming tabs first, so a small live count can't crowd them out.
        let chosen = Array((streaming + order.filter { !streaming.contains($0) && !reserved.contains($0) })
            .prefix(max(spawnCount, streaming.count)))
        if chosen.count + reserved.count < request.live {
            state.warnings.append("Only \(chosen.count + reserved.count) of \(request.live) live tabs available")
        }

        state.streamingIDs = streaming
        state.spawnSeconds = Double(chosen.count) * Self.loadSpawnInterval
        for id in streaming {
            manager.devInitialInput[id] = LoadState.streamingCommand
        }
        for (index, id) in chosen.enumerated() {
            schedule(after: Double(index) * Self.loadSpawnInterval) {
                guard let session = store.sessions.first(where: { $0.id == id }),
                      !session.isSleeping else { return }
                store.wireSurfaceCallbacks(manager.view(for: session), for: id)
            }
        }
    }

    // MARK: Timers

    /// One-shot main run loop timer in common modes, so nothing stalls
    /// during tracking.
    @discardableResult
    private func schedule(after delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

// MARK: - Background load state

private final class LoadState {
    struct Request {
        let live: Int
        let streaming: Int
    }

    /// In every streaming tab's output, so a later read of the screen can
    /// tell the loop is really running.
    nonisolated static let marker = "enso-switch-test-load"

    /// About 30 coloured lines a second: three lines, then a tenth of a second
    /// of sleep, which forks one `sleep` ten times a second rather than thirty.
    /// Prints text only: no files, no network. Bounded to an hour, after which
    /// it falls back to the tab's prompt. The leading space and unset keep it
    /// out of the shell history, and the tab has no agent to wrap it.
    nonisolated static let streamingCommand: String = {
        let line = "\\033[2m%05d\\033[0m \\033[%dm" + marker + "\\033[0m reading src/module_%d.swift "
            + "\\033[32m+%d\\033[0m lines, \\033[33mstep %d\\033[0m of a long running plan\\n"
        let one = "i=$((i+1)); printf \"\(line)\" $i $((31+i%6)) $((i%97)) $((i%400)) $((i%23)); "
        let loop = "i=0; while [ $i -lt 108000 ]; do \(one)\(one)\(one)sleep 0.1; done"
        return " unset HISTFILE; /bin/sh -c '\(loop)'\n"
    }()

    let requestedText: String
    let request: Request?
    var streamingIDs: [TerminalSession.ID] = []
    var spawnSeconds: TimeInterval = 0
    var effectiveDelaySeconds: TimeInterval = 0
    var warnings: [String] = []
    /// Each streaming tab's screen when recording started.
    private var screenSamples: [TerminalSession.ID: String] = [:]

    init(requested text: String) {
        requestedText = text
        let parts = text.split(separator: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, let live = parts[0], let streaming = parts[1], live >= 0, streaming >= 0 {
            request = Request(live: live, streaming: streaming)
        } else {
            request = nil
        }
    }

    func sampleStreamingScreens() {
        for id in streamingIDs {
            screenSamples[id] = GhosttySurfaceManager.shared.existingView(for: id)?.screenContents() ?? ""
        }
    }

    func report(liveAtStart: Int) -> LoadReport {
        // Printing means the marker is on screen and the screen has changed
        // since recording started.
        let verified = streamingIDs.filter { id in
            guard let text = GhosttySurfaceManager.shared.existingView(for: id)?.screenContents() else {
                return false
            }
            return text.contains(Self.marker) && text != screenSamples[id]
        }.count
        if verified < streamingIDs.count {
            warnings.append("Only \(verified) of \(streamingIDs.count) streaming tabs were seen printing")
        }
        return LoadReport(
            requestedLive: request?.live ?? 0,
            requestedStreaming: request?.streaming ?? 0,
            liveAtStart: liveAtStart,
            streaming: streamingIDs.count,
            streamingVerified: verified,
            effectiveDelaySeconds: effectiveDelaySeconds
        )
    }
}

private struct ScrollDiagnostics {
    var events = 0
    var precise = 0
    var began = 0
    var changed = 0
    var ended = 0
    var cancelled = 0
    var mayBegin = 0
    var momentumBegan = 0
    var momentumChanged = 0
    var momentumEnded = 0
    var sumScrollingDeltaX: Double = 0
    var sumScrollingDeltaY: Double = 0
    var maxAbsScrollingDeltaX: Double = 0

    mutating func add(_ event: NSEvent) {
        events += 1
        if event.hasPreciseScrollingDeltas { precise += 1 }
        switch event.phase {
        case .began: began += 1
        case .changed: changed += 1
        case .ended: ended += 1
        case .cancelled: cancelled += 1
        case .mayBegin: mayBegin += 1
        default: break
        }
        switch event.momentumPhase {
        case .began: momentumBegan += 1
        case .changed: momentumChanged += 1
        case .ended: momentumEnded += 1
        default: break
        }
        sumScrollingDeltaX += event.scrollingDeltaX
        sumScrollingDeltaY += event.scrollingDeltaY
        maxAbsScrollingDeltaX = max(maxAbsScrollingDeltaX, abs(event.scrollingDeltaX))
    }

    var report: ScrollReport {
        ScrollReport(
            events: events,
            precise: precise,
            began: began,
            changed: changed,
            ended: ended,
            cancelled: cancelled,
            mayBegin: mayBegin,
            momentumBegan: momentumBegan,
            momentumChanged: momentumChanged,
            momentumEnded: momentumEnded,
            sumScrollingDeltaX: sumScrollingDeltaX,
            sumScrollingDeltaY: sumScrollingDeltaY,
            maxAbsScrollingDeltaX: maxAbsScrollingDeltaX
        )
    }
}

// MARK: - Report

/// Encodes nil as an explicit JSON null; synthesized Encodable would drop
/// the key, and a script reading the report expects every field present.
@propertyWrapper
private struct Nullable<Value: Encodable>: Encodable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

private struct LateGap: Encodable {
    /// When the gap opened, relative to the switch (negative when it opened
    /// before the switch and spans it).
    let startMs: Double
    let gapMs: Double
}

private struct SwitchResult: Encodable {
    let index: Int
    /// Since recording started.
    let atMs: Double
    let fromSpace: String
    let toSpace: String
    let firstVisit: Bool
    let activateMs: Double
    @Nullable var longestGapMs: Double?
    /// The same gap from when callbacks actually ran, not their frame times.
    @Nullable var longestCallbackGapMs: Double?
    let lateFrames: Int
    let lateGaps: [LateGap]
    @Nullable var terminalAttachedMs: Double?
    /// Observe only: the 600ms leading up to the change.
    @Nullable var preChangeLongestGapMs: Double?
    @Nullable var preChangeLateFrames: Int?
}

private struct Stats: Encodable {
    let count: Int
    @Nullable var median: Double?
    @Nullable var p95: Double?
    @Nullable var max: Double?
}

private struct GroupStats: Encodable {
    let count: Int
    let longestGapMs: Stats
    let activateMs: Stats
    let terminalAttachedMs: Stats
    let longestCallbackGapMs: Stats
    @Nullable var medianLateFrames: Double?
}

private struct Baseline: Encodable {
    let frameCount: Int
    @Nullable var medianGapMs: Double?
    @Nullable var maxGapMs: Double?
    let lateFrames: Int
    @Nullable var cpuPercent: Double?
}

private struct Summary: Encodable {
    let repeatVisits: GroupStats
    let firstVisits: GroupStats
    let baseline: Baseline
    /// From the first switch to the end of the run, excluding the baseline.
    /// 100 means one full core.
    @Nullable var cpuPercent: Double?
    @Nullable var memoryStartMB: Double?
    @Nullable var memoryEndMB: Double?
    let spaces: Int
    let tabs: Int
}

private struct LoadReport: Encodable {
    let requestedLive: Int
    let requestedStreaming: Int
    /// Live sessions when recording started, the selected tab included.
    let liveAtStart: Int
    let streaming: Int
    /// Streaming tabs whose screen showed the loop's output and had changed
    /// since recording started.
    let streamingVerified: Int
    let effectiveDelaySeconds: Double
}

/// Every frame of the run, baseline included.
private struct WholeRun: Encodable {
    struct Gap: Encodable {
        /// When the gap closed, since recording started.
        let atMs: Double
        let gapMs: Double
    }

    let frames: Int
    let lateFrames: Int
    @Nullable var medianGapMs: Double?
    @Nullable var p95GapMs: Double?
    @Nullable var p99GapMs: Double?
    @Nullable var maxGapMs: Double?
    let worstGaps: [Gap]
}

private struct ScrollReport: Encodable {
    let events: Int
    let precise: Int
    let began: Int
    let changed: Int
    let ended: Int
    let cancelled: Int
    let mayBegin: Int
    let momentumBegan: Int
    let momentumChanged: Int
    let momentumEnded: Int
    let sumScrollingDeltaX: Double
    let sumScrollingDeltaY: Double
    let maxAbsScrollingDeltaX: Double
}

private struct Report: Encodable {
    let label: String
    let mode: String
    @Nullable var error: String?
    @Nullable var abortReason: String?
    let appVersion: String
    let appBuild: String
    let buildConfiguration: String
    let macOS: String
    let startedAt: String
    @Nullable var frameIntervalMs: Double?
    @Nullable var requestedIntervalMs: Double?
    let switchesRequested: Int
    var switchesPerformed: Int
    @Nullable var achievedSwitchesPerSecond: Double?
    var perfBarVisible: Bool
    var warnings: [String]
    @Nullable var load: LoadReport?
    @Nullable var wholeRun: WholeRun?
    @Nullable var scroll: ScrollReport?
    @Nullable var summary: Summary?
    var switches: [SwitchResult]
}
#endif
