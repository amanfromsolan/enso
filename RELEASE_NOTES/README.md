# Release notes

One file per release: `RELEASE_NOTES/<version>.md` (e.g. `0.5.0.md`).
`script/release.sh` refuses to build without a valid one. The same file
becomes, verbatim:

1. the Sparkle appcast release notes → Enso's in-app **What's New** sheet
2. the GitHub release body

## Format (strict — validated by `script/release_notes.py`)

Exactly two constructs are allowed; anything else fails the release:

```markdown
## New
- One change per bullet, written as a plain sentence.

## Improved
- Another change.

## Fixed
- Another change.
```

Rejected by the validator:

- prose outside a `- ` bullet
- bullets before the first `## Section`
- nested lists or multi-line bullets
- inline markdown — `**bold**`, `[links](…)`, backtick code — the in-app
  sheet renders plain text, so these would show as literal characters
- empty sections or empty bullets

Section names are free-form (they render as small-caps headers in-app),
but the convention is **New, Improved, Fixed**, in that order, skipping
any that are empty. Unicode is fine — em dashes, arrows, quotes.

## Voice — write for the user, not the diff

- Say what changed *for the person using Enso*, not what changed in the
  code. "Command palette no longer spawns a stray terminal when you
  press Enter" — not "Fix NSEvent monitor leak in CommandCenter".
- Name things the way the UI names them (the sidebar, the command
  palette, spaces), never by type or file name.
- One sentence per bullet, two at most. Lead with the outcome.
- Aim for 4–8 bullets per release; fold minor internal work into one
  bullet or leave it out. Every bullet should pass "would a user care?"
- Don't mention versions, dates, or "this release" inside bullets — the
  surrounding UI already says all of that.

## Checking your draft

```sh
python3 script/release_notes.py RELEASE_NOTES/<version>.md   # validate + preview HTML
```

To see it in the real UI: run the dev build with `ENSO_WHATS_NEW=sheet`
(the What's New sheet opens with canned content; for your actual draft,
paste its HTML into `UpdateController.debugNotesHTML`).
