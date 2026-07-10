import SwiftUI

/// Owns the index ⇄ experiment navigation. Simple state switch — no
/// NavigationStack needed for a two-level lab.
struct RootView: View {
    // `swift run EnsoLab --open 01` jumps straight into an experiment, so
    // iteration loops can relaunch and screenshot without clicking through.
    @State private var selection: Experiment? = {
        guard let flag = CommandLine.arguments.firstIndex(of: "--open"),
              CommandLine.arguments.indices.contains(flag + 1) else { return nil }
        let key = CommandLine.arguments[flag + 1]
        return ExperimentCatalog.all.first {
            $0.id == key || $0.number == key || $0.id.hasPrefix(key)
        }
    }()

    var body: some View {
        ZStack {
            // Translucent dark shell: the behind-window blur plus a heavy tint
            // so the desktop only faintly glows through.
            VisualEffect(material: .underWindowBackground, blendingMode: .behindWindow)
                .overlay(Color.black.opacity(0.5))
                .ignoresSafeArea()

            if let experiment = selection {
                experiment.makeView()
                    .overlay(alignment: .topLeading) { backControl }
                    .transition(.opacity)
            } else {
                IndexView { selection = $0 }
                    .transition(.opacity)
            }
        }
        // Fill the full window height; the hidden titlebar otherwise leaves a
        // safe-area strip above the content.
        .ignoresSafeArea()
        .animation(.easeOut(duration: 0.18), value: selection?.id)
    }

    private var backControl: some View {
        Button {
            selection = nil
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Experiments")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .buttonStyle(BackButtonStyle())
        // Sits beside the traffic lights, inside the sidebar's top band.
        .padding(.top, 6)
        .padding(.leading, 78)
    }
}

/// Low-opacity floating control that brightens on hover.
private struct BackButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(hovering ? 0.85 : 0.4))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.08 : 0.0))
            )
            .onHover { hovering = $0 }
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: - Index

struct IndexView: View {
    let open: (Experiment) -> Void

    private var count: Int { ExperimentCatalog.all.count }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            header

            VStack(alignment: .leading, spacing: 22) {
                ForEach(ExperimentCatalog.grouped, id: \.folder) { section in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.folder.uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.white.opacity(0.35))
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)

                        ForEach(section.items) { experiment in
                            ExperimentRow(experiment: experiment) { open(experiment) }
                        }
                    }
                }
            }
            .frame(width: 520)
            .padding(.top, 40)

            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 64, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                )
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)

            Text("Enso Experiments")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            Text("\(count) experiment\(count == 1 ? "" : "s") · a design lab for the terminal")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
    }
}

private struct ExperimentRow: View {
    let experiment: Experiment
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(experiment.number)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(hovering ? 0.55 : 0.3))
                    .frame(width: 22, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(experiment.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.8))
                    Text(experiment.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.05 : 0.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
