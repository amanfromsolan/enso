import SwiftUI

/// The full fake Enso window: frosted backdrop, sidebar, and the inset
/// terminal card. This is the canvas experiments draw their overlays over.
/// Layout mirrors TerminalRootView — sidebar flush against a card inset 10pt
/// from the terminal edges, on a `.sidebar` blur tinted black 0.38.
struct EnsoBackdrop: View {
    var terminal: MockTerminal.Variant = .filled

    var body: some View {
        HStack(spacing: 0) {
            MockSidebar()
                .frame(width: 248)

            MockTerminal(variant: terminal)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.22), radius: 12, y: 3)
                // Flush at the sidebar edge, inset on the other three sides.
                .padding(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffect(material: .sidebar, blendingMode: .behindWindow)
                .overlay(Color.black.opacity(0.38))
        )
    }
}
