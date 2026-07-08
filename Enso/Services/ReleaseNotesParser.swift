import Foundation

/// Turns the release-notes HTML from a Sparkle appcast item back into
/// WhatsNewSheet sections.
///
/// The happy path is the strict <h2>/<ul><li> subset our own release
/// pipeline emits (script/release_notes.py), but this end never assumes
/// it: unknown tags are flattened to their text, stray prose becomes an
/// untitled section, HTML entities are tolerated, and input that isn't
/// parseable XML at all falls back to stripping tags — so a hand-edited
/// or future-format appcast degrades to plain readable text instead of
/// breaking the sheet. Returns nil only when nothing displayable is left,
/// which callers should treat as "don't show the popup".
enum ReleaseNotesParser {
    static func parse(html: String, version: String) -> WhatsNewSheet.Content? {
        let sections = structured(html) ?? strippedFallback(html)

        let displayable = sections
            .map { WhatsNewSheet.Content.Section(title: $0.title, items: $0.items) }
            .filter { !$0.items.isEmpty }
        guard !displayable.isEmpty else { return nil }

        return WhatsNewSheet.Content(version: version, sections: displayable)
    }

    // MARK: - Structured pass (XML walk)

    private typealias RawSection = (title: String, items: [String])

    private static func structured(_ html: String) -> [RawSection]? {
        // XMLParser chokes on HTML-only entities; normalize the common
        // ones (and any fragment needs a single root).
        var normalized = html
        for (entity, plain) in htmlEntities {
            normalized = normalized.replacingOccurrences(of: entity, with: plain)
        }
        let wrapped = "<notes>\(normalized)</notes>"

        let collector = Collector()
        let parser = XMLParser(data: Data(wrapped.utf8))
        parser.delegate = collector
        guard parser.parse() else { return nil }
        return collector.sections
    }

    /// Collects h2/h3 headings as section boundaries and li/p contents as
    /// items; text inside any other tag flows through untouched, so
    /// inline markup like <b> or <a> flattens to its words.
    private final class Collector: NSObject, XMLParserDelegate {
        var sections: [RawSection] = []
        private var buffer = ""

        func parser(
            _ parser: XMLParser, didStartElement name: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch name.lowercased() {
            case "h1", "h2", "h3", "li", "p":
                flushStrayText()
            case "br":
                buffer += " "
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser, didEndElement name: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            switch name.lowercased() {
            case "h1", "h2", "h3":
                let title = collapsed(buffer)
                if !title.isEmpty {
                    sections.append((title: title, items: []))
                }
                buffer = ""
            case "li", "p":
                appendItem(collapsed(buffer))
                buffer = ""
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            buffer += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            flushStrayText()
        }

        /// Text sitting outside any h2/li (an intro paragraph without
        /// tags, say) still deserves to show — file it as an item.
        private func flushStrayText() {
            appendItem(collapsed(buffer))
            buffer = ""
        }

        private func appendItem(_ text: String) {
            guard !text.isEmpty else { return }
            if sections.isEmpty {
                sections.append((title: "", items: []))
            }
            sections[sections.count - 1].items.append(text)
        }
    }

    // MARK: - Fallback pass (tag strip)

    private static func strippedFallback(_ html: String) -> [RawSection] {
        var text = html.replacingOccurrences(
            of: "<[^>]*>", with: "\n", options: .regularExpression
        )
        for (entity, plain) in htmlEntities + xmlEntities {
            text = text.replacingOccurrences(of: entity, with: plain)
        }
        let items = text
            .components(separatedBy: .newlines)
            .map(collapsed)
            .filter { !$0.isEmpty }
        return [(title: "", items: items)]
    }

    // MARK: - Shared helpers

    private static let htmlEntities: [(String, String)] = [
        ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"),
        ("&lsquo;", "\u{2018}"), ("&rsquo;", "\u{2019}"),
        ("&ldquo;", "\u{201C}"), ("&rdquo;", "\u{201D}")
    ]

    private static let xmlEntities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&apos;", "'"),
        ("&amp;", "&")  // last, so it can't re-expand the others
    ]

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
