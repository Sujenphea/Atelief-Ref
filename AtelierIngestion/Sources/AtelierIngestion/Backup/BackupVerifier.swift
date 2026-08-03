// AtelierIngestion — prove the backup is what it says it is (008 · H5d)
//
// The filename IS the hash, so verification is self-describing: re-read
// `blobs/ab/cd/<hash>.<ext>`, hash the bytes back, and compare to the name.
// Nothing extra has to be recorded at backup time and there is no second source
// of truth to drift — which is exactly why this check was worth deferring out of
// H5a rather than approximating with sizes or timestamps.
//
// Why the routine check is SAMPLED, and why a full one is a separate button:
// enumerating a destination is metadata-cheap even when its files are dataless
// (an iCloud Drive folder evicted locally is the case that matters), but READING
// one forces a download. Re-hashing a whole synced backup is therefore a real
// cost in time and bandwidth, paid by the user, and a cost that large may not be
// spent on their behalf without being asked. So: a capped sample by default, an
// explicit action for everything, and both report the bytes they read so the
// price shows up on screen instead of in a bandwidth bill.
//
// The sample is DETERMINISTIC given (tree, limit, seed). A random pick would
// make "the check passed" unreproducible — untestable here, and unanswerable in
// a support conversation — which is the opposite of what a verifier is for. The
// seed is what rotates the sample between runs, so repeated checks drift across
// the tree over time while any single check stays perfectly reproducible.
//
// This type NEVER deletes, moves, or rewrites anything at the destination, and
// that is a deliberate refusal rather than an omission. A file whose bytes
// disagree with its name is still the only copy of something at a destination
// the user restores FROM; pruning it on suspicion would turn a bit-flip into a
// loss, and pruning it wrongly (a transient read error on a network volume
// reads exactly like corruption) would do so for no reason at all. Verification
// reports. Repair is a decision someone makes on purpose.

import AtelierCore
import Foundation

/// Re-hashes blob files at a backup destination and reports what disagrees.
///
/// `struct … Sendable` over pure path math, so it runs off the main actor next
/// to the copier it checks.
public struct BackupVerifier: Sendable {
    private let layout: BackupLayout

    /// - Parameter layout: the destination to check — already namespaced by
    ///   library id, so this is one library's backup, not the whole folder.
    public init(layout: BackupLayout) {
        self.layout = layout
    }

    /// The default cap on a sampled check.
    ///
    /// A count, not a byte budget, because the number has to be legible in a
    /// sentence ("checked 32 of 40,000 files") and because a budget expressed in
    /// bytes would make the sample size depend on which files happened to be
    /// picked — the one property this design spends effort to avoid. The bytes
    /// actually read are reported afterwards, which is where the cost belongs.
    public static let defaultSampleSize = 32

    /// How much of the destination to re-hash.
    ///
    /// One type rather than two code paths: "full" is simply the absence of a
    /// cap, so there is a single implementation and no chance of the exhaustive
    /// check quietly diverging from the sampled one it is supposed to subsume.
    public struct Scope: Sendable, Equatable {
        /// Maximum files to re-hash; `nil` re-hashes every one of them.
        public var limit: Int?
        /// Rotates WHICH files a capped sample picks. Same seed, same tree, same
        /// files — every time.
        public var seed: UInt64

        public init(limit: Int?, seed: UInt64) {
            self.limit = limit
            self.seed = seed
        }

        /// The routine check: capped, and cheap enough to run without ceremony.
        public static func sample(
            limit: Int = defaultSampleSize, seed: UInt64 = 0
        ) -> Scope {
            Scope(limit: limit, seed: seed)
        }

        /// Every blob at the destination — the explicit, separately-priced one.
        public static let full = Scope(limit: nil, seed: 0)
    }

