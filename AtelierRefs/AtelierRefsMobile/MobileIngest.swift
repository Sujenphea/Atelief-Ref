// AtelierRefsMobile — the phone's ingest, and the two numbers that make it the
// phone's rather than the Mac's (096 · 4, phase 3).
//
// `InboxDrain` has had no caller on iOS since it was written: the share extension
// put captures in `inbox/` and they sat there until a Mac was opened, so a capture
// made on the phone was invisible on the phone. `.change-log/452` made
// AtelierIngestion build for this platform and `.change-log/453` made a drained
// record survive for export; what was still missing was a caller. This is it — the
// composition root, and nothing else. WHEN a pass runs lives in
// ``InboxDrainScheduler``, exactly as it does on the Mac.
//
// **The same pipeline, not a phone-shaped copy of it.** Every ingest in this program
// funnels through one `IngestPipeline` behind one bounded `IngestCoordinator`, and
// the drain's own header spends a paragraph on why it is a producer for that
// coordinator rather than a second runner with its own opinion about how much of the
// machine to spend. That argument is not about macOS; it is about there being one
// answer per process. So the phone builds the same three objects the Mac builds, and
// differs in exactly two constants — both stated here, both with the reason attached,
// because a number without its argument is a number the next person will "tidy".
//
// **The library it drains into is its own, and the capture is still owed to the Mac.**
// Hence ``InboxDrain/Retention/retainForExport`` at the call site below: the phone is a
// waypoint, not a destination, and `InboxArchive` reads the inbox — not the SQLite
// library, which holds only what the Mac has synced back — so a drain that deleted the
// record would destroy the only copy the export has.

import AtelierCore
import AtelierIngestion
import Foundation
import os

/// The companion's log. The Mac's `AppLog` is in the macOS target and this is the
/// same idea at the size the phone needs it: the drain reports conditions the user has
/// no lever for (an unreadable container, a quarantined capture), which 093 § 7 and the
/// Mac's scheduler both settle the same way — the log, not a notice.
nonisolated enum MobileLog {
    static let subsystem = "sujenphea.AtelierRefsMobile"
    /// Everything on the capture path: the drain's cadence and what a pass found.
    static let capture = Logger(subsystem: subsystem, category: "capture")
}

/// Builds the phone's ingest stack. A namespace, `static` only — it owns no state,
/// because the state it would own (`AppServices`, the library root) is already owned by
/// ``LibraryStore``, which opens the library once for the life of the process.
enum MobileIngest {
    // MARK: - The two numbers that are not the Mac's

    /// The thumbnail tiers a drained capture gets on this device: the grid tier and the
    /// detail tier, and **not** the 128 px tier.
    ///
    /// `IngestPipeline` defaults to `ThumbnailTier.allCases` — 128 / 512 / 1280 — because
    /// the Mac's canvas renderer picks a LOD per tile and 128 is the one it uses for
    /// distant, densely packed tiles. **The phone has no canvas.** It reads exactly two
    /// files: `LibraryMediaPaths.gridThumbnailSize` (512) for a masonry tile and
    /// `LibraryMediaPaths.detailThumbnailSize` (1280) for the item screen — see
    /// `LibraryStore.gridThumbnailURL(for:)` / `detailImageURL(for:)`, which are the only
    /// two thumbnail readers in the app. A 128 px tier generated here is a decode, a JPEG
    /// encode and a file write per capture for a file nothing on this device will open.
    ///
    /// Narrowing is a constructor argument the pipeline has always taken (P14 regenerates
    /// only MISSING tiers, per tier), so this costs the pipeline nothing and restructures
    /// nothing.
    ///
    /// Spelled as the two cases rather than derived from the two constants because
    /// `ThumbnailTier(rawValue:)` is failable and a `compactMap` that silently dropped one
    /// would silently stop generating a tier the grid draws. That the cases and the
    /// constants agree is pinned by `ThumbnailTierAgreementTests` in AtelierIngestion —
    /// the one place that can see both.
    ///
    /// **This is not a decision about what the MAC ends up with.** The export sends the
    /// inbox record and its original payload, so a capture imported on the Mac is ingested
    /// there from the original bytes and gets every tier the Mac generates.
    static let thumbnailTiers: [ThumbnailTier] = [.medium, .large]

    /// How many captures the drain decodes at once here: **2**, against the coordinator's
    /// default of 4.
    ///
    /// **A cautious default, not a measured one.** Nothing in this program has profiled an
    /// inbox drain on a device, and this number should be revisited by measurement rather
    /// than by taste. What it rests on:
    ///
    ///   · the default of 4 was chosen for a Mac, where the ceiling is the machine's RAM
    ///     and the penalty for guessing high is a slow minute;
    ///   · an iOS app has a jetsam ceiling instead — a few hundred MB, enforced by
    ///     termination, with no warning the user can act on and no partial degradation;
    ///   · the expensive step is thumbnail generation, and each in-flight capture holds
    ///     the source bytes AND a decoded bitmap at the same time. A 4000 px share is
    ///     tens of MB of that, and the drain's whole purpose is running a BACKLOG — a
    ///     phone that captured all afternoon — so the worst case is the normal case;
    ///   · this app is also holding a 96 MB thumbnail cache (`ThumbnailCache`) and a live
    ///     grid while the pass runs behind it, which the Mac's four-way drain never
    ///     competes with.
    ///
    /// Halving the width halves the peak of the one allocation that scales with it. Two
    /// rather than one because the drain chunks at exactly this number, and a width of 1
    /// would give a fifty-share backlog strictly serial decoding — all of the batch
    /// machinery and none of the parallelism, which is the shape `InboxDrain`'s header
    /// rejects in the other direction.
    static let maxConcurrent = 2

    // MARK: - Composition

    /// The drain for this phone's inbox, over the library `services` already has open.
    ///
    /// `services` is passed in rather than opened here **because there is one database
    /// pool in this process** and ``LibraryStore`` owns it: the browse seam reads through
    /// it and the pipeline now writes through it. A second `AppServices` over the same
    /// file would be a second pool, a second migration pass at launch, and two writers on
    /// one SQLite file in one process for no reason.
    static func makeDrain(libraryRoot: URL, services: AppServices) -> InboxDrain {
        let pipeline = IngestPipeline(
            store: MediaStore(root: libraryRoot),
            services: services,
            tiers: thumbnailTiers)
        let coordinator = IngestCoordinator(
            pipeline: pipeline, maxConcurrent: maxConcurrent)
        // `.retainForExport`, stated here the way the Mac states `.discardWhenIngested`
        // (`IngestionModel.activateInboxDrain`). The record moves to `inbox/ingested/`:
        // out of the pending set, so no later pass runs it twice, and still on disk,
        // because `InboxArchive` is what owes it to the Mac.
        return InboxDrain(
            libraryRoot: libraryRoot, coordinator: coordinator,
            retention: .retainForExport)
    }
}
