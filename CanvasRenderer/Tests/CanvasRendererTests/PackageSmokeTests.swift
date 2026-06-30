import Testing
@testable import CanvasRenderer

// Checkpoint 1 smoke test: confirms the package skeleton builds and the test
// harness (Swift Testing) runs. Replaced by real suites in later checkpoints.
@Suite("Package skeleton")
struct PackageSmokeTests {
    @Test("Spike starts on the Core Animation backend (decision A1)")
    func startsOnCoreAnimation() {
        #expect(CanvasRenderer.backend == .coreAnimation)
    }
}
