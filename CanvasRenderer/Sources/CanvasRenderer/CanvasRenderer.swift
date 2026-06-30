// CanvasRenderer
//
// Phase 1 canvas rendering spike for ref-atelier. This file is intentionally a
// placeholder for the package skeleton (Checkpoint 1); the real types land in
// Checkpoint 2 (pure logic) and Checkpoint 4 (the Core Animation host).
//
// Build-order context lives in `.docs/004-foundation-plan.md` and the approved
// plan at `.claude/plans/look-into-docs-i-glittery-wren.md`.

/// Marker for the package version of the spike. Replaced by real surface area
/// as the checkpoints land.
public enum CanvasRenderer {
    /// Identifies the rendering backend the spike is validating.
    ///
    /// The spike starts on ``core Animation`` (decision A1); the benchmark
    /// (Checkpoint 6) decides whether that backend clears the performance bar or
    /// whether we escalate to ``metal``.
    public enum Backend: String, Sendable {
        case coreAnimation
        case metal
    }

    /// The backend this build renders with.
    public static let backend: Backend = .coreAnimation
}
