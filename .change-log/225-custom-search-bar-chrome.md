# 225 — Custom search field in the window toolbar (app chrome)

## Summary

Replaced the native `.searchable` toolbar token field with a custom `SearchToolbarField`
styled to the app's design system (the same `field` capsule language as the selection
action bar), hosted in the **window toolbar at the trailing edge** — same place as the
old native field, but now matching the app chrome.

- `SearchToolbarField` (private, `LibrarySearch.swift`): a leading magnifying glass,
  inline removable token chips (`SearchTokenChip`), the plain free-text field, and a
  trailing clear `×`. It draws NO background of its own — the macOS 26 toolbar item
  supplies the outer glass rect it sits in (an added `field` capsule just double-stacked
  behind the glass). Hosted via `ToolbarItem(placement: .primaryAction)`, fixed 360pt.
- `SearchSuggestionsDropdown` (private): the prefix-matched tag / collection suggestions,
  reusing the shared `SelectionMenuRow` (design-system card + rows). A toolbar item
  clips an attached overlay, so the dropdown is floated as a sibling at the **top of the
  panel, trailing edge**, roughly under the field — a popover was rejected because it
  steals first responder from the field and breaks live typing.
- Rebuilt the native affordances on the model: Esc clears the query, ⌘F focuses the
  field, clicking away in the content dismisses the dropdown, chips remove individually.

## Decisions (confirmed with the user)

- Placement: **right / trailing** in the toolbar (classic macOS search position).
- Width: **fixed compact** (360pt).
- Suggestions: **float under the toolbar** (approximate alignment; keeps live typing).
- Panes: **all panes** (Home, Collection, Settings, Space, Capture) — consistent toolbar.

## Model additions (`LibrarySearchModel`)

- `clearSuggestions()` — hide the open dropdown without touching the query.
- `clearQuery()` — clear text + tokens (the `×` / Esc).
- `removeToken(_:)` — drop one chip.
- `selectSuggestion(_:)` — promote a suggested token and clear the matched text.

## Files changed

- `AtelierRefs/AtelierRefs/LibrarySearch.swift` — removed `SearchFieldModifier` and the
  `.searchable` modifier; `LibrarySearchable` now hosts `SearchToolbarField` in a
  `.toolbar` item and floats `SearchSuggestionsDropdown` at the panel's top-trailing;
  added `SearchToolbarField` / `SearchSuggestionsDropdown` / `SearchTokenChip` and the
  four model helpers; refreshed the file / type doc comments.
- `AtelierRefs/AtelierRefs/AppShellView.swift` — updated the `rootContent` comment (field
  is a custom toolbar item now, not native `.searchable`).

## Notes

- Query behaviour is unchanged — still bound to `search.text` / `search.tokens`, still
  re-runs through the existing `onChange` hooks in `LibrarySearchable`.
- Tradeoff (accepted): the native token field's Esc-clear / focus ring / cancel button /
  token chips are now custom-rebuilt. Token chips render on a single line (no wrap yet);
  the dropdown's alignment under the field is approximate, not pixel-perfect.
- Build succeeds.
