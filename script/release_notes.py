#!/usr/bin/env python3
"""Converts RELEASE_NOTES/<version>.md into the XHTML fragment Sparkle
embeds in the appcast (and Enso's What's New sheet parses back).

The markdown is a deliberately strict subset — the gate that guarantees
the in-app parser only ever sees well-formed <h2>/<ul><li> XHTML:

    ## Section          e.g. New / Improved / Fixed
    - one change, written as a user-facing sentence

Anything else (stray prose, nested lists, inline markdown like **bold**
or [links](...)) is an error: release.sh runs this before building, so a
malformed notes file stops the release instead of shipping.

Usage: release_notes.py <notes.md>   (fragment on stdout, errors on stderr)
"""
import html
import pathlib
import sys


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
    section_open = False
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
            if section_open:
                out.append("</ul>")
            out.append(f"<h2>{html.escape(title)}</h2>")
            out.append("<ul>")
            section_open = True
        elif line.startswith("- "):
            item = line[2:].strip()
            if not section_open:
                errors.append(f"line {n}: bullet before any '## Section' heading")
                continue
            if not item:
                errors.append(f"line {n}: empty bullet")
                continue
            if "**" in item or "](" in item or item.startswith("`"):
                errors.append(
                    f"line {n}: inline markdown is not rendered — write plain text: {item[:60]}"
                )
                continue
            out.append(f"<li>{html.escape(item)}</li>")
            item_count += 1
        else:
            errors.append(
                f"line {n}: unrecognized line (only '## Section' and '- item' allowed): {line[:60]}"
            )

    if section_open:
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
