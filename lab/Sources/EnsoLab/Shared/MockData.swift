import SwiftUI

// MARK: - Sidebar mock model

struct MockSpace {
    enum Icon {
        case dot
        case symbol(String)
        case emoji(String)
    }

    let name: String
    let icon: Icon
}

struct MockTab: Identifiable {
    let id = UUID()
    let title: String
    let accent: Color
    /// A short process badge glyph + label, or nil for a plain accent dot.
    var process: (symbol: String, label: String)? = nil
}

struct MockFolder: Identifiable {
    let id = UUID()
    let title: String
    let tabs: [MockTab]
}

// MARK: - Palette mock model

struct LabPaletteItem: Identifiable {
    enum Icon {
        case accent(Color)
        case symbol(String)
        case emoji(String)
    }

    let id = UUID()
    let icon: Icon
    let title: String
    let context: String?
    let verb: String
}

// MARK: - Catalog of mock content

enum MockData {
    // Terminal palette accents, roughly Enso's per-tab colors.
    static let cyan = Color(red: 0.42, green: 0.80, blue: 0.85)
    static let green = Color(red: 0.50, green: 0.82, blue: 0.55)
    static let violet = Color(red: 0.68, green: 0.58, blue: 0.92)
    static let amber = Color(red: 0.92, green: 0.74, blue: 0.42)
    static let rose = Color(red: 0.92, green: 0.52, blue: 0.58)

    static let space = MockSpace(name: "enso", icon: .symbol("circle.dashed"))

    static let pinnedTabs: [MockTab] = [
        MockTab(title: "claude", accent: violet, process: ("sparkles", "claude")),
        MockTab(title: "bun dev", accent: green, process: ("bolt.fill", "bun")),
    ]

    static let folders: [MockFolder] = [
        MockFolder(title: "api", tabs: [
            MockTab(title: "zsh", accent: cyan),
            MockTab(title: "bun test", accent: amber, process: ("bolt.fill", "bun")),
        ]),
        MockFolder(title: "web", tabs: [
            MockTab(title: "next dev", accent: green, process: ("bolt.fill", "node")),
            MockTab(title: "tsc --watch", accent: cyan),
        ]),
    ]

    static let looseTabs: [MockTab] = [
        MockTab(title: "scratch", accent: rose),
        MockTab(title: "logs", accent: amber),
    ]

    /// Tab selected by default in the sidebar (matches the terminal header).
    static let selectedTabTitle = "claude"

    static let paletteItems: [LabPaletteItem] = [
        LabPaletteItem(icon: .accent(violet), title: "claude", context: "enso · api", verb: "Switch"),
        LabPaletteItem(icon: .accent(green), title: "bun dev", context: "enso", verb: "Switch"),
        LabPaletteItem(icon: .accent(cyan), title: "zsh", context: "enso · api", verb: "Switch"),
        LabPaletteItem(icon: .accent(amber), title: "bun test", context: "enso · api", verb: "Switch"),
        LabPaletteItem(icon: .accent(green), title: "next dev", context: "enso · web", verb: "Switch"),
        LabPaletteItem(icon: .accent(rose), title: "scratch", context: "enso", verb: "Switch"),
        LabPaletteItem(icon: .symbol("plus"), title: "New Tab", context: nil, verb: "Create"),
        LabPaletteItem(icon: .symbol("pencil"), title: "Rename Tab…", context: nil, verb: "Rename"),
        LabPaletteItem(icon: .symbol("folder.badge.plus"), title: "New Folder", context: nil, verb: "Create"),
        LabPaletteItem(icon: .emoji("🪐"), title: "Switch Space", context: nil, verb: "Open"),
        LabPaletteItem(icon: .symbol("sidebar.left"), title: "Toggle Sidebar", context: nil, verb: "Run"),
        LabPaletteItem(icon: .symbol("gearshape"), title: "Settings…", context: nil, verb: "Open"),
    ]
}
