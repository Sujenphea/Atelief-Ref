//
//  GridBakeoffSeam.swift
//  AtelierRefs
//
//  037 — THE CONTRACT between the bake-off harness and the three grid
//  implementations it measures (035 §5: is the AppKit `NSCollectionView`
//  rewrite worth 1–2 weeks?).
//
//  Three implementations are built INDEPENDENTLY and in parallel, so the seam
//  is designed for that specifically:
//
//   • One struct per mode, each in ITS OWN FILE, with a name and initializer
//     fixed here in advance. No shared registry, no registration order, no
//     startup side effects — so three authors never touch the same file and a
//     missing entry is a compile error, not a silently empty picker.
//   • The only communication is ``GridBakeoffContext`` in and a
//     ``BakeoffScrollTarget`` out. An implementation cannot reach the harness
//     any other way, so it cannot accidentally special-case the measurement.
//
//  Everything an implementation renders must lay out from the SAME inputs
//  (items, density, spacing, inset) — otherwise the three grids would be
//  measured over different geometry and the numbers would not compare.
//

import AtelierCore
import CoreGraphics
import SwiftUI

/// The grid(s) under comparison (037).
///
///  • ``appKit`` — 035 §5 Option B: `NSCollectionView` with native cell
///    recycling. The expensive fix (1–2 weeks) this bake-off existed to justify
///    or reject, and the one that shipped (Workstreams A/B/C).
///
/// The two SwiftUI modes (`swiftUIWindowed` — the old banded-windowing production
/// path — and `swiftUIEquatable` — 035 §5 Option A) were retired once the AppKit
/// grid became the default; only the AppKit mode remains, as the scroll-perf
/// regression guard (189). The enum keeps its `CaseIterable`/`Codable` shape so
/// the harness, the autorun parser, and the exported provenance are unchanged.
enum GridBakeoffMode: String, CaseIterable, Identifiable, Codable {
    case appKit

    var id: String { rawValue }

    /// Picker/report label.
    var title: String {
        switch self {
        case .appKit: "AppKit · NSCollectionView"
        }
    }
}

/// Which per-cell wrappers a SwiftUI grid attaches (037 §2).
///
/// This axis exists because the naive bake-off is apples-to-oranges and would
/// have unfairly favoured AppKit: the production SwiftUI cell carries
/// `.draggable` (incl. `dragPreview`), `.dropDestination`, `.contextMenu`
/// (incl. `cellMenu`), `.onHover` and `.animation`, and 035 §4 measured exactly
/// those as the dominant residual — while the AppKit spike is specified
/// read-only. Comparing a fully-wrapped SwiftUI cell against a bare AppKit cell
/// measures the WRAPPERS, not the framework, and would "prove" AppKit wins
/// regardless of the truth.
///
/// Running each SwiftUI mode in both configurations exposes a third finding the
/// naive design cannot see: if ``stripped`` ≈ AppKit but ``full`` is far worse,
/// the cost is the eager per-cell wrappers and the fix is deferring them
/// (days), not a framework rewrite (weeks).
enum GridBakeoffWrapperConfig: String, CaseIterable, Identifiable, Codable {
    /// The production wrapper chain — the real-world number today.
    case full
    /// No wrappers — the substrate number, comparable to the AppKit spike.
    case stripped

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Everything a bake-off grid is given, and the one thing it must give back
/// (037).
///
/// A plain value type passed by the harness on every body pass. It carries no
/// model object on purpose: an implementation that could reach `IngestionModel`
/// could load, mutate, or re-sort behind the measurement, and the runs would
/// stop being comparable.
@MainActor
struct GridBakeoffContext {
    /// The items to render, already loaded and in feed order. All three
    /// implementations receive the SAME array — this is the workload.
    let items: [CollectionItemDetail]
    /// The density to lay out at. Call `density.columns(forWidth:)` for the
    /// column count; do NOT invent your own, or your grid lays out different
    /// geometry from the others and the comparison is void.
    let density: GridDensity
    /// Inter-cell gap, points. Matches `CollectionView.gridSpacing`.
    let spacing: CGFloat
    /// Leading top gap, points. Matches `CollectionView.gridTopInset`.
    let topInset: CGFloat
    /// Which per-cell wrappers to attach (037 §2).
    ///
    /// SwiftUI modes MUST honour this — it is the control that keeps the
    /// comparison honest. Under `.full` attach the production
    /// `.draggable`/`.dropDestination`/`.contextMenu`/`.onHover`/`.animation`
    /// chain; under `.stripped` attach NONE of them. The AppKit mode is
    /// read-only by specification and may ignore this.
    let wrappers: GridBakeoffWrapperConfig

    /// The on-disk 512-tier thumbnail URL for an item (`nil` for media-less
    /// kinds) — exactly `IngestionModel.thumbnailURL(for:)`, forwarded as a
    /// closure so the context carries no model object.
    ///
    /// Every implementation MUST render through this. Thumbnail decode is a real
    /// and large part of scroll cost; a grid that drew coloured rectangles
    /// instead would post excellent numbers that mean nothing.
    let thumbnailURL: (CollectionItemDetail) -> URL?
    /// The ORIGINAL blob URL, needed only for the animated-GIF overlay
    /// (`IngestionModel.blobURL(for:)`). Implementations may ignore GIF
    /// animation — but if one supports it, all should, or that one pays a cost
    /// the others do not.
    let blobURL: (CollectionItemDetail) -> URL?

    /// Hand the harness the object it will scroll.
    ///
    /// MUST be called once the scroll target exists and its geometry is known —
    /// in practice from `.onAppear` or a geometry callback, NOT from `init`,
    /// where a SwiftUI view has no size yet. Calling it again REPLACES the
    /// target, so refreshing it on each body pass is fine and is the expected
    /// pattern for SwiftUI entries.
    ///
    /// A mode that never calls this cannot be run: the harness reports "no
    /// scroll target registered" rather than producing a meaningless all-idle
    /// result.
    let registerScrollTarget: (BakeoffScrollTarget) -> Void
}

//
//  ─────────────────────────────────────────────────────────────────────────
//  THE ENTRY POINT
//
//  The surviving mode is one `View` struct with a fixed name and a single stored
//  property `context`. The harness switches over `GridBakeoffMode` and
//  constructs it by this exact signature:
//
//      AppKitBakeoffGrid(context: ctx)              // AppKitBakeoffGrid.swift
//
//  (The two SwiftUI entry points — `SwiftUIWindowedBakeoffGrid` and
//  `SwiftUIEquatableBakeoffGrid` — were retired in 189.)
//  ─────────────────────────────────────────────────────────────────────────
//
