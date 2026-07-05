# 062 — Bulk import: app progress, consent gate, working controls (Phase 7)

Phase 7 of bulk import ([.docs/018](../.docs/018-bulk-import-plan.md)): the app-side
UI — a consent gate on the first sweep, a live ledger-driven progress view, and
pause/resume/cancel controls that a running BROWSER sweep actually honours. Decision
4A + the legal framing; spans AtelierCore + AtelierServer + the extension + the app.

## The cross-boundary problem

The sweep loop runs in the browser, but progress + controls live in the app. So
controls that merely mark the ledger would be cosmetic. Instead, the app-side status
change is fed back to the running loop through the **per-item relay reply**: every
tagged ingest response now carries the owning job's current status, and the extension
halts the sweep the moment it sees `paused`/`halted`. Pull-based, no new channel.

## Summary

- **AtelierCore** — three ledger reads on `AppServices`: `listJobs` (progress list),
  `jobItemCounts` (per-outcome tally via `GROUP BY`, not row-loading), and
  `jobStatus` (the lightweight status the relay feedback polls).
- **AtelierServer**
  - **Consent gate**: `JobRoutes` gains a `consentGranted` closure; `POST /jobs`
    returns **403 `consent_required`** before consent, ahead of any ledger touch.
    `JobLedger` gains `jobStatus(forJob:)`.
  - **Relay feedback**: `CaptureResponse` gains an optional `jobStatus`, stamped ONLY
    on a bulk-tagged capture's reply (nil + unencoded for single-item — the wire is
    unchanged). Best-effort: a ledger read never blocks an ingest that already happened.
- **Extension** — `ingestOne` surfaces the reply's `jobStatus`; `classifyIngestResult`
  records the item then returns `signal: "halt"` when the job is `paused`/`halted`.
  So a pause/cancel in the app stops the sweep on its next item, checkpoint intact.
- **App** — `IngestionModel`: a persisted `bulkConsentGranted` flag (the SAME
  UserDefaults key the server's gate reads), `grant/revokeBulkConsent`, a `sweeps`
  list with `SweepProgress` (ingested/skipped/failed/estimate), a polling
  `refreshSweeps`, and `pause/resume/cancelSweep` → `setJobStatus`. New
  `BulkSweepsView` (a third "Sweeps" tab): the consent disclosure panel before
  acceptance (own-data-only, human-paced, ToS/account-risk), the live progress list
  with controls after.

## Files changed

- Core: `AppServices.swift` (+3 queries), `ServicesJobTests.swift` (+3 tests).
- Server: `JobDTO.swift` (`jobStatus` seam + `consentRequired`), `JobRoutes.swift`
  (consent gate), `CaptureDTO.swift` (`CaptureResponse.jobStatus`), `CaptureRoutes.swift`
  (stamp status), `JobRoutesTests.swift` (consent 403 + relay-feedback + fake).
- Extension: `sw.js` (`ingestOne` jobStatus), `bulk-engine.js` (`classifyIngestResult`
  halt), tests: `sw.test.js`, `bulk-engine.test.js`, `bulk-controller.test.js`.
- App: `IngestionModel.swift` (consent + sweeps + wire the gate), `BulkSweepsView.swift`
  (new), `ContentView.swift` (Sweeps tab).

## Control semantics (honest)

- **Pause** → job `paused`; the browser loop halts on its next item and checkpoints.
- **Resume** → job re-`open`ed so a fresh browser run continues from the checkpoint
  (the app can't re-trigger the browser; the user restarts the sweep, which resumes).
- **Cancel** → job `halted`; the loop stops on its next item.
- The feedback rides the IMAGE ingest reply (the common bulk path — posters). A pure
  bulk-video item's pause takes effect on the next image item; wiring the video reply
  is a small follow-up (bulk video is opt-in/rare).

## Verification

All green: `swift test` AtelierCore **184** + AtelierServer **70**; extension
`npm test` **155**; `xcodebuild -scheme AtelierRefs` **BUILD SUCCEEDED**. New coverage:
the consent 403 gate, the tagged-reply job status (+ untagged omission), the three
new ledger queries, and the pause→halt path end-to-end through the controller.
