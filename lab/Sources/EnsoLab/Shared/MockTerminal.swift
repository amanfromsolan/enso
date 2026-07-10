import SwiftUI

/// A static lookalike of Enso's terminal card: shell output straight on the
/// dark surface — the real card has no header strip (traffic lights live over
/// the sidebar). No logic, just believable frozen output.
struct MockTerminal: View {
    enum Variant {
        case empty
        case filled
    }

    var variant: Variant = .filled

    /// Enso's real terminal background (GhosttyRuntime.themeBackground).
    private let surface = Color(red: 0.018, green: 0.019, blue: 0.023)

    var body: some View {
        content
            .background(surface)
    }

    @ViewBuilder
    private var content: some View {
        switch variant {
        case .empty:
            emptyContent
        case .filled:
            filledContent
        }
    }

    private var emptyContent: some View {
        HStack(spacing: 8) {
            Text("~")
                .foregroundStyle(MockData.cyan.opacity(0.7))
            Text("❯")
                .foregroundStyle(.white.opacity(0.5))
            // Block cursor.
            RoundedRectangle(cornerRadius: 1)
                .fill(.white.opacity(0.6))
                .frame(width: 8, height: 16)
            Spacer()
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filledContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            promptLine("ls")
            Text(colored([
                (" api        web        scratch", MockData.cyan),
            ]))
            Text(colored([
                (" README.md  package.json  bun.lockb  tsconfig.json", .white.opacity(0.75)),
            ]))
            spacer()

            promptLine("git status")
            line("On branch ", "main", .white.opacity(0.6), MockData.cyan)
            line("Your branch is up to date with ", "origin/main", .white.opacity(0.6), MockData.cyan)
            Text(" ").font(mono)
            Text("Changes not staged for commit:")
                .foregroundStyle(.white.opacity(0.6))
            Text(colored([
                ("  modified:   Sources/EnsoLab/Shared/MockTerminal.swift", MockData.rose),
            ]))
            Text(colored([
                ("  modified:   Package.swift", MockData.rose),
            ]))
            spacer()

            promptLine("bun test")
            Text(colored([
                ("bun test ", .white.opacity(0.55)),
                ("v1.1.38", .white.opacity(0.35)),
            ]))
            Text(colored([
                ("✓", MockData.green),
                (" palette › filters items on query", .white.opacity(0.7)),
            ]))
            Text(colored([
                ("✓", MockData.green),
                (" palette › arrow keys move highlight", .white.opacity(0.7)),
            ]))
            Text(colored([
                ("✓", MockData.green),
                (" sidebar › renders folders and tabs", .white.opacity(0.7)),
            ]))
            Text(colored([
                (" 3 pass  0 fail  ", MockData.green),
                ("7 expect() calls", .white.opacity(0.45)),
            ]))
            Text(colored([
                ("Ran 3 tests across 1 file. ", .white.opacity(0.55)),
                ("[212.00ms]", .white.opacity(0.35)),
            ]))
            spacer()

            HStack(spacing: 6) {
                Text("~/dev/enso/api")
                    .foregroundStyle(MockData.cyan.opacity(0.7))
                Text("❯")
                    .foregroundStyle(.white.opacity(0.5))
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white.opacity(0.6))
                    .frame(width: 8, height: 16)
            }
        }
        .font(mono)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Line helpers

    private let mono = Font.system(size: 13, design: .monospaced)

    private func promptLine(_ command: String) -> some View {
        Text(colored([
            ("~/dev/enso/api ", MockData.cyan.opacity(0.7)),
            ("❯ ", .white.opacity(0.5)),
            (command, .white.opacity(0.9)),
        ]))
    }

    private func line(_ lead: String, _ accent: String, _ leadColor: Color, _ accentColor: Color) -> Text {
        Text(colored([(lead, leadColor), (accent, accentColor)]))
    }

    private func spacer() -> some View {
        Color.clear.frame(height: 8)
    }

    /// Builds a single styled Text run out of colored segments.
    private func colored(_ segments: [(String, Color)]) -> AttributedString {
        var result = AttributedString()
        for (text, color) in segments {
            var piece = AttributedString(text)
            piece.foregroundColor = color
            result += piece
        }
        return result
    }
}
