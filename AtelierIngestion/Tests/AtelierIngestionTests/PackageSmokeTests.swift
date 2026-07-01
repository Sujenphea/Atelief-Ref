import Testing
import AtelierCore
@testable import AtelierIngestion

// Checkpoint 1 smoke test: confirms the package skeleton builds, the test
// harness (Swift Testing) runs, and the AtelierCore path dependency is linked
// and usable. Replaced by real suites in later checkpoints.
@Suite("Package skeleton")
struct PackageSmokeTests {
    @Test("Namespace subsystem is the expected ingestion identifier")
    func subsystemValue() {
        #expect(AtelierIngestion.subsystem == "ingestion")
    }

    @Test("AtelierCore links and its public CanvasPlacement resolves")
    func atelierCoreLinks() {
        #expect(AtelierIngestion.probeCorePlacement() == CanvasPlacement())
    }
}
