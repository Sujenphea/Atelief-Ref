# 297 — Settings: one surface, one door

The sidebar's Settings row and the ⌘, Settings window rendered the **same
`SettingsView`** — two doors into one room, neither of which was designed as a
split. Groundwork for 008 · H4, which adds the backup folder picker and cadence
toggle and needed a single, unambiguous home first.

## Summary

- **Settings is no longer a sidebar destination.** `SidebarItem.settings` is
  gone, along with the `AppShellView` branch that rendered `SettingsView` inside
  the detail panel. The ⌘, `Settings` scene is now the app's only settings
  surface — the one macOS puts in the app menu and binds to ⌘,.
- **The sidebar gear stays exactly where it was**, but calls
  `@Environment(\.openSettings)` instead of `nav.selectSidebar`. Discoverability
  is unchanged (the row is still the obvious place to look); only the door moved.
  It never draws a selected state, because the panel behind it doesn't move.
  Nav-row chrome is now shared via `rowButton(_:_:selected:action:)` so a styling
  change can't reach the destination rows and miss the gear.
- **This also fixes how the pane rendered.** `SettingsView` ends in
  `.frame(width: 460, height: 380)` — sized for a preferences window. The panel
  wrapped it in `.frame(maxWidth: .infinity, ...)`, but the inner fixed frame won,
  so the sidebar route showed a 460×380 form marooned in the full-size panel,
  under a library search field it had no use for.
- **Capture-token UI de-duplicated** (`CaptureTokenViews.swift`, new). The
  Settings capture section and the sidebar's `CapturePane` independently rendered
  the endpoint, the token, a Copy button, and the same explanatory sentence — and
  the sentence had already drifted: "AtelierRefs **browser** extension" in one,
  "AtelierRefs **Chrome** extension" in the other. `CaptureCopy` now owns the
  strings and display rules; `CaptureTokenText` / `CaptureTokenCopyButton` /
  `CaptureTokenExplainer` own the shared bits of presentation. **Layout stays with
  each surface** — a grouped `Form` row and a free-form pane genuinely want
  different chrome, and one view serving both would need a style flag per
  difference.
  - Wording settled on **Chrome**: that is the store the extension ships to
    (`extension/STORE-LISTING.md`), so it is the more actionable instruction. The
    third instance (the Regenerate confirmation) was updated to match.
  - `CaptureCopy.hasToken` is deliberately the exact `isEmpty` test
    `IngestionModel.copyCaptureToken()` guards on. A stricter rule here (trimming
    whitespace) would enable a button whose action then no-ops.

## Deferred

No **Customisation** page. The only user-tunable view preference in the app is
grid density (`GridViewPreferences`), already driven by ⌘+/⌘− and a toolbar
control; theme is tokens-only with no user choice. A page for one switch is
premature. When density, theme, and defaults do warrant a surface, they belong as
a *section or tab inside* the one Settings window — not a second page reached
from a different place.

## Files changed

- `AtelierRefs/AtelierRefs/NavModel.swift` — `SidebarItem.settings` removed; the
  enum doc records why settings is not a destination.
- `AtelierRefs/AtelierRefs/SidebarView.swift` — `settingsRow` opens ⌘,; nav-row
  chrome extracted to `rowButton`.
- `AtelierRefs/AtelierRefs/AppShellView.swift` — `.settings` branch removed;
  `CapturePane` consumes the shared capture views.
- `AtelierRefs/AtelierRefs/SettingsView.swift` — consumes the shared capture views.
- `AtelierRefs/AtelierRefs/CaptureTokenViews.swift` — new.
- Tests: `AtelierRefsTests/CaptureCopyTests.swift` (new, 11 tests);
  `CollectionActivationTests.swift` drops `.settings` from the non-collection
  destinations it enumerates (`.search` added — it was never covered).

## Test results

`AtelierRefsTests` — **TEST SUCCEEDED**, including all 11 new `CaptureCopyTests`.

`AtelierRefsUITests/testLaunchAndNavigateShell` fails, asserting
`app.buttons["Sweeps"]` exists at launch. **Pre-existing and unrelated** —
verified by running it against `4fde3c2` (the commit before this work), where it
fails identically. The suite still describes "the top-bar shell that replaced the
old 3-tab TabView"; changelog 193 moved Spaces and Capture into the sidebar and
put Sweeps behind Capture ▸ "Bulk Import Sweeps…", and the test was never
updated. The only `"Sweeps"` string in the app is a `Text` in the sheet header,
so no such button can exist at launch. Not fixed here — out of scope, and worth
its own pass over the whole smoke suite.

## Migration notes

Behavioural change for anyone used to the sidebar row: clicking the gear now
opens the Settings **window** rather than swapping the panel. Nothing persists
`SidebarItem`, so no stored state can hold a now-absent `.settings` case —
`NavModel.restoredSelection()` only ever restores `.collection` or `.home`.
