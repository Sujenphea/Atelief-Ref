//
//  GifMotion.swift
//  AtelierRefs
//
//  011-B5 · 8A/15A — motion policy for the grid: GIFs animate in the grid on
//  HOVER ONLY (decode cost), everywhere else a static poster/thumbnail. The
//  DECISION is pure and exhaustively tested (`shouldAnimateGif`, `gifWithinBudget`);
//  the machinery around it is deliberately disciplined:
//
//   • dwell-gated — animation only after a short hover so a fast pass doesn't
//     churn decodes (the cell owns the 150 ms dwell timer),
//   • single-animation cap — at most ONE GIF animates at a time
//     (`GifAnimationCoordinator`), so a grid of GIFs never decodes them all,
//   • Reduce-Motion aware — short-circuits BEFORE any decode, and
//   • budgeted — a GIF past a byte budget stays static (a huge multi-MB GIF isn't
//     worth the memory for a hover peek).
//
//  Video hover-preview is explicitly deferred to v1.5 (needs a pooled player).
//

import AppKit
import SwiftUI

enum GifMotion {
    /// The GIF mime type — the only kind that animates in the grid (8A).
    static let gifMimeType = "image/gif"
    /// GIFs larger than this stay static on hover (15A) — a hover peek isn't
    /// worth decoding a huge animation into memory. ~24 MB.
    static let maxAnimatedBytes = 24 * 1024 * 1024
    /// How long the pointer must dwell on a cell before its GIF animates (15A).
    static let hoverDwell: Duration = .milliseconds(150)
}

/// Whether a cell's GIF should animate right now (011-B5 · 8A). True only for an
/// actual GIF, while hovered, with Reduce Motion OFF — the Reduce-Motion / not-a-
/// GIF cases short-circuit here, before any decode is attempted (15A).
func shouldAnimateGif(mimeType: String?, reduceMotion: Bool, isHovering: Bool) -> Bool {
    !reduceMotion && isHovering && mimeType == GifMotion.gifMimeType
}

/// Whether a GIF of `fileSize` bytes is within the animation budget (011-B5 · 15A).
/// An unknown size is allowed (best effort — byte-backed GIFs carry a size, so
/// this is only the defensive path); over the cap it stays static.
func gifWithinBudget(fileSize: Int?, maxBytes: Int = GifMotion.maxAnimatedBytes) -> Bool {
    guard let fileSize else { return true }
    return fileSize <= maxBytes
}

/// Enforces the single-animation cap across the whole grid (011-B5 · 15A). One
/// cell holds the slot at a time; a plain (unobserved) main-actor class so
/// claiming/releasing never re-renders any cell.
@MainActor
final class GifAnimationCoordinator {
    static let shared = GifAnimationCoordinator()
    private var current: UUID?

    /// Grant the slot to `id` if it's free (or already `id`'s); false if another
    /// cell holds it.
    func claim(_ id: UUID) -> Bool {
        if current == nil || current == id { current = id; return true }
        return false
    }

    /// Release the slot iff `id` holds it (a stale release from another cell is a
    /// no-op).
    func release(_ id: UUID) {
        if current == id { current = nil }
    }
}

/// Plays an animated GIF from its ORIGINAL blob (the static thumbnail tiers are
/// flattened posters, so they can't animate). An `NSImageView` animates a
/// multi-frame `NSImage` itself — no frame pump needed. Data is read off-main so
/// the hover never blocks the render path; frames release when the view is torn
/// down (hover-out removes it from the tree).
struct AnimatedGifView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let view = BoundedImageView()
        // Fill the cell's aspect frame and CLIP to it — the cell aspect is the
        // GIF's own aspect, so a proportional fill crops nothing (a clamped
        // extreme aspect letterboxes slightly rather than overflowing).
        view.imageScaling = .scaleProportionallyUpOrDown
        view.animates = true
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        load(into: view)
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if context.coordinator.loadedURL != url {
            load(into: nsView)
            context.coordinator.loadedURL = url
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(loadedURL: url) }

    final class Coordinator {
        var loadedURL: URL
        init(loadedURL: URL) { self.loadedURL = loadedURL }
    }

    private func load(into view: NSImageView) {
        let url = self.url
        Task { @MainActor in
            let data = await Task.detached(priority: .userInitiated) {
                try? Data(contentsOf: url)
            }.value
            guard let data, let image = NSImage(data: data) else { return }
            view.image = image
            view.animates = true
        }
    }

    /// An `NSImageView` that reports NO intrinsic size and clips to its bounds, so
    /// SwiftUI sizes it to the ambient cell frame instead of the GIF's pixel size
    /// — otherwise a large GIF's intrinsic size makes the hosted view spill past
    /// the cell before any SwiftUI clip runs.
    private final class BoundedImageView: NSImageView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }
}
