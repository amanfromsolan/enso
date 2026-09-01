#!/usr/bin/env python3
"""Converts RELEASE_NOTES/<version>.md into the XHTML fragment Sparkle
embeds in the appcast (and Enso's What's New sheet parses back).

The markdown is a deliberately strict subset — the gate that guarantees
the in-app parser only ever sees well-formed XHTML:

    ## Section          e.g. New / Improved / Fixed
    - one change, written as a user-facing sentence
    a free-standing line becomes a paragraph (intro or footer prose)

Inline [label](https://...) links are allowed anywhere and become
<a href> — the GitHub release body renders them, and the What's New
sheet shows them tappable. Anything fancier (**bold**, `code`, nested
lists) is an error: release.sh runs this before building, so a
malformed notes file stops the release instead of shipping.

Usage: release_notes.py <notes.md>   (fragment on stdout, errors on stderr)
"""
import html
import pathlib
import re
import sys

LINK = re.compile(r"\[([^\]]+)\]\(([^)\s]+)\)")


def render_inline(text: str, n: int, errors: list[str]) -> str | None:
    """Escaped plain text plus [label](url) links; anything fancier errors."""
    if "**" in text or "`" in text:
        errors.append(
            f"line {n}: inline markdown is not rendered — write plain text: {text[:60]}"
        )
        return None

    out: list[str] = []
    pos = 0
    for m in LINK.finditer(text):
        url = m.group(2)
        if not url.startswith(("https://", "http://", "mailto:")):
            errors.append(f"line {n}: link needs an absolute http(s)/mailto url: {url[:60]}")
            return None
        out.append(html.escape(text[pos : m.start()]))
        out.append(f'<a href="{html.escape(url, quote=True)}">{html.escape(m.group(1))}</a>')
        pos = m.end()

    rest = text[pos:]
    if "](" in rest:
        errors.append(f"line {n}: malformed link: {rest[:60]}")
        return None
    out.append(html.escape(rest))
    return "".join(out)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: release_notes.py <notes.md>", file=sys.stderr)
        return 2

    src = pathlib.Path(sys.argv[1])
    if not src.is_file():
        print(f"error: {src} does not exist", file=sys.stderr)
        return 1

    out: list[str] = []
    errors: list[str] = []
    section_seen = False
    list_open = False
    item_count = 0

    for n, raw in enumerate(src.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line:
            continue

        if line.startswith("## "):
            title = line[3:].strip()
            if not title:
                errors.append(f"line {n}: empty section title")
                continue
            if list_open:
                out.append("</ul>")
                list_open = False
            out.append(f"<h2>{html.escape(title)}</h2>")
            section_seen = True
        elif line.startswith("- "):
            item = line[2:].strip()
            if not section_seen:
                errors.append(f"line {n}: bullet before any '## Section' heading")
                continue
            if not item:
                errors.append(f"line {n}: empty bullet")
                continue
            rendered = render_inline(item, n, errors)
            if rendered is None:
                continue
            if not list_open:
                out.append("<ul>")
                list_open = True
            out.append(f"<li>{rendered}</li>")
            item_count += 1
        else:
            # Free-standing prose: an intro or footer paragraph. It closes
            # any open list; a later bullet under the same section simply
            # opens a fresh one.
            rendered = render_inline(line, n, errors)
            if rendered is None:
                continue
            if list_open:
                out.append("</ul>")
                list_open = False
            out.append(f"<p>{rendered}</p>")
            item_count += 1

    if list_open:
        out.append("</ul>")
    if item_count == 0:
        errors.append("no items: notes need at least one '## Section' with one '- item'")

    if errors:
        for e in errors:
            print(f"error: {e}", file=sys.stderr)
        return 1

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
