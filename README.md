<div align="center">
  <img src="docs/icon.png" width="128" alt="Enso icon" />
  <h1>Enso</h1>
  <p><strong>The terminal that keeps itself organized.</strong></p>
  <p>
    <img src="https://img.shields.io/badge/platform-macOS-6fa8ff" alt="macOS" />
    <img src="https://img.shields.io/badge/built%20on-libghostty-ff7eb6" alt="libghostty" />
    <img src="https://img.shields.io/github/v/release/amanfromsolan/enso?color=ffb454&label=release" alt="latest release" />
  </p>
</div>

Enso is a native macOS terminal. Tabs show what's actually running in them, with names and icons instead of `zsh · 80×24`. Workspaces keep projects apart, the command palette finds everything, and it's all GPU-fast thanks to [libghostty](https://github.com/ghostty-org/ghostty). If you run AI coding agents all day, Enso is especially good at that.

![Enso screenshot](docs/screenshot.png)

## Download

**[⬇ Download Enso.dmg](https://github.com/amanfromsolan/enso/releases/latest)** — signed & notarized, no security prompts. Drag to Applications, open, done.

> ⚠️ Enso is pre-1.0 — expect breaking changes between releases.

## Highlights

- **🪷 Spaces:** swipeable workspaces in the sidebar, each with its own tabs and folders. Swipe past the last one to create a new one.

- **🕵️ Icons for what's running:** Claude, Codex, Gemini, and Ollama show their real logos; vim, ssh, git, and docker get glyphs; idle shells show a default terminal icon.

- **🔁 Tabs that survive a restart:** tabs running Claude or Codex pick up right where they left off after a relaunch.

- **⌘T Command palette:** every tab, space, and command in one search. Jump with `⌘1–9`, rename inline, duplicate, close others, open in Finder.

- **⌃Tab switcher:** flip through your recent tabs with a live preview, like the app switcher but for terminals.

- **🌗 Feels like a Mac app:** native SwiftUI chrome that follows your system's light or dark look, while the terminal keeps your Ghostty theme.

- **📌 A sidebar that never rots:** pin tabs to keep them forever, group them into folders, double-click to rename. Unpinned tabs quietly expire after 24 hours.

## Keyboard

| Shortcut | Action |
| --- | --- |
| `⌘T` / `⌘P` | Command center |
| `⌘N` | New tab |
| `⌘W` | Close tab |
| `⌃Tab` | MRU tab switcher |
| `⌘1–9` | Jump to tab |
| `⇧⌘P` | Pin / unpin tab |
| `⇧⌘[` / `⇧⌘]` | Previous / next tab |
| `⌘,` | Settings |

## Build from source

Enso embeds [Ghostty](https://github.com/ghostty-org/ghostty)'s `GhosttyKit.xcframework`, which isn't vendored in this repo:

```sh
git clone https://github.com/ghostty-org/ghostty references/ghostty
cd references/ghostty && zig build -Doptimize=ReleaseFast -Demit-macos-app=false
cd ../.. && ln -s ../references/ghostty/macos/GhosttyKit.xcframework macos/GhosttyKit.xcframework
xcodebuild -project macos/Enso.xcodeproj -scheme Enso build
```

`script/release.sh` cuts a signed, notarized DMG (needs a Developer ID certificate and a `notarytool` keychain profile).

## Credits

Terminal emulation, PTY, and Metal rendering by [Ghostty](https://ghostty.org) — Enso is UI and workflow on top of `libghostty`. Agent logos via [Simple Icons](https://simpleicons.org) and [LobeHub](https://icons.lobehub.com).

## License

Enso is open source under the [GNU General Public License v3.0](LICENSE). Ghostty (MIT) and other bundled components retain their original licenses.
