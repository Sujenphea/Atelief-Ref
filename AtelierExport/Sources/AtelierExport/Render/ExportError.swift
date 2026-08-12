// AtelierExport — typed export errors + per-element skip report (052 · 7A)
//
// Two failure channels, kept distinct on purpose:
//
//   • ``ExportError`` — a HARD failure that aborts the whole render (no pages,
//     a CoreGraphics context that won't create, an encoder that won't finish).
//     Thrown; the app shows it as an error toast.
//   • ``RenderResult/skipped`` — a SOFT, per-element skip (a missing image
//     blob). The render still succeeds for every other element; the app shows a
//     partial-success summary. One bad reference never sinks the export.

import Foundation

/// A hard, render-aborting export failure.
public enum ExportError: Error, Equatable {
    /// The layout produced no pages — an empty selection, or every element
    /// filtered out before layout. Nothing to render. Both folder writers raise
    /// the same error for their own kind of empty — the static site (014 · S3)
    /// for an empty gallery, the originals writer (011 · A2) for an empty file
    /// list: same meaning, nothing to put in the output.
    case noPages
    /// A CoreGraphics bitmap / PDF context could not be created (e.g. a page
    /// size that rounds to zero pixels).
    case contextCreationFailed
    /// The bitmap rendered but could not be encoded to the requested image
    /// format (PNG).
    case imageEncodingFailed
}

/// Why a single element was skipped during rendering. Skips are collected, not
/// thrown (052 · 7A).
public enum SkipReason: Equatable, Sendable {
    /// ``MoodboardImageProvider`` returned `nil` — the blob is missing or
    /// unreadable.
    case missingImage
    /// An image element was reached but no provider was supplied to the render
    /// call (a programmer error surfaced softly rather than crashing).
    case noProvider
}

/// One skipped element, for the partial-success report.
public struct SkippedElement: Equatable, Sendable {
    /// The image id that could not be drawn.
    public var id: String
    /// Why it was skipped.
    public var reason: SkipReason

    public init(id: String, reason: SkipReason) {
        self.id = id
        self.reason = reason
    }
}

/// The outcome of a successful render: the encoded bytes plus any soft skips.
public struct RenderResult: Equatable, Sendable {
    /// The encoded document (PDF) or image (PNG) bytes.
    public var data: Data
    /// Elements that were skipped with a reason (empty on a clean render).
    public var skipped: [SkippedElement]

    public init(data: Data, skipped: [SkippedElement]) {
        self.data = data
        self.skipped = skipped
    }
}
