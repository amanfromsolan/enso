import AppKit
import SwiftUI
import Testing
@testable import Enso

@MainActor
struct PaneHeaderThemeTests {
    @Test(arguments: [false, true])
    func existingHeaderUpdatesContrastWhenThemeChanges(compact: Bool) async throws {
        let session = TerminalSession(title: "Terminal", workingDirectory: NSHomeDirectory())
        let store = TerminalSessionStore(
            spaces: [SidebarSpace(name: "Main", pinnedFolders: [], pinnedSessions: [session])],
            persistToDisk: false
        )
        func header(_ scheme: ColorScheme) -> some View {
            PaneHeaderView(
                session: session, store: store, compact: compact, focused: true,
                terminalColorScheme: scheme, onActivate: {}
            )
            .frame(width: 600, height: 46)
            .background(Color(white: 0.5))
        }
        let hosting = NSHostingView(rootView: header(.light))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 46),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.contentView = hosting
        defer { window.contentView = nil }

        // Reuse the same host and session throughout; only the theme changes.
        for scheme in [ColorScheme.light, .dark, .light] {
            hosting.rootView = header(scheme)
            try await Task.sleep(for: .milliseconds(50))
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            var darkPixels = 0
            var lightPixels = 0
            // Sample the leading title/badge cluster, away from controls.
            let scale = CGFloat(bitmap.pixelsWide) / hosting.bounds.width
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<Int(220 * scale) {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                    if brightness < 0.25 { darkPixels += 1 }
                    if brightness > 0.75 { lightPixels += 1 }
                }
            }
            if scheme == .light {
                #expect(darkPixels > 50)
                #expect(darkPixels > lightPixels)
            } else {
                #expect(lightPixels > 50)
                #expect(lightPixels > darkPixels)
            }
        }
    }
}
