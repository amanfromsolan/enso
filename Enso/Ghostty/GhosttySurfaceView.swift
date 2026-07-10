import AppKit
import GhosttyKit

/// The NSView a libghostty surface renders into. libghostty owns the PTY,
/// the shell process, and the Metal rendering; this view feeds it input,
/// focus, and size changes.
final class GhosttySurfaceView: NSView, NSTextInputClient {
    // Read from ghostty callback threads and deinit; written on main only.
    nonisolated(unsafe) private(set) var surface: ghostty_surface_t?

    var onTitleChange: ((String) -> Void)?
    var onPwdChange: ((String) -> Void)?
    var onSurfaceClose: (() -> Void)?

    /// Non-nil while interpretKeyEvents is routing a keyDown through
    /// NSTextInputClient; collects the text AppKit translates for us.
    private var keyTextAccumulator: [String]?
    private var markedText = NSMutableAttributedString()

    /// The cursor libghostty wants shown over this surface. Terminals default
    /// to the I-beam; ghostty swaps to a pointer over a link (while ⌘ is held)
    /// and to resize/other shapes via GHOSTTY_ACTION_MOUSE_SHAPE.
    private var cursor: NSCursor = .iBeam {
        didSet {
            guard cursor != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    init(workingDirectory: String) {
        // Non-zero initial frame so the renderer never sees empty bounds.
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        registerForDraggedTypes(Array(Self.dropTypes))
        createSurface(workingDirectory: workingDirectory)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func createSurface(workingDirectory: String) {
        GhosttyRuntime.shared.ensureStarted()
        guard let app = GhosttyRuntime.shared.app else { return }

        var config = ghostty_surface_config_new()
        config.platform_tag = GHOSTTY_PLATFORM_MACOS
        config.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: Unmanaged.passUnretained(self).toOpaque())
        )
        config.userdata = Unmanaged.passUnretained(self).toOpaque()
        config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

        let directory = (workingDirectory as NSString).expandingTildeInPath
        directory.withCString { directoryPtr in
            config.working_directory = directoryPtr
            surface = ghostty_surface_new(app, &config)
        }

        if surface == nil {
            NSLog("GhosttySurfaceView: ghostty_surface_new failed")
        }
    }

    /// Frees the surface (terminating the shell). The view must not receive
    /// further input afterwards; the manager drops it immediately.
    func shutdown() {
        guard let surface else { return }
        self.surface = nil
        ghostty_surface_free(surface)
    }

    func surfaceDidRequestClose() {
        onSurfaceClose?()
    }

    /// Plain text of the whole screen including scrollback; feeds tab
    /// auto-naming. Nil when the surface is gone or has nothing to read.
    func screenContents() -> String? {
        guard let surface else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return nil }
        return String(cString: pointer)
    }

    deinit {
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    // MARK: - View lifecycle / sizing

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        syncContentScale()
        syncSurfaceSize()
        syncDisplayID()
        if let surface {
            ghostty_surface_refresh(surface)
        }
    }

    override func layout() {
        super.layout()
        syncSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncContentScale()
        syncSurfaceSize()
    }