    /// The one thing that stops a check before it can report anything.
    public enum VerifyError: Error, Equatable {
        /// No database at the destination for this library, so there is no
        /// backup here to verify. Distinct from "a backup with problems": the
        /// remedy is to run a backup, not to distrust one.
        case noBackupFound
    }

    // MARK: - Sample selection

    /// The files a capped check re-hashes, chosen deterministically.
    ///
    /// Sorted by hash, then taken at a fixed stride from an offset the seed
    /// picks. Two properties are being bought:
    ///
    /// - **Spread.** Striding across the sorted hashes spreads the sample over
    ///   every shard directory. Taking the first `limit` would re-check the same
    ///   corner of `blobs/00/` forever and never look at the rest — a check that
    ///   passes while the damage sits somewhere it never reads is worse than no
    ///   check, because it is believed.
    /// - **Rotation without randomness.** The seed moves the starting offset
    ///   across the whole tree, so successive runs walk different files while
    ///   any single (tree, limit, seed) is exactly reproducible.
    ///
    /// A tree at or under `limit` is returned whole (sorted), so a small backup
    /// is simply verified completely.
    public static func sample(_ files: [BlobFile], limit: Int, seed: UInt64) -> [BlobFile] {
        guard limit > 0 else { return [] }
        let sorted = files.sorted { $0.hash < $1.hash }
        guard sorted.count > limit else { return sorted }

        let stride = sorted.count / limit           // ≥ 1, since count > limit
        // The offset ranges over the WHOLE tree, not over one stride. A tree
        // only a little larger than the limit collapses the stride to 1, and an
        // offset taken modulo the stride would then be 0 for every seed — the
        // same files re-checked forever, on exactly the destinations small
        // enough for rotating to be cheap. Taking it modulo the COUNT rotates in
        // every case, and the picks stay distinct because `stride * limit <=
        // count` means the walk spans less than one full lap of the tree.
        let offset = Int(seed % UInt64(sorted.count))
        var picked: [BlobFile] = []
        picked.reserveCapacity(limit)
        for step in 0 ..< limit {
            picked.append(sorted[(offset + step * stride) % sorted.count])
        }
        return picked
    }

    // MARK: - Verifying

    /// Check the destination's database copy, then re-hash `scope`'s share of
    /// its blobs.
    ///
    /// The database check comes first and is not sampled: it is one bounded
    /// `PRAGMA integrity_check` on a read-only connection, it is the artifact a
    /// restore cannot proceed without, and it is the failure a filling disk
    /// actually produces. The blob sample is the part with the download cost.
    ///
    /// Per-file failures never abort the pass — a mismatch and an unreadable
    /// file are both *findings*, and stopping at the first one would hide how
    /// widespread the problem is, which is the only thing that tells a user
    /// whether to distrust one file or the whole destination.
    ///
    /// - Parameter isCancelled: read before the database check and before each
    ///   file. A caller on a detached task does not inherit task cancellation,
    ///   so it passes its own flag (the `CancelFlag` precedent).
    public func verify(
        scope: Scope = .sample(),
        maxConcurrent: Int = 4,
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil
    ) async throws -> BackupVerifyResult {
        guard FileManager.default.fileExists(atPath: layout.database.path) else {
            throw VerifyError.noBackupFound
        }

        var result = BackupVerifyResult()
        guard !isCancelled() else {
            result.cancelled = true
            return result
        }
        result.databaseHealthy =
            (try? AppServices.isHealthy(databaseFileAt: layout.database)) ?? false

        let store = layout.store
        let files = store.enumerateBlobFiles().map {
            BlobFile(hash: $0.hash, fileExtension: $0.fileExtension)
        }
        result.totalFiles = files.count

        let picked = scope.limit.map { Self.sample(files, limit: $0, seed: scope.seed) }
            ?? files.sorted { $0.hash < $1.hash }
        guard !picked.isEmpty else { return result }

        let reporter = ProgressReporter(total: picked.count, onProgress: onProgress)
        let outcomes = await runBounded(picked, maxConcurrent: maxConcurrent) { _, file in
            let outcome: FileOutcome = isCancelled() ? .skipped : Self.check(file, in: store)
            await reporter.report()
            return outcome
        }

        // A `nil` slot is an item `runBounded` never launched (cancelled before
        // its turn); `.skipped` is one that reached the flag. Both mean "not
        // checked", and neither is evidence of anything about that file.
        var skipped = 0
        for (file, outcome) in zip(picked, outcomes) {
            switch outcome ?? .skipped {
            case .matched(let bytes):
                result.checked += 1
                result.bytesRead += bytes
            case .mismatched(let bytes):
                result.checked += 1
                result.bytesRead += bytes
                result.mismatched.append(file.hash)
            case .unreadable:
                result.unreadable.append(file.hash)
            case .skipped:
                skipped += 1
            }
        }
        // Cancellation is reported by what it COST, mirroring the copier: a stop
        // that lands after the last file is already in flight skipped nothing,
        // and that pass really did check everything it was asked to.
        result.cancelled = skipped > 0
        return result
    }

