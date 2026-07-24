# 221 — Search: keyword/meaning toggle moved to results panel

## Summary

Relocated the **Keyword / Meaning** mode toggle out of the native `.searchScopes`
bar (which macOS rendered under the toolbar search field) and into a custom
segmented `Picker` at the top of the search results panel.

Behaviour is unchanged — it still binds to `LibrarySearchModel.mode`, and the
existing `.onChange(of: search.mode)` in `LibrarySearchable` still re-runs the
query via `modeChanged()`. Only the control's placement and rendering changed;
FTS keyword vs. semantic-cosine routing is untouched.

The toggle now appears leading-aligned and intrinsically sized (not full-width)
above the grid, and is visible in every active-search state (results, "No
results", "Searching…", and "Search failed").

## Files changed

- `AtelierRefs/AtelierRefs/LibrarySearch.swift`
  - `SearchFieldModifier`: removed the `.searchScopes($search.mode) { … }` modifier.
  - `LibrarySearchResults`: wrapped the body in a `VStack` and added a `modePicker`
    (`.pickerStyle(.segmented)`, `.labelsHidden()`, `.fixedSize()`) at the top.
  - Updated doc comments in `LibrarySearchable` and `SearchFieldModifier` that
    referenced the native scope bar.

## Migration notes

None. No model, service, or persistence changes. The `SearchMode` enum and all
query routing remain as-is.
