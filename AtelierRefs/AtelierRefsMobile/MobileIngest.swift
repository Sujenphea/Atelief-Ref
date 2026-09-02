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
// **Two constants became four** (098 · P2). The pixel-area cap and the timing flag are
// here for the reason the first two are: they are facts about this device, stated at the
// call site with the argument attached, rather than a `#if os(iOS)` inside a package. The
// backup exclusions land here too — the drain is what creates the derived files, so the
// launch that builds it is the launch that should say they are not worth backing up.
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

    /// The largest image this device will decode: **64 megapixels**.
    ///
    /// `Validation` asks only that dimensions be positive, so before 457 added the gate a
    /// PNG whose header claims 65,535 × 65,535 was a 17 GB decode attempt. On a Mac that
    /// is a slow minute and a watching user; here it is jetsam — a termination with no
    /// warning, no partial degradation and nothing the person holding the phone can do —
    /// and, with the drain re-running the record at every launch, a phone that dies on
    /// startup until the capture is out of the way. Finding 1a's write-ahead stamp bounds
    /// that loop at three; this stops it happening at all.
    ///
    /// **Why 64, and not the number that would fit in RAM.** The cap has to clear every
    /// image a person legitimately shares from this device, and the largest of those is
    /// what the phone's own camera makes: 48 MP (8064 × 6048) on the current sensors, plus
    /// headroom for a stitched panorama. 64 MP clears both and is a factor of ~67 below
    /// the gigapixel headers a hostile page can serve, which is the range the gate exists
    /// for. It is deliberately NOT derived from a memory budget: the peak this process
    /// actually reaches is a function of ``maxConcurrent`` as well, ImageIO subsamples
    /// when it makes a thumbnail rather than materialising the full bitmap, and a cap
    /// tuned to a bitmap size would refuse the user's own photographs to buy a bound the
    /// width already provides. Two numbers, two arguments.
    ///
    /// The refusal is `IngestError.pixelAreaExceeded`, raised after the header read and
    /// before the blob write, so an over-large share costs a hash and a header read and
    /// leaves nothing on disk. The Mac passes nil and is unaffected.
    static let maximumPixelArea = 64_000_000

    /// The launch argument that turns the pipeline's phase timing into log lines.
    ///
    /// Off by default and read once, in the style `TileBodyLog` established two files
    /// over (`MasonryGridView.swift`): the sink is nil unless it is on, so an ordinary
    /// run pays the handful of clock reads the pipeline takes anyway and nothing else.
    ///
    /// It exists for one unanswered question. ``maxConcurrent`` is 2 on an argument and
    /// not a measurement (098 · finding 3), and the measurement is a drain of a seeded
    /// backlog on a device — `-seed-fixture-library -seed-pending-captures 50` with this
    /// flag on, width 2 against 4. Every ingest logs, not only a slow one: the Mac's sink
    /// reports thumbnail STALLS because it is watching for a regression in a running app,
    /// and this is watching a batch that is supposed to be slow.
    static let ingestTimingArgument = "-atelier-log-ingest-timing"

    static var logsIngestTiming: Bool {
        CommandLine.arguments.contains(ingestTimingArgument)
    }

    /// One line per ingest: what it cost, and whether it did any thumbnail work at all.
    ///
    /// `nonisolated` static, with no captured state, so it is safe to hand to the
    /// off-main pipeline — the same shape the Mac's `logIngestTiming` has.
    nonisolated private static func logIngestTiming(_ timing: IngestTiming) {
        let total = Int(timing.totalMillis)
        let thumbnails = Int(timing.thumbnailMillis)
        let tiers = timing.tiersGenerated
        let deduped = timing.blobExisted
        MobileLog.capture.notice(
            """
            ingest timing: \(total)ms total, \(thumbnails)ms thumbnails, \
            \(tiers) tiers, blob existed \(deduped)
            """)
    }

    // MARK: - Composition

    /// The drain for this phone's inbox, over the library `services` already has open.
    ///
    /// `services` is passed in rather than opened here **because there is one database
    /// pool in this process** and ``LibraryStore`` owns it: the browse seam reads through
    /// it and the pipeline now writes through it. A second `AppServices` over the same
    /// file would be a second pool, a second migration pass at launch, and two writers on
    /// one SQLite file in one process for no reason.
    static func makeDrain(libraryRoot: URL, services: AppServices) -> InboxDrain {
        let store = MediaStore(root: libraryRoot)

        // Backup hygiene (008 · H2), which the phone had never done although it is the
        // platform where it costs the user something: `thumbnails/` and `cache/` are
        // regenerable from the blobs, and `Caches/Exports/` is a second copy of bytes the
        // inbox still holds, so none of the three belongs in an iCloud backup of a device
        // whose backup quota is 5 GB by default. Idempotent and cheap; run every launch,
        // exactly as `IngestionModel` runs it on the Mac.
        store.excludeDerivedFromBackup()
        MediaStore.excludeFromBackup(CaptureExport.exportsDirectory)

        // Spelled as a typed local rather than a ternary in the argument list: the
        // parameter is an optional `@Sendable` closure, and the inference for one of
        // those built inline is what a reader has to reconstruct.
        let timing: (@Sendable (IngestTiming) -> Void)? =
            logsIngestTiming ? logIngestTiming : nil

        let pipeline = IngestPipeline(
            store: store,
            services: services,
            tiers: thumbnailTiers,
            maximumPixelArea: maximumPixelArea,
            timing: timing)
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
