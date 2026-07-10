import SwiftUI

/// Experiment 01 — the current ⌘T palette, staged over a live-looking Enso
/// window. A faithful visual copy of CommandCenterView with local-only
/// filtering and keyboard navigation (no CommandCenter dependency).
struct Exp01CommandPalette: View {
    var body: some View {
        ZStack(alignment: .top) {
            EnsoBackdrop(terminal: .filled)

            // Scrim, matching TerminalRootView's 0.4 palette dim.
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // Mirror the root layout so the palette centers over the terminal
            // column, not the whole window.
            HStack(spacing: 0) {
                Color.clear.frame(width: 248)

                LabPaletteView()
                    .frame(height: 480, alignment: .top)
                    .padding(.top, 90)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Palette

private struct LabPaletteView: View {
    @State private var query = ""
    @State private var highlightedIndex = 0
    @State private var flashIndex: Int?
    @FocusState private var searchFocused: Bool

    private var items: [LabPaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return MockData.paletteItems }
        return MockData.paletteItems.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.context?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))

                TextField("Search tabs, spaces, commands…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.92))
                    .focused($searchFocused)
                    .onKeyPress(.downArrow) { moveHighlight(1); return .handled }
                    .onKeyPress(.upArrow) { moveHighlight(-1); return .handled }
                    .onKeyPress(.return) { flash(); return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 18)

            Rectangle()
                .fill(Color.white.opacity(0.04))
                .frame(height: 1)

            if items.isEmpty {
                Text("No matches")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, at: index)
                                    .id(item.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: highlightedIndex) { _, index in
                        guard items.indices.contains(index) else { return }
                        proxy.scrollTo(items[index].id)
                    }
                }
            }
        }
        .frame(width: 560)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                )
                .shadow(color: .black.opacity(0.4), radius: 4, y: 2)
                .shadow(color: .black.opacity(0.65), radius: 70, y: 30)
        )
        .onChange(of: query) { _, _ in
            // Keep the highlight valid as the list shrinks.
            highlightedIndex = 0
        }
        .onAppear {
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private func moveHighlight(_ delta: Int) {
        guard !items.isEmpty else { return }
        highlightedIndex = (highlightedIndex + delta + items.count) % items.count
    }

    private func flash() {
        guard items.indices.contains(highlightedIndex) else { return }
        let index = highlightedIndex
        flashIndex = index
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            if flashIndex == index { flashIndex = nil }
        }
    }

    private func row(_ item: LabPaletteItem, at index: Int) -> some View {
        let isHighlighted = index == highlightedIndex
        let isFlashing = index == flashIndex

        return HStack(spacing: 12) {
            HStack(spacing: 9) {
                iconView(item.icon, isHighlighted: isHighlighted)
                    .frame(width: 16)

                Text(item.title)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(isHighlighted ? 0.95 : 0.6))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            if let context = item.context {
                Text(context)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(isHighlighted ? 0.55 : 0.35))
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }

            HStack(spacing: 8) {
                if isHighlighted {
                    HStack(spacing: 4) {
                        Text(item.verb)
                            .font(.system(size: 11, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }

                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(isHighlighted ? 0.55 : 0.3))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.white.opacity(0.07))
                        )
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isFlashing
                    ? Color.white.opacity(0.18)
                    : (isHighlighted ? Color.white.opacity(0.09) : Color.clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { highlightedIndex = index }
        }
        .onTapGesture { flash() }
    }

    @ViewBuilder
    private func iconView(_ icon: LabPaletteItem.Icon, isHighlighted: Bool) -> some View {
        switch icon {
        case .accent(let color):
            Circle()
                .fill(color.opacity(isHighlighted ? 0.95 : 0.55))
                .frame(width: 7, height: 7)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(isHighlighted ? 0.8 : 0.45))
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: 12))
                .opacity(isHighlighted ? 1 : 0.55)
        }
    }
}
