import Foundation

/// One curated SF Symbol from `sf-symbols.json`: the symbol name plus a few
/// search keywords. The very first entry (`circle.fill`) stands in for the
/// app's default dot — see `IconCatalog.iconTiles`.
struct SymbolEntry: Decodable, Hashable {
    let symbol: String
    let keywords: [String]
}

/// One gemoji from `emoji.json`, in the standard picker order. Searched over
/// description + aliases + tags; grouped under `category` for section headers.
struct EmojiEntry: Decodable, Hashable {
    let emoji: String
    let description: String
    let aliases: [String]
    let tags: [String]
    let category: String

    /// Lowercased description + aliases + tags, matched against a search.
    var searchText: String {
        ([description] + aliases + tags).joined(separator: " ").lowercased()
    }
}

/// A ready-to-render Icons-grid tile: the model `Icon` to persist plus the
/// lowercased text we match a search against. The dot tile carries `.dot`
/// (never `.symbol("circle.fill")`), so picking it persists the real default.
struct IconTile: Identifiable, Hashable {
    let id: String
    let icon: SidebarSpace.Icon
    let searchText: String
}

/// The picker's backing data: the 185 curated SF Symbols and the 1,870
/// gemoji, decoded once from bundled JSON. If either resource ever goes
/// missing the symbol side falls back to a small inline list, so the picker
/// and the shuffle button can never come up empty.
struct IconCatalog {
    let symbols: [SymbolEntry]
    let emoji: [EmojiEntry]
    /// Emoji category names in gemoji order, for the grid's section headers.
    let emojiCategories: [String]
    /// Emoji bucketed by category, memoized so the grouped grid never
    /// re-partitions 1,870 entries on every render.
    let emojiByCategory: [String: [EmojiEntry]]

    static let shared = IconCatalog.load()

    /// Icons-grid tiles: the plain dot first (from the `circle.fill` stand-in
    /// entry, but persisting `.dot`), then every other curated symbol.
    var iconTiles: [IconTile] {
        symbols.enumerated().map { index, entry in
            let text = ([entry.symbol] + entry.keywords)
                .joined(separator: " ")
                .lowercased()
            if index == 0 {
                return IconTile(id: "dot", icon: .dot, searchText: text)
            }
            return IconTile(id: entry.symbol, icon: .symbol(entry.symbol), searchText: text)
        }
    }

    /// Every icon the shuffle button may land on: all curated symbols (minus
    /// the dot stand-in) plus all emoji. The plain dot is intentionally left
    /// out — shuffle is for serendipity, not the default.
    var shuffleChoices: [SidebarSpace.Icon] {
        symbols.dropFirst().map { SidebarSpace.Icon.symbol($0.symbol) }
            + emoji.map { SidebarSpace.Icon.emoji($0.emoji) }
    }

    static func load(from bundle: Bundle = .main) -> IconCatalog {
        let symbols = decode([SymbolEntry].self, named: "sf-symbols", from: bundle)
            ?? fallbackSymbols
        let emoji = decode([EmojiEntry].self, named: "emoji", from: bundle) ?? []
        var categories: [String] = []
        for entry in emoji where !categories.contains(entry.category) {
            categories.append(entry.category)
        }
        return IconCatalog(
            symbols: symbols,
            emoji: emoji,
            emojiCategories: categories,
            emojiByCategory: Dictionary(grouping: emoji, by: \.category)
        )
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        named name: String,
        from bundle: Bundle
    ) -> T? {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Last-ditch symbols if the bundled JSON is ever unreadable — same shape
    /// as the file, first entry standing in for the dot.
    static let fallbackSymbols: [SymbolEntry] = [
        "circle.fill", "house.fill", "terminal", "hammer.fill",
        "folder.fill", "globe", "server.rack", "cpu",
        "bolt.fill", "flame.fill", "leaf.fill", "star.fill",
        "heart.fill", "book.fill", "briefcase.fill", "sparkles",
    ].map { SymbolEntry(symbol: $0, keywords: []) }
}
