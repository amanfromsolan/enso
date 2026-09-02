import AppKit
import GhosttyKit
import SwiftUI

/// Owns the single libghostty app instance: global init, config loading,
/// runtime callbacks, and the main-thread tick loop driven by ghostty wakeups.
///
/// The C callbacks fire on ghostty's internal threads, so everything they
/// touch is nonisolated and they hop to the main actor for UI work.
final class GhosttyRuntime {
    static let shared = GhosttyRuntime()

    nonisolated(unsafe) private(set) var app: ghostty_app_t?
    nonisolated(unsafe) private var config: ghostty_config_t?

    /// Terminal background from the loaded ghostty config, so surrounding
    /// chrome (title strip, empty states) blends with the terminal theme.
    private(set) var themeBackground: Color = Color(red: 0.018, green: 0.019, blue: 0.023)

    nonisolated private let tickLock = NSLock()
    nonisolated(unsafe) private var tickScheduled = false
    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Must be called on the main thread before creating any surface.
    func ensureStarted() {
        guard app == nil else { return }

        // libghostty resolves its resources dir from GHOSTTY_RESOURCES_DIR
        // before falling back to bundle detection — and when Enso is launched
        // from inside another Ghostty-based terminal (including Enso itself),
        // that inherited var points at the OTHER app's bundle, so tabs source
        // a foreign shell integration. Pin it to our own bundle, the same way
        // Ghostty.app does.
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("ghostty", isDirectory: true),
           FileManager.default.fileExists(atPath: resources.path) {
            setenv("GHOSTTY_RESOURCES_DIR", resources.path, 1)
        }

        // Launching Enso from inside an agent session (Claude Code's shell,
        // an Enso tab, codex) leaks that session's identity into every tab we
        // spawn — the agent shims would then treat the user's own launches as
        // nested runs and stay inert. Our tabs are fresh sessions, never
        // nested inside whatever started the app.
        for inherited in [
            "CLAUDECODE", "CODEX_SANDBOX", "ENSO_AGENT_ACTIVE",
            "ENSO_TAB_ID", "ENSO_SHIM_DIR", "ENSO_SESSIONS_DIR", "ENSO_SHIM_DEPTH",
        ] {
            unsetenv(inherited)
        }

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("GhosttyRuntime: ghostty_init failed")
            return
        }

        let config = loadConfig()
        self.config = config

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = false

        // Fires on ghostty's internal threads whenever the app needs a tick.
        runtimeConfig.wakeup_cb = { userdata in
            guard let userdata else { return }
            Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue().scheduleTick()
        }

        runtimeConfig.action_cb = { app, target, action in
            GhosttyRuntime.handleAction(app: app, target: target, action: action)
        }

        // Clipboard callbacks receive the *surface* userdata (the view).
        runtimeConfig.read_clipboard_cb = { userdata, location, state, mimes, mimesLen, list in
            guard let userdata, location == GHOSTTY_CLIPBOARD_STANDARD else {
                return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
            }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            // The MIME list is borrowed; copy it before leaving the callback.
            var wantsText = false
            if let mimes {
                for index in 0..<mimesLen where mimes[index].map({ String(cString: $0).hasPrefix("text/") }) == true {
                    wantsText = true
                    break
                }
            }
            let wantsList = list
            Task { @MainActor in
                guard let surface = view.surface else { return }
                var contents: [(mime: String, text: String)] = []
                if wantsText {
                    contents.append(("text/plain", NSPasteboard.general.string(forType: .string) ?? ""))
                }
                GhosttyRuntime.completeClipboardRequest(
                    surface,
                    contents: contents,
                    available: wantsList ? ["text/plain"] : [],
                    state: state,
                    confirmed: false)
            }
            return GHOSTTY_CLIPBOARD_READ_STARTED
        }

        // Unsafe-paste style confirmations: auto-confirm for now.
        runtimeConfig.confirm_read_clipboard_cb = { userdata, confirm, state, _ in
            guard let userdata else { return }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            // The payload is borrowed C memory; copy it before leaving the callback.
            var contents: [(mime: String, text: String)] = []
            var available: [String] = []
            if let confirm {
                let payload = confirm.pointee
                if let items = payload.contents {
                    for index in 0..<payload.contents_len {
                        let item = items[index]
                        guard let mime = item.mime, let data = item.data else { continue }
                        let bytes = Data(bytes: data, count: item.len)
                        contents.append((String(cString: mime), String(data: bytes, encoding: .utf8) ?? ""))
                    }
                }
                if let names = payload.available {
                    for index in 0..<payload.available_len {
                        guard let ptr = names[index] else { continue }
                        available.append(String(cString: ptr))
                    }
                }
            }
            Task { @MainActor in
                guard let surface = view.surface else { return }
                GhosttyRuntime.completeClipboardRequest(
                    surface,
                    contents: contents,
                    available: available,
                    state: state,
                    confirmed: true)
            }
        }

