//
//  LibraryStatsCopy.swift
//  AtelierRefs
//
//  016 · A — the words the Library section says, and none of the layout. Same
//  split `BackupTarget` (008 H4) draws: facts and phrasing in a testable,
//  AppKit-free enum, arrangement in the view. A sentence that has to be read to
//  be checked is a sentence nobody checks.
//
//  Every function here is pure and total over its input, which is what lets the
//  unit tests assert the number in the sentence rather than merely that a
//  sentence appeared.
//

import AtelierCore
import AtelierIngestion
import Foundation

enum LibraryStatsCopy {

    // MARK: - Sizes

    /// Human byte size, the same `.file` style the snapshots list and the
    /// diagnostics report use — one library, one way of saying "2.4 MB".
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The Archived row's value (023 · A4). Two facts in one line because they
    /// answer different halves of the same question, and either alone misleads:
    /// a count with no size says nothing about reclaiming, and a size with no
    /// count hides a shelf of a thousand weightless swatches.
    ///
    /// The size is what deleting the shelf would ACTUALLY free — blobs a visible
    /// item still shares are excluded — so the row can be read as an offer.
    /// Zero bytes is spelled out rather than hidden: "12 items · nothing to
    /// reclaim" is a real and useful answer, and a bare "12 items" would leave
    /// the reader to guess.
    static func archived(_ usage: ArchivedUsage) -> String {
        guard usage.exclusiveBytes > 0 else {
            return "\(items(usage.assetCount)) · nothing to reclaim"
        }
        return "\(items(usage.assetCount)) · \(size(Int64(usage.exclusiveBytes))) reclaimable"
    }

    /// The row label for a storage tier.
    static func tier(_ tier: LibraryStorageTier) -> String {
        switch tier {
        case .blobs: "Originals"
        case .thumbnails: "Thumbnails"
        case .cache: "Cache"
        case .snapshots: "Snapshots"
        }
    }

    /// The caption under the size breakdown. Names the regenerable figure
    /// explicitly — that number is the whole reason the tiers are measured
    /// apart rather than summed (008 H2 already keeps it out of Time Machine,
    /// and until now nothing said how much that was worth).
    static func storageExplainer(_ usage: LibraryStorageUsage) -> String {
        "Originals and the database are the bytes that only exist here. "
            + "\(size(usage.regenerableBytes)) of thumbnails and cache is "
            + "regenerable — it's already excluded from Time Machine, and "
            + "rebuilt on demand."
    }

    // MARK: - Counts

    /// A human label for an asset kind, pluralised for a count row.
    static func kind(_ kind: AssetKind) -> String {
        switch kind {
        case .image: "Images"
        case .video: "Videos"
        case .tweet: "Tweets"
        case .link: "Links"
        case .color: "Colors"
        }
    }

    /// A human label for a capture platform. Matches the detail sidebar's
    /// wording so one item isn't "Twitter / X" in one place and "Twitter" here.
    static func platform(_ platform: Platform) -> String {
        switch platform {
        case .twitter: "Twitter / X"
        case .pinterest: "Pinterest"
        case .instagram: "Instagram"
        case .cosmos: "Cosmos"
        case .rednote: "rednote"
        case .web: "Web"
        case .clipboard: "Clipboard"
        case .localPaste: "Pasted"
        case .localDrag: "Dragged in"
        }
    }

    /// `"1 item"` / `"12 items"` — the count phrase, pluralised.
    static func items(_ count: Int) -> String {
        "\(count) item\(count == 1 ? "" : "s")"
    }

    // MARK: - Largest items

    /// A row's title: the item's name, else its source title, else the kind.
    /// Never empty — a blank row is unclickable and unexplainable.
    static func title(for item: LargestItem) -> String {
        if let name = item.usage.displayName, !name.isEmpty { return name }
        return kind(item.usage.kind)
    }

    /// A row's subtitle: size, platform, and — only when it matters — how many
    /// assets share the file. The share count is the difference between "delete
    /// this to free 240 MB" and "delete this and free nothing".
    static func subtitle(for item: LargestItem) -> String {
        var parts = [size(item.byteSize), platform(item.usage.platform)]
        if item.usage.assetCount > 1 {
            parts.append("shared by \(items(item.usage.assetCount))")
        }
        return parts.joined(separator: " · ")
    }

    /// The confirmation body for deleting a largest-items row. States the
    /// consequence in bytes, and — when the blob is shared — that every
    /// referencing item goes, because reclaiming the FILE is the point.
    static func deleteConfirmation(for item: LargestItem) -> String {
        let freed = size(item.byteSize)
        if item.usage.assetCount > 1 {
            return "\(items(item.usage.assetCount)) share this file. All of them are "
                + "removed from the library, freeing \(freed). You can undo this "
                + "with ⌘Z; the media stays in the Trash until you empty it."
        }
        return "This item is removed from the library, freeing \(freed). You can "
            + "undo this with ⌘Z; the media stays in the Trash until you empty it."
    }

    // MARK: - Staleness

    /// "Measured just now" / "Measured 12 minutes ago" — how much to trust the
    /// figures above. A clock adjustment can put `scannedAt` in the future;
    /// clamp rather than say "measured in 3 hours" (008 H5's lesson).
    /// - Parameter isStale: whether the library changed after the measurement.
    ///   When it did, the line says so — figures presented as current when they
    ///   are known not to be is the failure this whole section exists to end.
    static func measured(at date: Date, isStale: Bool = false, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        let when: String
        if elapsed < 60 {
            when = "Measured just now"
        } else {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            when = "Measured \(formatter.localizedString(for: date, relativeTo: now))"
        }
        return isStale
            ? "\(when) — the library has changed since. Measure again for current figures."
            : "\(when)."
    }
}
