import AppKit
import Combine
@preconcurrency import Sparkle

/// Drives Sparkle updates with Enso's own UI instead of Sparkle's dialogs.
///
/// Scheduled checks run in the background (SUEnableAutomaticChecks); when an
/// update exists the sidebar shows ``UpdateCardView`` and every step —
/// download, extract, restart — is user-driven from that card. Sparkle's
/// `SPUUserDriver` is `@MainActor`, so callbacks mutate `phase` directly.
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    enum Phase: Hashable {
        case idle
        /// Manual check in flight (background checks stay invisible until found).
        case checking
        case available(version: String)
        /// `fraction` is nil until the expected content length is known.
        case downloading(fraction: Double?)
        case extracting(fraction: Double)
        case readyToRestart(version: String)
        case installing
        /// Transient confirmation after a manual check finds nothing.
        case upToDate
        case failed(message: String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Parsed release notes for the pending update (nil when the appcast
    /// had none worth showing); drives the card's "What's New" button.
    @Published private(set) var releaseNotes: WhatsNewSheet.Content?
    @Published var isShowingWhatsNew = false

    let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"

    private var updater: SPUUpdater?
    /// Pending Sparkle replies; the card's buttons consume them.
    private var updateChoice: (@Sendable (SPUUserUpdateChoice) -> Void)?
    private var restartChoice: (@Sendable (SPUUserUpdateChoice) -> Void)?
    private var pendingVersion = ""
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var autoDismiss: Task<Void, Never>?

    func start() {
        guard updater == nil else { return }
        #if DEBUG
        // Day-to-day dev runs never hit the public appcast; opt in with
        // ENSO_SPARKLE=1 to exercise the real update flow from Xcode.
        guard ProcessInfo.processInfo.environment["ENSO_SPARKLE"] == "1" else { return }
        #endif
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: self,
            delegate: self
        )
        do {
            try updater.start()
            self.updater = updater
        } catch {
            // Never surface startup failures in the card; updates just stay off.
        }
    }

    /// Manual "Check for Updates…" from the menu or command palette.
    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    // MARK: - Card actions

    func installNow() {
        isShowingWhatsNew = false
        updateChoice?(.install)
        updateChoice = nil
    }

    func showWhatsNew() {
        guard releaseNotes != nil else { return }
        isShowingWhatsNew = true
    }


    func closeWhatsNew() {
        isShowingWhatsNew = false
    }

    /// Sparkle remembers the skipped version itself (SUSkippedVersion), so
    /// background checks stay quiet about it and surface the next one.
    func skipThisVersion() {
        isShowingWhatsNew = false
        updateChoice?(.skip)
        updateChoice = nil
        phase = .idle
    }

    func restartNow() {
        phase = .installing
        restartChoice?(.install)
        restartChoice = nil
    }

    func dismiss() {
        autoDismiss?.cancel()
        isShowingWhatsNew = false
        updateChoice?(.dismiss)
        updateChoice = nil
        restartChoice?(.dismiss)
        restartChoice = nil
        phase = .idle
    }

    #if DEBUG
    /// Design scaffold: fakes a found update (with notes run through the
    /// real parser) so the sidebar card and What's New sheet can be
    /// exercised in dev builds, where Sparkle is off. The Update button
    /// no-ops — there's no pending Sparkle reply to consume.
    func debugSimulateUpdateFound() {
        pendingVersion = "0.5.0"
        releaseNotes = ReleaseNotesParser.parse(html: Self.debugNotesHTML, version: pendingVersion)
        phase = .available(version: pendingVersion)
        // ENSO_WHATS_NEW=sheet lands straight in the sheet (design
        // iteration without reaching for the card's button).
        if ProcessInfo.processInfo.environment["ENSO_WHATS_NEW"] == "sheet" {
            isShowingWhatsNew = true
        }
    }

    /// What script/release_notes.py emits for RELEASE_NOTES/0.5.0.md.
    private static let debugNotesHTML = """
    <h2>New</h2>
    <ul>
    <li>Release notes now show up right in the app when an update is ready — no more guessing what changed.</li>
    <li>Right-click a folder in Finder → New Enso Terminal Here.</li>
    </ul>
    <h2>Improved</h2>
    <ul>
    <li>The sidebar update card keeps its layout in narrow sidebars instead of wrapping.</li>
    <li>Quit confirmation is bigger and easier to read.</li>
    </ul>
    <h2>Fixed</h2>
    <ul>
    <li>Command palette no longer spawns a stray terminal when you press Enter.</li>
    <li>Fixed a crash at launch when the updater framework failed to load.</li>
    </ul>
    """
    #endif

    private func flashUpToDate() {
        phase = .upToDate
        autoDismiss?.cancel()
        autoDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.phase == .upToDate else { return }
            self.phase = .idle
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: @preconcurrency SPUUpdaterDelegate {
    /// The Next channel (bundle id suffix ".next") updates from its own
    /// appcast on the rolling `next` GitHub release; stable falls through
    /// (nil) to the SUFeedURL in Info.plist. Runtime override beats Info.plist
    /// preprocessing: one plist serves every configuration.
    func feedURLString(for updater: SPUUpdater) -> String? {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".next") == true else { return nil }
        return "https://github.com/amanfromsolan/enso/releases/download/next/enso-next-appcast.xml"
    }
}

// MARK: - SPUUserDriver

extension UpdateController: @preconcurrency SPUUserDriver {
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
    ) {
        // Never show Sparkle's permission dialog: scheduled checks on,
        // automatic downloads off so installs stay user-driven.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping @Sendable () -> Void) {
        phase = .checking
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    ) {
        pendingVersion = appcastItem.displayVersionString
        releaseNotes = ReleaseNotesParser.parse(
            html: appcastItem.itemDescription ?? "",
            version: pendingVersion
        )
        updateChoice = reply
        phase = .available(version: pendingVersion)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping @Sendable () -> Void
    ) {
        acknowledgement()
        flashUpToDate()
    }

    func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping @Sendable () -> Void
    ) {
        acknowledgement()
        phase = .failed(message: error.localizedDescription)
    }

    func showDownloadInitiated(cancellation: @escaping @Sendable () -> Void) {
        expectedBytes = 0
        receivedBytes = 0
        phase = .downloading(fraction: nil)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedBytes = expectedContentLength
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        receivedBytes += length
        guard expectedBytes > 0 else { return }
        phase = .downloading(fraction: min(1, Double(receivedBytes) / Double(expectedBytes)))
    }

    func showDownloadDidStartExtractingUpdate() {
        phase = .extracting(fraction: 0)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        phase = .extracting(fraction: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void) {
        restartChoice = reply
        phase = .readyToRestart(version: pendingVersion)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping @Sendable () -> Void
    ) {
        phase = .installing
        if !applicationTerminated {
            retryTerminatingApplication()
        }
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping @Sendable () -> Void
    ) {
        acknowledgement()
        phase = .idle
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        updateChoice = nil
        restartChoice = nil
        // Sparkle ends every session through here; keep states the user still
        // needs to read (up-to-date flash, errors) on screen.
        switch phase {
        case .upToDate, .failed, .installing:
            break
        default:
            phase = .idle
        }
    }
}