    private func syncSurfaceSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds.size)
        guard backing.width > 0, backing.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    private func syncContentScale() {
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        guard scale > 0 else { return }
        layer?.contentsScale = scale
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    /// Keeps ghostty's vsync source on the right display.
    private func syncDisplayID() {
        guard let surface,
              let screen = window?.screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        else { return }
        ghostty_surface_set_display_id(surface, number)
    }

    // MARK: - Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let surface {
            ghostty_surface_set_focus(surface, true)
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, let surface {
            ghostty_surface_set_focus(surface, false)
        }
        return accepted
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        guard surface != nil else {
            super.keyDown(with: event)
            return
        }

        // Round-trip through NSTextInputClient so dead keys, IME, and
        // modifier translation behave like a native text view.
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])

        if let texts = keyTextAccumulator, !texts.isEmpty {
            for text in texts {
                sendKey(action: GHOSTTY_ACTION_PRESS, event: event, text: text)
            }
        } else {
            sendKey(action: GHOSTTY_ACTION_PRESS, event: event, text: nil)
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(action: GHOSTTY_ACTION_RELEASE, event: event, text: nil)
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifier keyCodes: shift 0x38/0x3C, ctrl 0x3B/0x3E, option 0x3A/0x3D,
        // command 0x37/0x36, caps lock 0x39.
        let flag: NSEvent.ModifierFlags?
        switch event.keyCode {
        case 0x38, 0x3C: flag = .shift
        case 0x3B, 0x3E: flag = .control
        case 0x3A, 0x3D: flag = .option
        case 0x37, 0x36: flag = .command
        case 0x39: flag = .capsLock
        default: flag = nil
        }
        guard let flag else { return }
        let pressed = event.modifierFlags.contains(flag)
        sendKey(action: pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE, event: event, text: nil)
    }

    /// Swallow unhandled command selectors (insertNewline: etc.) so the
    /// system doesn't beep; the raw key event already went to ghostty.
    override func doCommand(by selector: Selector) {}

    private func sendKey(action: ghostty_input_action_e, event: NSEvent, text: String?) {
        guard let surface else { return }

        var key = ghostty_input_key_s()
        key.action = (event.type == .keyDown && event.isARepeat) ? GHOSTTY_ACTION_REPEAT : action
        key.mods = Self.ghosttyMods(event.modifierFlags)
        key.keycode = UInt32(event.keyCode)
        key.composing = hasMarkedText()

        if event.type == .keyDown || event.type == .keyUp {
            if let scalar = event.characters(byApplyingModifiers: [])?.unicodeScalars.first {
                key.unshifted_codepoint = scalar.value
            }
        }

        if text != nil {
            // Modifiers that produced the text are "consumed"; ctrl and
            // command never contribute to text translation on macOS.
            let translation = ghostty_surface_key_translation_mods(surface, key.mods)
            key.consumed_mods = ghostty_input_mods_e(
                rawValue: translation.rawValue & ~(GHOSTTY_MODS_CTRL.rawValue | GHOSTTY_MODS_SUPER.rawValue)
            )
        }

        if let text {
            text.withCString { ptr in
                key.text = ptr
                _ = ghostty_surface_key(surface, key)
            }
        } else {
            _ = ghostty_surface_key(surface, key)
        }
    }

    private static func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    // MARK: - Copy / paste (Edit menu)

    @objc func copy(_ sender: Any?) {
        performBinding("copy_to_clipboard")
    }

    @objc func paste(_ sender: Any?) {
        performBinding("paste_from_clipboard")
    }

    override func selectAll(_ sender: Any?) {
        performBinding("select_all")
    }

    private func performBinding(_ action: String) {
        guard let surface else { return }
        _ = action.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(action.utf8.count))
        }
    }

    // MARK: - Mouse

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
    }

    override func mouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func mouseMoved(with event: NSEvent) {
        sendMousePos(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendMousePos(event)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            // Matches Ghostty's own 2x multiplier for precise (trackpad) deltas.
            x *= 2
            y *= 2
        }

        // Packed scroll mods: bit 0 precision, bits 1-3 momentum phase.
        var scrollMods: ghostty_input_scroll_mods_t = precision ? 1 : 0
        scrollMods |= momentumBits(event.momentumPhase) << 1

        ghostty_surface_mouse_scroll(surface, x, y, scrollMods)
    }

    private func momentumBits(_ phase: NSEvent.Phase) -> Int32 {
        switch phase {
        case .began: 1
        case .stationary: 2
        case .changed: 3
        case .ended: 4
        case .cancelled: 5
        case .mayBegin: 6
        default: 0
        }
    }

    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, Self.ghosttyMods(event.modifierFlags))
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let pos = convert(event.locationInWindow, from: nil)
        // ghostty expects top-left origin.
        ghostty_surface_mouse_pos(surface, pos.x, bounds.height - pos.y, Self.ghosttyMods(event.modifierFlags))
    }

    // MARK: - Cursor

    /// AppKit owns cursor updates while the pointer is inside the view; we
    /// hand it the shape ghostty last asked for.
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }

    /// Maps a ghostty mouse shape to the closest NSCursor and applies it.
    /// Driven by GHOSTTY_ACTION_MOUSE_SHAPE, which fires whenever the hovered
    /// content changes — most notably the pointer over a ⌘-hovered link.
    func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT: cursor = .arrow
        case GHOSTTY_MOUSE_SHAPE_TEXT: cursor = .iBeam
        case GHOSTTY_MOUSE_SHAPE_POINTER: cursor = .pointingHand
        case GHOSTTY_MOUSE_SHAPE_GRAB: cursor = .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING: cursor = .closedHand
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: cursor = .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: cursor = .crosshair
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED: cursor = .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE,
             GHOSTTY_MOUSE_SHAPE_E_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_COL_RESIZE: cursor = .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE,
             GHOSTTY_MOUSE_SHAPE_S_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE,
             GHOSTTY_MOUSE_SHAPE_ROW_RESIZE: cursor = .resizeUpDown
        default:
            // Shapes without a native NSCursor (help, progress, wait, zoom,
            // diagonal resizes, …): fall back to the terminal's I-beam.
            cursor = .iBeam
        }
    }

    // MARK: - Drag and drop

    /// Types we accept on drop: files and URLs become escaped paths typed
    /// into the terminal, plain strings are inserted as-is.
    private static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
        .URL,
    ]

    /// Shell-sensitive characters escaped with a backslash so dropped paths
    /// survive being typed into a live prompt (matches upstream Ghostty).
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    private static func shellEscape(_ str: String) -> String {
        var result = str
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types,
              !Set(types).isDisjoint(with: Self.dropTypes)
        else { return [] }
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        let content: String?
        if let url = pasteboard.string(forType: .URL) {
            // URLs first, escaped as-is.
            content = Self.shellEscape(url)
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
                  !urls.isEmpty {
            // File URLs next: escaped individually, joined by spaces.
            content = urls
                .map { Self.shellEscape($0.path) }
                .joined(separator: " ")
        } else if let string = pasteboard.string(forType: .string) {
            // Plain strings are not escaped; they may be a command to run.
            content = string
        } else {
            content = nil
        }

        guard let content else { return false }
        DispatchQueue.main.async {
            self.insertText(content, replacementRange: NSRange(location: 0, length: 0))
        }
        return true
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let attributed as NSAttributedString: text = attributed.string
        case let plain as String: text = plain
        default: return
        }

        if hasMarkedText() {
            unmarkText()
        }

        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(text)
        } else if let surface {
            text.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(text.utf8.count))
            }
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: attributed)
        case let plain as String:
            markedText = NSMutableAttributedString(string: plain)
        default:
            return
        }
        syncPreedit()
    }

    func unmarkText() {
        guard hasMarkedText() else { return }
        markedText.mutableString.setString("")
        syncPreedit()
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText()
            ? NSRange(location: 0, length: markedText.length)
            : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        let viewRect = NSRect(x: x, y: bounds.height - y, width: width, height: height)
        return window.convertToScreen(convert(viewRect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        0
    }

    private func syncPreedit() {
        guard let surface else { return }
        if hasMarkedText() {
            let text = markedText.string
            text.withCString { ptr in
                ghostty_surface_preedit(surface, ptr, UInt(text.utf8.count))
            }
        } else {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}
