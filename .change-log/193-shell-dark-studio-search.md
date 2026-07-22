# 193 — Shell: dark-studio sidebar + native toolbar search

Lands the 006 redesign shell — the `Theme` token layer, the custom sidebar,
and the relocation of Search into the native window toolbar. Follows the
approved plan (WS1 foundation + WS6 shell), plus a search-behaviour pass driven
by feedback.

## What ships

### Theme foundation (WS1)

- **New `Theme.swift`** — the app's single design-token layer: a dark-studio
  **monochrome** palette (`canvasOuter #131313`, `panel #212121`, `surface
  #232326`, `field #2C2C30`, `selection #3A3A40`, `mediaBackdrop #141416`,
  `filmstrip #1A1A1C`, `inkPrimary/Secondary`, `hairline` / `hairlineStrong`),
  plus `Spacing` (4-pt scale), `Radius`, `Motion` (one canonical spring set),
  `Elevation`, and `Typography` roles. Also `VisualEffectBackground`
  (`NSViewRepresentable`), the `.elevation(_:)` modifier, and compile-time
  `Color(hex:)` / `NSColor(hex:)`.
- **`AccentColor.colorset`** filled with near-white `#F2F1EE` so system controls
  read monochrome.
- **Forced dark + native translucent window** — `ContentView` sets
  `.preferredColorScheme(.dark)` + a `VisualEffectBackground`; `AtelierRefsApp`
  keeps `.windowStyle(.hiddenTitleBar)` and sets `NSApp.appearance = .darkAqua`.

### Sidebar shell (WS6)

- **New `SidebarView.swift`** — a custom two-width leading column (273pt
  expanded ↔ 60pt rail) replacing the `NavigationStack`-of-cover-cards. Nav
  (Home / Capture / Settings), Spaces + Collections trees
  (`CollectionTargets.galleryRoots`, Unsorted pinned), a sort + trash footer,
  and the `sidebar.right` collapse toggle. Active row uses the brighter
  `selection` fill + `hairlineStrong` border so the current destination pops.
  Nav rows are 14pt with a 6pt gap.
- **`AppShellView`** — `HStack { SidebarView; detailPanel }`; the panel is an
  opaque `#212121` rounded inset with a floating `+`. `rootContent` switches on
  `nav.sidebarSelection`.
- **`NavModel`** — selection-driven (`SidebarItem` enum, `sidebarSelection`,
  `sidebarCollapsed`); relaunch-restore seeds the selection.
- `CollectionView` / `CollectionsGalleryView` shed their old `.searchable` /
  toolbar chrome (now owned by the shell).

### Search → native toolbar

- **Search left the sidebar.** It is now Apple's native `.searchable` token
  field, hosted in the window toolbar via `LibrarySearchable` wrapping **every**
  pane. Wrapping all panes keeps the toolbar height — and therefore the traffic
  lights — constant; previously the lights jumped when search appeared /
  disappeared between panes.
- **Scope filter removed.** No more This Collection / All bar; search stays
  scoped to the current collection, global elsewhere (model default retained).
- **Empty states fill the panel** — the No results / Searching / Search failed
  views centre in the full panel instead of hugging their text.

## Files changed

- **New:** `Theme.swift`, `SidebarView.swift`.
- `AppShellView.swift` — split-view shell; every pane wrapped in
  `LibrarySearchable`.
- `NavModel.swift` — sidebar selection state + restore.
- `ContentView.swift` / `AtelierRefsApp.swift` — dark + translucent window.
- `CollectionView.swift` / `CollectionsGalleryView.swift` — drop inline search /
  toolbar chrome.
- `LibrarySearch.swift` — native `.searchable` only (scope bar removed),
  empty-state fill.
- `Assets.xcassets/AccentColor.colorset/Contents.json` — monochrome accent.

## Verification

- `xcodebuild build -scheme AtelierRefs` → **BUILD SUCCEEDED**.
- Ran & eyeballed: sidebar selection / collapse, pane switching (lights hold),
  native search field + Esc-to-clear + cancel button.

## Migration notes

No data or schema change. Light mode is dropped (committed dark identity). The
custom-search-bar experiments (in-content field, toolbar-hosted custom field)
were reverted in favour of the native `.searchable`; the `LibrarySearchModel`
token / suggestion / scope API is unchanged and still available for a future
suggestions popover.
