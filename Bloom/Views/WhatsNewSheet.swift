import SwiftUI

/// Release-notes modal shown when an update is waiting: what changed in the
/// new version, with Update Now / Skip This Version as the ways out.
/// Presented as an owned in-window overlay (same chrome as
/// SpaceEditorSheet), never a macOS sheet. Knows nothing about Sparkle —
/// it renders whatever Content it's handed.
struct WhatsNewSheet: View {
    /// Mirrors the markdown the release notes are authored in: `##`
    /// headings ("New", "Improved", "Fixed") become sections, list items
    /// become lines. Keeping the model this shape means the appcast HTML
    /// (h2 + ul/li) parses straight into it.
    struct Content {
        var version: String
        var sections: [Section]

        struct Section: Identifiable {
            let id = UUID()
            var title: String
            var items: [String]
        }
    }

    let content: Content
    let onUpdate: () -> Void
    let onSkip: () -> Void
    let onDismiss: () -> Void

    @State private var closeHovered = false
    @State private var scrolledUnderHeader = false
    @State private var moreBelowFooter = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.32))
                    Image(systemName: "sparkles")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text("What's New in Bloom")
                        .font(.system(size: 15, weight: .semibold))

                    Text("Version \(content.version) is ready to install.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 24)  // keeps clear of the close button
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            hairline(visible: scrolledUnderHeader)

            // Header and footer are sticky; only the notes flex. Short
            // notes hug their height, long ones cap the card and scroll —
            // ViewThatFits picks the plain list whenever it fits.
            ViewThatFits(in: .vertical) {
                notesList

                ScrollView {
                    notesList
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y > 0.5
                } action: { _, scrolled in
                    scrolledUnderHeader = scrolled
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height < geo.contentSize.height - 0.5
                } action: { _, more in
                    moreBelowFooter = more
                }
            }
            .frame(maxHeight: 300)

            hairline(visible: moreBelowFooter)
                .padding(.bottom, 14)

            HStack(spacing: 8) {
                Button("Skip This Version") {
                    onSkip()
                }
                .buttonStyle(ModalSecondaryButtonStyle())

                Button {
                    onUpdate()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text("Update Now")
                    }
                }
                .buttonStyle(ModalPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
        }
        .frame(width: 420)
        .overlay(alignment: .topTrailing) {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(closeHovered ? 0.85 : 0.45))
                    .frame(width: 30, height: 30)
                    .background(
                        Circle().fill(Color.white.opacity(closeHovered ? 0.08 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .keyboardShortcut(.cancelAction)
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.094, green: 0.096, blue: 0.105))
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                .shadow(color: .black.opacity(0.65), radius: 70, y: 30)
        )
    }

    private var notesList: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(content.sections) { section in
                SectionView(section: section)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    /// Edge-to-edge separator that fades in while content is scrolled
    /// past its edge, macOS-sheet style.
    private func hairline(visible: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .opacity(visible ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: visible)
    }

    /// One "## heading" worth of notes: a quiet small-caps title, then
    /// plain text lines with a hanging dim bullet.
    private struct SectionView: View {
        let section: Content.Section

        var body: some View {
            VStack(alignment: .leading, spacing: 7) {
                // Untitled sections happen (stray prose in the appcast);
                // just show their lines without a header.
                if !section.title.isEmpty {
                    Text(section.title.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(.bottom, 1)
                }

                ForEach(section.items, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("·")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.35))

                        Text(item)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

extension WhatsNewSheet.Content {
    /// Canned notes for previews and the DEBUG design scaffold.
    static let preview = WhatsNewSheet.Content(
        version: "0.5.0",
        sections: [
            .init(title: "New", items: [
                "Release notes now show up right here when an update is ready — no more guessing what changed.",
                "Right-click a folder in Finder → New Bloom Terminal Here."
            ]),
            .init(title: "Improved", items: [
                "The sidebar update card keeps its layout in narrow sidebars instead of wrapping.",
                "Quit confirmation is bigger and easier to read."
            ]),
            .init(title: "Fixed", items: [
                "Command palette no longer spawns a stray terminal when you press Enter.",
                "Fixed a crash at launch when the updater framework failed to load."
            ])
        ]
    )
}

#Preview("Typical") {
    WhatsNewSheet(content: .preview, onUpdate: {}, onSkip: {}, onDismiss: {})
        .padding(60)
        .background(.black)
}

#Preview("One line") {
    WhatsNewSheet(
        content: .init(version: "0.5.1", sections: [
            .init(title: "Fixed", items: ["Fixed a hang when closing the last tab."])
        ]),
        onUpdate: {}, onSkip: {}, onDismiss: {}
    )
    .padding(60)
    .background(.black)
}
