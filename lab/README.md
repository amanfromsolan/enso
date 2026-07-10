# EnsoLab

A standalone SwiftUI design lab for the Enso terminal. It hosts visual
experiments — starting with a command-palette redesign — without building or
launching the real app. No dependency on the Enso module, GhosttyKit, or any
external package; pure SwiftUI + AppKit.

## Run

```sh
cd lab
swift run
```

The window is dark-themed and translucent (behind-window blur), roughly
1180×760, with a hidden titlebar — the same shell aesthetic as Enso.

## Structure

```
Sources/EnsoLab/
  EnsoLabApp.swift        @main App + AppDelegate (forces a regular, active,
                          dark app since SPM executables ship no Info.plist)
  Experiment.swift        Experiment model + ExperimentCatalog registry
  IndexView.swift         RootView (index ⇄ experiment nav) + launcher screen
  Shared/
    VisualEffect.swift    NSVisualEffectView wrapper
    MockData.swift        Mock spaces, tabs, folders, palette items
    MockTerminal.swift    Static fake terminal card (.empty / .filled)
    MockSidebar.swift     Fake Enso sidebar (248pt, real row styling)
    EnsoBackdrop.swift    Sidebar + terminal composed as a fake Enso window
  Experiments/
    Exp01CommandPalette.swift   Baseline command palette
```

## Adding an experiment

1. Add a file under `Sources/EnsoLab/Experiments/` with a `View` for it.
   Stage it over `EnsoBackdrop(terminal:)` if you want a realistic context.
2. Register it in `ExperimentCatalog.all` (`Experiment.swift`): give it an
   `id`, `number`, `title`, `subtitle`, `folder` (the index section header),
   and a `makeView` closure returning `AnyView(YourExperiment())`.

That's it — the index screen groups by `folder` and lists it automatically.