    /// Re-hash one file and compare the digest to its own filename.
    ///
    /// `static` so the concurrent closure captures a `Sendable` store rather
    /// than `self`. Reads through `ContentHasher.hash(contentsOf:)`, which
    /// streams in bounded chunks — a backup holds whole videos, and a verifier
    /// that pulled one into memory to check it would be its own outage.
    private static func check(_ file: BlobFile, in store: MediaStore) -> FileOutcome {
        let url = store.blobURL(hash: file.hash, fileExtension: file.fileExtension)
        guard let digest = try? ContentHasher.hash(contentsOf: url) else {
            // Absent, permission-denied, or a dataless file whose download
            // failed. NOT reported as corruption: the bytes were never seen, and
            // claiming they are wrong on that basis would be a guess with the
            // same weight as a fact.
            return .unreadable
        }
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .map(Int64.init) ?? 0
        return digest == file.hash ? .matched(bytes) : .mismatched(bytes)
    }

    /// What happened to one file.
    private enum FileOutcome: Sendable {
        case matched(Int64)
        case mismatched(Int64)
        case unreadable
        case skipped
    }
}

/// What one verification pass found.
///
/// Counts and hashes only — no `URL`s, no `Error`s — so it crosses actor
/// boundaries and reaches a UI unchanged, exactly like ``BackupCopyResult``.
public struct BackupVerifyResult: Sendable, Equatable {
    /// Blob files the destination holds — the denominator a sample is *of*.
    /// Reported even on a sampled pass, because "32 checked" means nothing
    /// without it.
    public var totalFiles = 0
    /// Files this pass actually re-hashed.
    public var checked = 0
    /// Bytes read to do it — the cost, and the reason the sample is capped.
    public var bytesRead: Int64 = 0
    /// Hashes whose bytes no longer hash to their own filename. This is
    /// corruption at the destination, and the whole reason the check exists.
    public var mismatched: [String] = []
    /// Hashes that could not be read at all — absent, denied, or a dataless
    /// file that wouldn't come down. A different problem with a different
    /// remedy, so deliberately not folded into ``mismatched``.
    public var unreadable: [String] = []
    /// Whether the destination's database copy passed `PRAGMA integrity_check`.
    public var databaseHealthy = false
    /// Whether the pass stopped early at the user's request.
    public var cancelled = false

    public init() {}

    /// Whether everything this pass looked at was exactly what it should be.
    ///
    /// A cancelled pass is never clean — it did not finish looking, and
    /// "verified" is a claim, not an impression.
    public var isClean: Bool {
        !cancelled && databaseHealthy && mismatched.isEmpty && unreadable.isEmpty
    }

    /// Whether the pass looked at every blob the destination holds.
    public var wasExhaustive: Bool { !cancelled && checked == totalFiles }
}
