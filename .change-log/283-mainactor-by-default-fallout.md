# 283 — MainActor-by-default fallout

## Summary

The app target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and
`SWIFT_APPROACHABLE_CONCURRENCY = YES`, which makes every unannotated declaration
main-actor isolated — including pure namespaces and constants that have no state to
protect and are read from off-main code. This is the annotation pass that follows
from that, plus two unrelated compiler complaints in the same sweep.

**`nonisolated` on what was never isolated in the first place.** The pure-function
namespaces (`CollectionTargets`, `SpaceTargets`, `ExportDefaults`), the logging
namespace (`AppLog`), the lock-backed `CancelFlag`, and a handful of static
constants (`IngestionModel.bulkConsentKey`, `thumbnailStallMs`, `ingestLog`,
`BakeoffScrollDriver.defaultDuration`). `IngestionModel.logIngestTiming` was
`@Sendable` for the same reason and is now `nonisolated`, which says it directly:
no captured state, safe to hand to the off-main pipeline.

**`weak self` hoisted out of two `Task` closures** — `ExportController`'s progress
forwarder and `IngestionModel`'s remote-capture handler now `guard let self` before
the `Task { @MainActor in … }` rather than writing through `self?` inside it.

**`_ = try? await`** on five calls whose values were being dropped
(`pauseStaleOpenJobs` ×2, `reconcileOrphanedKnownItems`, `snapshot(reason:)` ×2) —
an unused `try?` result is a warning, and the discard is now written down.

**`isItemExpandable(_:item:)`** in `CollectionsOutlineView` and `SpacesOutlineView`
takes a non-optional `Any`, matching the SDK's audited signature.

## Files changed

- `CollectionTargets.swift`, `SpaceTargets.swift`, `MoodboardExport.swift`,
  `Diagnostics.swift`, `Debug/BakeoffScrollDriver.swift` — `nonisolated`.
- `ExportController.swift` — `nonisolated` on `CancelFlag`, `self` hoisted.
- `IngestionModel.swift` — `nonisolated` statics, `self` hoisted, explicit discards.
- `SnapshotManager.swift` — explicit discard.
- `CollectionsOutlineView.swift`, `SpacesOutlineView.swift` — SDK signature.

## Migration notes

- No behaviour change intended, with one nuance worth knowing: hoisting `guard let
  self` OUT of the `Task` means the closure now takes a strong reference at callback
  time and holds it across the hop to the main actor. Before, the object could be
  released before the hop landed and the write was simply skipped. For a progress
  ring and a capture handler that is the same outcome either way — the reference is
  held for the length of one hop, not for the length of the export.
- New pure namespaces in this target need `nonisolated` to be callable off-main.
  Under MainActor-by-default the annotation is not an optimisation; without it, the
  type is main-actor isolated whatever its contents.
