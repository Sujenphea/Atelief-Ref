// AtelierCore — SpaceCamera round-trip + the setSpaceCamera funnel
// (018 · Cluster C — camera persistence).
//
// Two halves: the pure value (encode → TEXT → decode, and what `resolved` refuses
// to call usable), and the service write that puts it in `space.camera` and reads
// it back through `getSpace`.

import Foundation
import Testing
@testable import AtelierCore

@Suite("SpaceCamera: JSON round-trip (018 · C)")
struct SpaceCameraCodecTests {

    @Test("a full camera survives encode → TEXT → decode exactly")
    func roundTripsExactly() throws {
        let camera = SpaceCamera(x: 1234.5, y: -987.25, zoom: 3.75)
        let json = try #require(camera.jsonString())
        let decoded = try #require(SpaceCamera(jsonString: json))
        #expect(decoded == camera)
        let resolved = try #require(decoded.resolved)
        #expect(resolved.x == 1234.5)
        #expect(resolved.y == -987.25)
        #expect(resolved.zoom == 3.75)
    }

    @Test("a nil / malformed / non-JSON string decodes to nil")
    func malformedDecodesToNil() {
        #expect(SpaceCamera(jsonString: nil) == nil)
        #expect(SpaceCamera(jsonString: "") == nil)
        #expect(SpaceCamera(jsonString: "not json at all") == nil)
        #expect(SpaceCamera(jsonString: "{\"x\":") == nil)
        // Right shape, wrong types — still nothing usable.
        #expect(SpaceCamera(jsonString: "{\"x\":\"far\",\"y\":\"left\",\"zoom\":\"in\"}") == nil)
    }

    @Test("unknown keys are ignored, so a blob from a newer build still decodes")
    func toleratesUnknownKeys() throws {
        let decoded = try #require(
            SpaceCamera(jsonString: "{\"x\":10,\"y\":20,\"zoom\":1.5,\"home\":{\"x\":0}}"))
        #expect(decoded.resolved.map { [$0.x, $0.y, $0.zoom] } == [10, 20, 1.5])
    }

    @Test("a PARTIAL camera decodes but resolves to nothing")
    func partialResolvesToNil() throws {
        // The value survives (so it round-trips rather than being dropped)…
        let decoded = try #require(SpaceCamera(jsonString: "{\"x\":10,\"y\":20}"))
        #expect(decoded.x == 10)
        #expect(decoded.zoom == nil)
        // …but half a camera is not half a viewport: there is no default for
        // "where were you looking", so the caller re-fits.
        #expect(decoded.resolved == nil)
        #expect(SpaceCamera().resolved == nil)
        #expect(SpaceCamera(x: 1, y: 2).resolved == nil)
    }

    @Test("a non-positive or non-finite zoom resolves to nothing")
    func unusableZoomResolvesToNil() {
        #expect(SpaceCamera(x: 0, y: 0, zoom: 0).resolved == nil)
        #expect(SpaceCamera(x: 0, y: 0, zoom: -2).resolved == nil)
        #expect(SpaceCamera(x: 0, y: 0, zoom: .infinity).resolved == nil)
        #expect(SpaceCamera(x: .nan, y: 0, zoom: 1).resolved == nil)
    }
}

@Suite("AppServices.setSpaceCamera (018 · C)")
struct ServicesSpaceCameraTests {

    private func makeServices() throws -> AppServices {
        try AppServices(databasePath: NSTemporaryDirectory()
            + "space-camera-\(UUID().uuidString).sqlite")
    }

    @Test("a new space starts with no camera (NULL means fit-to-content)")
    func newSpaceHasNoCamera() async throws {
        let services = try makeServices()
        let space = try await services.createSpace(name: "Board")
        #expect(space.camera == nil)
        #expect(try await services.getSpace(id: space.id).camera == nil)
    }

    @Test("a written camera reads back through getSpace")
    func writeThenRead() async throws {
        let services = try makeServices()
        let space = try await services.createSpace(name: "Board")
        let camera = SpaceCamera(x: -300, y: 42.5, zoom: 0.75)

        try await services.setSpaceCamera(spaceID: space.id, camera: camera)

        let reloaded = try await services.getSpace(id: space.id)
        #expect(SpaceCamera(jsonString: reloaded.camera) == camera)
    }

    @Test("writing nil clears the column back to never-opened")
    func nilClears() async throws {
        let services = try makeServices()
        let space = try await services.createSpace(name: "Board")
        try await services.setSpaceCamera(
            spaceID: space.id, camera: SpaceCamera(x: 1, y: 2, zoom: 3))
        try await services.setSpaceCamera(spaceID: space.id, camera: nil)
        #expect(try await services.getSpace(id: space.id).camera == nil)
    }

    @Test("a camera write does NOT bump updatedAt — looking is not editing")
    func doesNotTouchUpdatedAt() async throws {
        let services = try makeServices()
        let space = try await services.createSpace(name: "Board")
        let before = try await services.getSpace(id: space.id).updatedAt

        try await services.setSpaceCamera(
            spaceID: space.id, camera: SpaceCamera(x: 5, y: 5, zoom: 1))

        let after = try await services.getSpace(id: space.id)
        #expect(after.updatedAt == before)
        #expect(after.name == "Board")       // nothing else moved either
        #expect(after.sortIndex == space.sortIndex)
    }

    @Test("a camera for a deleted space is a silent no-op, not .notFound")
    func unknownSpaceIsNoOp() async throws {
        let services = try makeServices()
        let space = try await services.createSpace(name: "Board")
        try await services.deleteSpace(id: space.id)
        // The flush on close can land after the board is gone; that is nothing to
        // raise at the user.
        await #expect(throws: Never.self) {
            try await services.setSpaceCamera(
                spaceID: space.id, camera: SpaceCamera(x: 1, y: 1, zoom: 1))
        }
    }

    @Test("a restored space keeps the camera it was deleted with")
    func recoverableDeletePreservesCamera() async throws {
        let services = try makeServices()
        let space = try await services.createSpace(name: "Board")
        let camera = SpaceCamera(x: 11, y: 22, zoom: 1.25)
        try await services.setSpaceCamera(spaceID: space.id, camera: camera)

        let backup = try await services.deleteSpaceRecoverable(id: space.id)
        try await services.restoreDeletedSpace(backup)

        #expect(SpaceCamera(jsonString: try await services.getSpace(id: space.id).camera)
            == camera)
    }
}