        runtimeConfig.write_clipboard_cb = { _, location, items, count, _ in
            guard location == GHOSTTY_CLIPBOARD_STANDARD, let items, count > 0 else { return }
            var text: String?
            for index in 0..<count {
                let item = items[index]
                guard let mime = item.mime, let data = item.data else { continue }
                if String(cString: mime).hasPrefix("text/") {
                    text = String(cString: data)
                    break
                }
            }
            guard let text else { return }
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }

        runtimeConfig.close_surface_cb = { userdata, _ in
            guard let userdata else { return }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            Task { @MainActor in
                view.surfaceDidRequestClose()
            }
        }

        var app = ghostty_app_new(&runtimeConfig, config)
        if app == nil {
            // A broken user config can fail app creation; retry with defaults.
            NSLog("GhosttyRuntime: ghostty_app_new failed, retrying with default config")
            if let config {
                ghostty_config_free(config)
            }
            let fallback = ghostty_config_new()
            ghostty_config_finalize(fallback)
            self.config = fallback
            app = ghostty_app_new(&runtimeConfig, fallback)
        }
        self.app = app

        guard let app else {
            NSLog("GhosttyRuntime: could not create ghostty app")
            return
        }

        // NSApp is nil when started from App.init, before NSApplication exists.
        ghostty_app_set_focus(app, NSApp?.isActive ?? true)
        installObservers()
        NSLog("GhosttyRuntime: started")
    }

    /// Completes a clipboard read with the struct-based payload libghostty
    /// expects, copying the Swift strings into C memory for the call.
    @MainActor
    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        contents: [(mime: String, text: String)],
        available: [String],
        state: UnsafeMutableRawPointer?,
        confirmed: Bool
    ) {
        var cStrings: [UnsafeMutablePointer<CChar>] = []
        defer { cStrings.forEach { free($0) } }

        var cContents: [ghostty_clipboard_content_s] = []
        for entry in contents {
            guard let mime = strdup(entry.mime), let data = strdup(entry.text) else { continue }
            cStrings.append(mime)
            cStrings.append(data)
            cContents.append(ghostty_clipboard_content_s(
                mime: mime,
                data: data,
                len: entry.text.utf8.count))
        }
        var cAvailable: [UnsafePointer<CChar>?] = []
        for mime in available {
            guard let copy = strdup(mime) else { continue }
            cStrings.append(copy)
            cAvailable.append(UnsafePointer(copy))
        }

        cContents.withUnsafeBufferPointer { contentsBuf in
            cAvailable.withUnsafeBufferPointer { availableBuf in
                var payload = ghostty_clipboard_complete_s(
                    contents: contentsBuf.baseAddress,
                    contents_len: contentsBuf.count,
                    available: availableBuf.baseAddress,
                    available_len: availableBuf.count,
                    confirmed: confirmed,
                    remember: false)
                ghostty_surface_complete_clipboard_request(surface, &payload, state)
            }
        }
    }

    private func loadConfig() -> ghostty_config_t? {
        let config = ghostty_config_new()
        // Respect the user's Ghostty config (fonts, theme) when present.
        ghostty_config_load_default_files(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)

        var background = ghostty_config_color_s()
        let key = "background"
        if key.withCString({ ghostty_config_get(config, &background, $0, UInt(key.utf8.count)) }) {
            themeBackground = Color(
                red: Double(background.r) / 255,
                green: Double(background.g) / 255,
                blue: Double(background.b) / 255
            )
        }

        return config
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })
        observers.append(center.addObserver(
            forName: NSTextInputContext.keyboardSelectionDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_keyboard_changed(app)
        })
    }

    /// Coalesces wakeups (which arrive on arbitrary threads) into a single
    /// main-queue ghostty_app_tick. No display link, no manual draw loop —
    /// ghostty's renderer thread drives drawing.
    nonisolated private func scheduleTick() {
        tickLock.lock()
        let alreadyScheduled = tickScheduled
        tickScheduled = true
        tickLock.unlock()
        guard !alreadyScheduled else { return }

        Task { @MainActor [self] in
            tickLock.lock()
            tickScheduled = false
            tickLock.unlock()
            if let app {
                ghostty_app_tick(app)
            }
        }
    }

    nonisolated private static func handleAction(
        app: ghostty_app_t?,
        target: ghostty_target_s,
        action: ghostty_action_s
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let userdata = ghostty_surface_userdata(surface),
                  let titlePtr = action.action.set_title.title
            else { return false }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            let title = String(cString: titlePtr)
            Task { @MainActor in
                view.onTitleChange?(title)
            }
            return true

        case GHOSTTY_ACTION_PWD:
            NSLog("GhosttyRuntime: PWD action received")
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let userdata = ghostty_surface_userdata(surface),
                  let pwdPtr = action.action.pwd.pwd
            else {
                NSLog("GhosttyRuntime: PWD action guard failed")
                return false
            }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            let pwd = String(cString: pwdPtr)
            Task { @MainActor in
                view.onPwdChange?(pwd)
            }
            return true

        case GHOSTTY_ACTION_QUIT:
            Task { @MainActor in
                NSApp.terminate(nil)
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            // Cursor feedback: ghostty swaps to the pointer over a ⌘-hovered
            // link and back to the I-beam otherwise. Per-surface, so route it
            // through the view like SET_TITLE/PWD.
            guard target.tag == GHOSTTY_TARGET_SURFACE,
                  let surface = target.target.surface,
                  let userdata = ghostty_surface_userdata(surface)
            else { return false }
            let view = Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
            let shape = action.action.mouse_shape
            Task { @MainActor in
                view.setCursorShape(shape)
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            // ⌘-clicking a link asks the app to open it in the default handler.
            return openURL(action.action.open_url)

        // Scrollback search. libghostty runs the search and paints the
        // matches itself; these tell the pane to show/hide its find bar
        // and keep the match counter current. START/END fire synchronously
        // from inside the binding-action or key call, TOTAL/SELECTED from
        // the surface mailbox during app tick — all hop to main the same
        // way SET_TITLE does.
        case GHOSTTY_ACTION_START_SEARCH:
            guard let view = surfaceView(for: target) else { return false }
            let needle = action.action.start_search.needle.map { String(cString: $0) }
            Task { @MainActor in
                view.searchDidStart(needle: needle)
            }
            return true

        case GHOSTTY_ACTION_END_SEARCH:
            guard let view = surfaceView(for: target) else { return false }
            Task { @MainActor in
                view.searchDidEnd()
            }
            return true

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            guard let view = surfaceView(for: target) else { return false }
            let total = Int(action.action.search_total.total)
            Task { @MainActor in
                view.searchDidUpdate(total: total)
            }
            return true

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            guard let view = surfaceView(for: target) else { return false }
            let selected = Int(action.action.search_selected.selected)
            Task { @MainActor in
                view.searchDidUpdate(selected: selected)
            }
            return true

        default:
            NSLog("GhosttyRuntime: unhandled action tag=%d", action.tag.rawValue)
            return false
        }
    }

    /// The GhosttySurfaceView behind a surface-targeted action, via the
    /// userdata registered at surface creation.
    nonisolated private static func surfaceView(for target: ghostty_target_s) -> GhosttySurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface,
              let userdata = ghostty_surface_userdata(surface)
        else { return nil }
        return Unmanaged<GhosttySurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Opens a URL libghostty surfaced from a ⌘-click on a terminal link.
    /// The payload is length-delimited (not null-terminated). Scheme-less
    /// strings are treated as file paths so local paths open in the right
    /// app instead of failing as malformed URLs.
    nonisolated private static func openURL(_ payload: ghostty_action_open_url_s) -> Bool {
        guard let urlPtr = payload.url, payload.len > 0 else { return false }
        let string = String(
            data: Data(bytes: urlPtr, count: Int(payload.len)),
            encoding: .utf8
        ) ?? ""
        guard !string.isEmpty else { return false }

        let url: URL
        if let candidate = URL(string: string), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(filePath: NSString(string: string).standardizingPath)
        }

        Task { @MainActor in
            NSWorkspace.shared.open(url)
        }
        return true
    }
}
