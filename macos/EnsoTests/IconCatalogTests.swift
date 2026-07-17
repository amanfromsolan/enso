import Testing
@testable import Enso

/// The space-icon picker leans on two bundled JSON catalogs. If either fails
/// to decode the picker silently falls back to a tiny inline list, so these
/// guard that the real resources ship and parse.
@MainActor
struct IconCatalogTests {
    private let catalog = IconCatalog.load()

    @Test func bundledSymbolsDecode() {
        // 185 curated symbols in the file; well past the 16-item fallback.
        #expect(catalog.symbols.count > 100)
        // The first entry is the dot stand-in.
        #expect(catalog.symbols.first?.symbol == "circle.fill")
    }

    @Test func bundledEmojiDecode() {
        #expect(catalog.emoji.count > 1000)
        #expect(catalog.emojiCategories.first == "Smileys & Emotion")
        // Every emoji lands in exactly one of the ordered categories.
        #expect(catalog.emojiByCategory.keys.count == catalog.emojiCategories.count)
    }

    @Test func firstIconTileIsTheDotNotCircleFill() {
        // Picking the first Icons tile must persist `.dot`, never the
        // `circle.fill` stand-in it's drawn from.
        #expect(catalog.iconTiles.first?.icon == .dot)
    }

    @Test func shuffleDrawsFromSymbolsAndEmoji() {
        // Full curated set, minus the dot stand-in, plus every emoji outside
        // the Flags category.
        let nonFlagEmoji = catalog.emoji.filter { $0.category != "Flags" }
        let expected = (catalog.symbols.count - 1) + nonFlagEmoji.count
        #expect(catalog.shuffleChoices.count == expected)
        #expect(!catalog.shuffleChoices.contains(.dot))
    }

    @Test func shuffleExcludesFlagEmoji() {
        let flagIcons = Set(
            catalog.emoji
                .filter { $0.category == "Flags" }
                .map { SidebarSpace.Icon.emoji($0.emoji) }
        )
        #expect(!flagIcons.isEmpty)
        #expect(catalog.shuffleChoices.allSatisfy { !flagIcons.contains($0) })
    }
}
