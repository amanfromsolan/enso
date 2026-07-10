import SwiftUI

/// Lookalike of Enso's sidebar: space header, pinned tabs, a couple of
/// folders with tab rows, and a "New Terminal" affordance. Row styling
/// (heights, fonts, corner radii, selected/hover fills) tracks SidebarView.
struct MockSidebar: View {
    var selectedTab: String = MockData.selectedTabTitle

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clear band for the floating traffic lights.
            Color.clear.frame(height: 40)

            VStack(alignment: .leading, spacing: 2) {
                spaceHeader
                    .padding(.bottom, 4)

                ForEach(MockData.pinnedTabs) { tab in
                    tabRow(tab)
                }

                ForEach(MockData.folders) { folder in
                    folderSection(folder)
                }

                zoneDivider

                ForEach(MockData.looseTabs) { tab in
                    tabRow(tab)
                }

                newTerminalRow

                Spacer(minLength: 0)

                spaceIndicatorBar
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(width: 248)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Header

    private var spaceHeader: some View {
        HStack(spacing: 8) {
            spaceIcon(MockData.space.icon, size: 15, active: true)
                .frame(width: 16)

            Text(MockData.space.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))

            Spacer(minLength: 0)

            Text("2 spaces")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
    }

    // MARK: - Folder

    private func folderSection(_ folder: MockFolder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 16)

                Text(folder.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .rotationEffect(.degrees(90))
                    .opacity(0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)

            // Children, indented like the real folder body.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(folder.tabs) { tab in
                    tabRow(tab)
                }
            }
            .padding(.leading, 14)
        }
    }

    // MARK: - Tab row

    private func tabRow(_ tab: MockTab) -> some View {
        let isSelected = tab.title == selectedTab

        return HStack(spacing: 8) {
            ZStack {
                if let process = tab.process {
                    HStack(spacing: 3) {
                        Image(systemName: process.symbol)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(tab.accent.opacity(isSelected ? 1 : 0.8))
                    }
                } else {
                    Circle()
                        .fill(tab.accent.opacity(isSelected ? 0.95 : 0.55))
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 14, height: 14)

            Text(tab.title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.62))
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(isSelected ? Color.white.opacity(0.14) : Color.clear)
        )
    }

    private var newTerminalRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 14)
            Text("New Terminal")
                .font(.system(size: 13, weight: .medium))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white.opacity(0.45))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private var zoneDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(height: 1)
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
    }

    // MARK: - Space indicator bar

    private var spaceIndicatorBar: some View {
        HStack(spacing: 10) {
            spaceIcon(MockData.space.icon, size: 13, active: true)
            spaceIcon(.dot, size: 13, active: false)

            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .padding(.bottom, 6)
    }

    // MARK: - Space icon

    @ViewBuilder
    private func spaceIcon(_ icon: MockSpace.Icon, size: CGFloat, active: Bool) -> some View {
        switch icon {
        case .dot:
            Circle()
                .fill(.white.opacity(active ? 0.9 : 0.3))
                .frame(width: size * 0.4, height: size * 0.4)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: size * 0.61, weight: .medium))
                .foregroundStyle(.white.opacity(active ? 0.9 : 0.3))
        case .emoji(let emoji):
            Text(emoji)
                .font(.system(size: size * 0.67))
                .opacity(active ? 1 : 0.5)
        }
    }
}
