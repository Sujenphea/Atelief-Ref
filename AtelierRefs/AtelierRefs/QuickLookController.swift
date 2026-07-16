//
//  QuickLookController.swift
//  AtelierRefs
//
//  011-B3 · 7A — spacebar Quick Look for the grid (and the retrofit for the Space
//  canvas's video peek), on the NATIVE `QLPreviewPanel`. The shared panel gives
//  flip (←/→), spacebar-to-dismiss, zoom, and share for free over an ARRAY of
//  items, so a multi-select preview flips through the whole selection — none of
//  which the old standalone `QLPreviewView`-in-`NSWindow` (`QuickLookPresenter`,
//  now retired) did. Media-less kinds (color / link / tweet) have no on-disk file,
//  so they're skipped by `quickLookPlan(for:leadID:blobURL:)` before the panel
//  ever sees them.
//

import AppKit
import AtelierCore
import Foundation
import Quartz

/// What to show in the Quick Look panel: the previewable file URLs (media-less
/// items already dropped) and the index to open on. A pure value so the mapping
/// is unit-tested without the panel.
struct QuickLookPlan: Equatable {
    var urls: [URL]
    var startIndex: Int

    /// Nothing previewable (an all-media-less selection, or an empty one).
    var isEmpty: Bool { urls.isEmpty }
}

/// The Quick Look set for `details` (feed order): each item's on-disk blob URL,
/// skipping any media-less item that has none (7A). `startIndex` lands on the
/// `leadID` item when it survives into the previewable set, else the first item
/// — so flipping starts where the keyboard cursor / selection lead is.
func quickLookPlan(
    for details: [CollectionItemDetail],
    leadID: UUID?,
    blobURL: (CollectionItemDetail) -> URL?
) -> QuickLookPlan {
    var urls: [URL] = []
    var startIndex = 0
    for detail in details {
        guard let url = blobURL(detail) else { continue }   // media-less → skip
        if detail.item.id == leadID { startIndex = urls.count }
        urls.append(url)
    }
    return QuickLookPlan(urls: urls, startIndex: startIndex)
}

/// Drives the shared `QLPreviewPanel` as its data source. Held by the presenting
/// view; the panel is process-shared, so `dataSource`/`delegate` are (re)claimed
/// on every open so two surfaces (grid, space) never fight over a stale source.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [URL] = []

    /// Show `urls` starting at `startIndex`. No-op on an empty set. Reloads in
    /// place if the panel is already up (a new selection re-previews without a
    /// close/open flicker).
    func present(urls: [URL], startIndex: Int = 0) {
        guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.delegate = self
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.currentPreviewItemIndex = min(max(startIndex, 0), urls.count - 1)
    }

    /// Spacebar behaviour: if OUR preview is up, close it; otherwise open `urls`.
    /// (Once the panel is key, its own spacebar dismiss handles the close — this
    /// covers toggling from the grid before the panel takes focus.)
    func toggle(urls: [URL], startIndex: Int = 0) {
        if let panel = QLPreviewPanel.shared(), panel.isVisible, panel.dataSource === self {
            panel.orderOut(nil)
        } else {
            present(urls: urls, startIndex: startIndex)
        }
    }

    /// Convenience for a single file (the Space canvas's video peek).
    func present(url: URL) { present(urls: [url]) }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
