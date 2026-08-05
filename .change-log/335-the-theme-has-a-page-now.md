# 335 — The theme has a page now

`Theme.swift` has been the app's style guide for a while, but only as a comment.
There was nowhere to *see* it, which is how three `NS` mirrors drifted from their
`Colors` originals without anyone noticing (295), and how the Capture pane kept
the look of the toolbar popover it stopped being in 006.

Two halves: a specimen page for the tokens, and the surface that had drifted
furthest from them brought back onto them.

## The gallery

`ThemeGalleryView` — a **DEBUG-only** sidebar destination (`SidebarItem.theme`,
compiled out of release along with the row and the file's contents). Seven
sections: colour swatches, the `NS` mirrors, the type ramp, the spacing and
radius scales drawn to size, the two elevations, live specimens of everything in
`DialogControls.swift`, and the three motion springs run side by side.

It **derives** rather than restates. Hexes come from the live `Color` values via
`NSColor.usingColorSpace(.sRGB)`, and the mirrors section compares `Theme.NS`
against `Theme.Colors` at render time and flags a mismatch in `warning`. A page
that hard-coded `#2C2C30` beside `Colors.field` would be a fourth copy of the
palette and the next thing to drift.

In the sidebar rather than behind a launch argument (the `Debug/GridBakeoff*`
precedent) because the tokens have to be judged against the chrome they sit in —
a separate `NSWindow` would draw every swatch on a background that is not the
`panel` they are used over.

## Two new tokens

- **`Colors.warning`** — the app's one alarm colour, spelled `.orange` at eleven
  sites. Left as the SYSTEM orange rather than a hex, unlike every other colour
  token: the greys are the studio palette and have to be exact, but this one has
  to stay legible under Increase Contrast, which AppKit only does for a system
  colour. All eleven sites adopted it.
- **`Typography.mono`** — for a value that is a string of characters rather than
  a word. The two capture surfaces had been passing their own text *style* into
  `CaptureTokenText` (`.body` in Settings, `.callout` in the pane), which is how
  one token rendered at two sizes.

`pageTitle`'s doc comment named "Capture" as an example and `sectionTitle`'s did
not — the two contradicted each other once Capture became a pane. Corrected: a
sheet takes `pageTitle`, a pane takes `sectionTitle`.

## The Capture pane

Rebuilt on the tokens. The title drops from `pageTitle` to `sectionTitle` so all
four panes match; the two system `Divider()`s give way to titled groups inside
two `surface` cards (the app's raised-group idiom); the token sits in
`dialogFieldChrome()` as a value rather than floating as a caption; both buttons
take `DialogButtonStyle` — the default push button renders accent-filled, which
made it the most coloured chrome in an app whose theme states it has no accent.
`.secondary` → `inkSecondary`, the 40pt inset → `Spacing.xl` (what every other
pane uses), the bare `520` → `CaptureLayout.columnWidth`, and the column is now
centred instead of pinned `topLeading`, where it read as content cut off.

The green/orange status dot is now `CaptureEndpointDot`: a filled ink dot when
listening, a hollow `warning` ring when the port is taken. It read as a
two-colour severity scale the app doesn't have — the rule is that colour means
something is *wrong*. Shared with `OnboardingSheet`, which drew the same dot a
second time; the two surfaces keep their own sentences, since onboarding prints
the endpoint address on the row above.

## The Sweeps sheet

`StatusBadge` was a four-colour scale (green/orange/blue/grey) — the most
colour-coded thing in the app. Now a `field` capsule in `inkSecondary`, with only
`Stopped` in `warning`; a *paused* sweep was paused on purpose and resumes, so
colouring it would cry wolf. The sheet header moves to `pageTitle` +
`Spacing.md` + a `DialogButtonStyle` Done, matching `DuplicateReviewSheet` (the
two sheets had titled themselves at different sizes). `ProgressView` and the
failure links are tinted off the system accent. The consent panel's
`.borderedProminent` button becomes `DialogButtonStyle(width: .fill)`, and the
sweep row's `.quaternary` material becomes a real `surface` card.

## Copy says so now

`copyCaptureToken()` raises a "Pairing token copied" notice. The app's ⌘C
deliberately stays silent on a full success — "the pasteboard content is the
feedback, matching standard macOS Copy" (052 · B1) — but that reasoning doesn't
reach this case: the token is middle-truncated on every surface that shows it,
so what landed on the pasteboard is a string you cannot read back to check, and
the button had no state of its own. Posted from the MODEL so all three copy
surfaces report identically rather than three buttons each remembering to.

Caveat: `ToastHostView` is attached to the main window only, so Copy from the
Settings window posts onto the window behind it, and Copy in the onboarding
sheet posts underneath the sheet. Covering those properly wants an in-place
"Copied" button state, not a toast.

## The extension

`extension/src/theme.css` — the palette, spacing, radius and type roles as custom
properties, adopted by `popup.html` and `options.html`. Both were white-ground
light-mode pages with browser-default buttons and three hand-picked status
colours (`#8a5a00`, `#8a1f00`, `#2e8b57`) that exist nowhere in the product —
which is unfortunate, since the popup is the surface you look at *while*
capturing. `color-scheme: dark` so the parts the page doesn't draw (a `<select>`
dropdown, the checkbox tick, the caret) don't render white-on-white. Success
messages are monochrome now, for the same reason the status dot is.

Dark only, with no `prefers-color-scheme` variant, because the app is: it never
asks for a dark appearance, it just paints its own greys over whatever the system
is doing.

**The honest risk:** this is a second copy of the palette, and nothing checks the
two agree — Swift and CSS share no build step. The property names are kept
identical to their Swift originals so a drift is at least greppable. Change
values there only alongside the Swift side.

## Files

- `Theme.swift` — `Colors.warning`, `Typography.mono`, corrected title-role docs
- `ThemeGalleryView.swift` — new, DEBUG-only
- `NavModel.swift`, `SidebarView.swift` — the `theme` destination, DEBUG-only
- `AppShellView.swift` — `CapturePane` rebuilt, `CaptureLayout`, sheet header
- `CaptureTokenViews.swift` — `CaptureEndpointDot` / `CaptureEndpointStatus`,
  `mono`, the `tokenised` button flag, `tokenCopied`
- `IngestionModel.swift` — the copy confirmation
- `BulkSweepsView.swift` — badges, tints, consent button, sweep-row card
- `OnboardingSheet.swift`, `SettingsView.swift` — `warning` adoption
- `extension/src/theme.css` — new; `popup.html`, `options.html` adopt it

## Migration notes

None. No stored state, no schema, no API. `SidebarItem.theme` is `#if DEBUG` and
the relaunch restore only ever reconstructs `.home` or `.collection(_:)` from
`UserDefaults`, so a release build cannot be asked to decode it.

Two greens survive, both success checkmarks and both out of this change's scope:
`OnboardingSheet.swift:129` ("your first capture landed") and
`MoodboardExportControls.swift:160`.
