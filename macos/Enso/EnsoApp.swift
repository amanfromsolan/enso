//
//  EnsoApp.swift
//  Enso
//
//  Created by aman on 09/06/26.
//

import SwiftUI

/// Root Application Support directory for this build identity. Three build
/// identities can run side by side — Dev (debug builds), Next (the
/// pre-release channel), and stable Enso — and two live apps sharing
/// state.json is last-writer-wins data loss: whichever saves second silently
/// erases the other's tabs. So each identity gets its own folder; Dev and
/// Next seed themselves once with a COPY of the stable release's state so
/// they start from real tabs without ever writing back.
enum EnsoAppSupport {
    /// Folder name for this build identity. Debug builds are "Enso Dev"
    /// (compile-time — they keep the .debug bundle id). Release-family
    /// builds distinguish Next from stable at runtime by bundle id suffix,
    /// since ReleaseNext compiles without DEBUG.
    static let folderName: String = {
        #if DEBUG
        return "Enso Dev"
        #else
        if Bundle.main.bundleIdentifier?.hasSuffix(".next") == true {
            return "Enso Next"
        }
        return "Enso"
        #endif
    }()

    static let directory: URL = {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = appSupport.appendingPathComponent(folderName, isDirectory: true)

        // Stable keeps its historical behavior untouched (no eager create,
        // no seeding — TerminalSessionStore owns that path's lifecycle).
        guard folderName != "Enso" else { return dir }

        if !fm.fileExists(atPath: dir.path) {
            #if DEBUG
            // One-time migration: debug builds were "Enso Nightly" before
            // the Dev rename. MOVE the old folder so existing dev state
            // (tabs, agent sessions, shims) survives the rename.
            let legacy = appSupport.appendingPathComponent("Enso Nightly", isDirectory: true)
            if fm.fileExists(atPath: legacy.path) {
                try? fm.moveItem(at: legacy, to: dir)
            }
            #endif
            if !fm.fileExists(atPath: dir.path) {
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let releaseState = appSupport.appendingPathComponent("Enso/state.json")
                if fm.fileExists(atPath: releaseState.path) {
                    try? fm.copyItem(
                        at: releaseState,
                        to: dir.appendingPathComponent("state.json")
                    )
                }
            }
        }
        return dir
    }()
}

/// Finder Services entry point: right-click a folder → "New Enso Terminal
/// Here" opens a tab at that directory (declared in Info.plist NSServices).
@MainActor
final class ServiceProvider: NSObject {
    static let shared = ServiceProvider()

    private weak var store: TerminalSessionStore?
    /// Requests that arrived before launch finished attaching the store.
    private var pendingPaths: [String] = []

    func attach(store: TerminalSessionStore) {
        self.store = store
        let paths = pendingPaths
        pendingPaths = []
        paths.forEach(openTerminal(at:))
    }

    @objc func newTerminalHere(
        _ pasteboard: NSPasteboard,
        userData: String,
        error: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        var paths: [String] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            paths = urls.map(\.path)
        } else if let names = pasteboard.propertyList(
            forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ) as? [String] {
            paths = names
        } else if let text = pasteboard.string(forType: .string) {
            paths = [text]
        }

        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let directory = isDirectory.boolValue ? path : (path as NSString).deletingLastPathComponent
            openTerminal(at: directory)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openTerminal(at path: String) {
        guard let store else {
            pendingPaths.append(path)
            return
        }
        store.createSession(workingDirectory: path)
    }
}

@main
struct EnsoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var sessionStore: TerminalSessionStore

    init() {
        // macOS ships with font smoothing off since Big Sur, which renders
        // small light-on-dark UI text thin and brittle. Opt this app back in
        // (CoreText reads the app's preference domain at startup).
        if UserDefaults.standard.object(forKey: "AppleFontSmoothing") == nil {
            UserDefaults.standard.set(2, forKey: "AppleFontSmoothing")
        }

        // Start libghostty before any view reads the theme background.
        GhosttyRuntime.shared.ensureStarted()

        // Pin the app light/dark if the user chose to; system otherwise.
        AppAppearance.applyStored()

        // Agent-session persistence must be ready before the first surface
        // spawns a shell: shims on disk, and restore decisions made against
        // the loaded tabs (which also drives orphan GC of old map files).
        let store = TerminalSessionStore()
        _sessionStore = StateObject(wrappedValue: store)
        AgentShimInstaller.installIfNeeded()
        AgentSessionStore.shared.bootstrap(knownTabIDs: Set(store.sessions.map(\.id)))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(store: sessionStore)
                .frame(minWidth: 920, minHeight: 560)
                .onAppear {
                    TabAutoNamer.shared.configure(store: sessionStore)
                    ServiceProvider.shared.attach(store: sessionStore)
                    QuitGuard.shared.attach(store: sessionStore)
                    NSApp.servicesProvider = ServiceProvider.shared
                    UpdateController.shared.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            TerminalCommands(store: sessionStore)
        }

        // Settings as its own fixed-size window (⌘,). A custom Window scene
        // instead of Settings {} so the design keeps its own chrome.
        Window("Settings", id: SettingsPanel.windowID) {
            SettingsPanelView(panel: SettingsPanel.shared)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}
