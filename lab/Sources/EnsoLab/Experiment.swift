import SwiftUI

struct Experiment: Identifiable {
    let id: String        // "01-command-palette"
    let number: String    // "01"
    let title: String
    let subtitle: String
    let folder: String    // section header on the index
    let makeView: () -> AnyView
}

/// The registry. Adding an experiment = one file in Experiments/ plus one
/// entry here. Experiments are meant to be built in parallel: keep every
/// helper in your file `private` (only the ExpNN entry view is internal),
/// treat Shared/ as read-only — copy code into your file to change it —
/// and append your registry entry in number order.
enum ExperimentCatalog {
    static let all: [Experiment] = [
        Experiment(
            id: "01-command-palette",
            number: "01",
            title: "Baseline — current design",
            subtitle: "The ⌘T command palette exactly as it ships today.",
            folder: "Command Palette",
            makeView: { AnyView(Exp01CommandPalette()) }
        ),
    ]

    /// Sections in first-seen order, each with its experiments.
    static var grouped: [(folder: String, items: [Experiment])] {
        var order: [String] = []
        var buckets: [String: [Experiment]] = [:]
        for experiment in all {
            if buckets[experiment.folder] == nil { order.append(experiment.folder) }
            buckets[experiment.folder, default: []].append(experiment)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }
}
