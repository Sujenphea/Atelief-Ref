import AtelierCore

// Checkpoint 1 skeleton: a placeholder `AtelierIngestion` namespace plus a tiny
// internal helper that builds a value from an AtelierCore PUBLIC type. That
// reference forces the linker to resolve the AtelierCore product, proving the
// path dependency is wired. Real store / utilities / pipeline land later.

/// The ingestion package namespace.
public enum AtelierIngestion {
    /// The subsystem string later used for os.Logger categories.
    public static let subsystem = "ingestion"

    /// Proves the AtelierCore dependency links: constructs a value from an
    /// AtelierCore PUBLIC type (`CanvasPlacement`), so the compiler and linker
    /// must resolve the product. Internal — no public surface yet.
    static func probeCorePlacement() -> CanvasPlacement {
        CanvasPlacement()
    }
}
