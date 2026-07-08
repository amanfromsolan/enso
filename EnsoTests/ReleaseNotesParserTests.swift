import Testing
@testable import Enso

/// The What's New sheet must survive whatever the appcast hands it: the
/// canonical h2/li subset our pipeline emits, but also hand-edited HTML,
/// inline markup, entities, and outright malformed input — everything
/// degrades to readable text, and only truly empty input hides the sheet.
@MainActor
struct ReleaseNotesParserTests {
    @Test func parsesCanonicalPipelineOutput() {
        let html = """
        <h2>New</h2>
        <ul>
        <li>Release notes show up in the app.</li>
        <li>Finder service added.</li>
        </ul>
        <h2>Fixed</h2>
        <ul>
        <li>Palette no longer spawns terminals.</li>
        </ul>
        """
        let content = ReleaseNotesParser.parse(html: html, version: "0.5.0")

        #expect(content?.version == "0.5.0")
        #expect(content?.sections.count == 2)
        #expect(content?.sections[0].title == "New")
        #expect(content?.sections[0].items == [
            "Release notes show up in the app.",
            "Finder service added."
        ])
        #expect(content?.sections[1].title == "Fixed")
        #expect(content?.sections[1].items == ["Palette no longer spawns terminals."])
    }

    @Test func flattensInlineMarkupToText() {
        let html = "<h2>New</h2><ul><li>Now with <b>bold</b> and <a href=\"https://x.com\">links</a>.</li></ul>"
        let content = ReleaseNotesParser.parse(html: html, version: "1.0")

        #expect(content?.sections[0].items == ["Now with bold and links."])
    }

    @Test func strayProseBecomesUntitledSection() {
        let html = "<p>A big release.</p><h2>Fixed</h2><ul><li>The bug.</li></ul>"
        let content = ReleaseNotesParser.parse(html: html, version: "1.0")

        #expect(content?.sections.count == 2)
        #expect(content?.sections[0].title == "")
        #expect(content?.sections[0].items == ["A big release."])
        #expect(content?.sections[1].title == "Fixed")
    }

    @Test func toleratesHTMLEntities() {
        let html = "<h2>New</h2><ul><li>Fast&nbsp;&amp;&nbsp;flexible &mdash; really.</li></ul>"
        let content = ReleaseNotesParser.parse(html: html, version: "1.0")

        #expect(content?.sections[0].items == ["Fast & flexible — really."])
    }

    @Test func malformedHTMLFallsBackToStrippedText() {
        // Unclosed <ul> is not well-formed XML; the strip fallback should
        // still surface every line of text.
        let html = "<h2>New</h2><ul><li>First thing.<li>Second thing."
        let content = ReleaseNotesParser.parse(html: html, version: "1.0")

        #expect(content != nil)
        let allText = content?.sections.flatMap(\.items).joined(separator: " ") ?? ""
        #expect(allText.contains("First thing."))
        #expect(allText.contains("Second thing."))
    }

    @Test func headingWithoutItemsIsDropped() {
        let html = "<h2>New</h2><ul></ul><h2>Fixed</h2><ul><li>The bug.</li></ul>"
        let content = ReleaseNotesParser.parse(html: html, version: "1.0")

        #expect(content?.sections.count == 1)
        #expect(content?.sections[0].title == "Fixed")
    }

    @Test func emptyInputReturnsNil() {
        #expect(ReleaseNotesParser.parse(html: "", version: "1.0") == nil)
        #expect(ReleaseNotesParser.parse(html: "   \n  ", version: "1.0") == nil)
        #expect(ReleaseNotesParser.parse(html: "<ul></ul>", version: "1.0") == nil)
    }

    @Test func plainTextWithNoTagsStillShows() {
        let content = ReleaseNotesParser.parse(html: "Just a sentence about the release.", version: "1.0")

        #expect(content?.sections.count == 1)
        #expect(content?.sections[0].items == ["Just a sentence about the release."])
    }

    @Test func whitespaceBetweenTagsIsNotAnItem() {
        let html = "<h2>New</h2>\n  \n<ul>\n  <li>Real item.</li>\n</ul>\n"
        let content = ReleaseNotesParser.parse(html: html, version: "1.0")

        #expect(content?.sections.count == 1)
        #expect(content?.sections[0].items == ["Real item."])
    }
}
