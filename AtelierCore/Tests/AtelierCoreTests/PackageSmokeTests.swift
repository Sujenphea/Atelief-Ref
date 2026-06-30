import Testing
@testable import AtelierCore

// Checkpoint 1 smoke test: confirms the package skeleton builds, the test
// harness (Swift Testing) runs, and GRDB is linked and usable. Replaced by
// real suites in later checkpoints.
@Suite("Package skeleton")
struct PackageSmokeTests {
    @Test("Database filename is the expected library store")
    func databaseFileName() {
        #expect(AtelierCore.databaseFileName == "library.sqlite")
    }

    @Test("GRDB links and a fresh in-memory database reports user_version 0")
    func grdbLinksAndOpens() throws {
        #expect(try AtelierCore.probeUserVersion() == 0)
    }
}
