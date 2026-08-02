//
//  SpaceCameraPersistTests.swift
//  AtelierRefsTests
//
//  018 · Cluster C — the model half of camera persistence, over a real (temp)
//  `AppServices`: the 0.4s debounce that turns a whole gesture into ONE write, the
//  explicit flush that stops the LAST gesture of a session being the one that is
//  lost, and the read side that turns a stored blob into an opening camera.
//
//  The delay is injected rather than slept through (the `SnapshotManager(now:)`
//  pattern applied to a duration): a test that has to wait 0.4s to prove a debounce
//  coalesced is a test that fails on a loaded machine.
//

import AtelierCore
import AtelierIngestion
import CanvasRenderer
import CoreGraphics
import Foundation
import Testing
@testable import AtelierRefs

@MainActor
@Suite("SpaceModel camera persistence (018 · C)")
struct SpaceCameraPersistTests {

    /// A model whose debounce timer will not fire during the test, so the
    /// coalescing can be observed without racing a clock.
    private func makeModel(
        cameraFlushDelay: Duration = .seconds(600)
    ) async throws -> (model: SpaceModel, services: AppServices, spaceID: UUID) {
        let dbPath = NSTemporaryDirectory() + "space-camera-\(UUID().uuidString).sqlite"
        let services = try AppServices(databasePath: dbPath)
        let store = MediaStore(root: FileManager.default.temporaryDirectory)
        let space = try await services.createSpace(name: "Camera Board")
        let model = SpaceModel(
            spaceID: space.id, services: services, store: store,
            cameraFlushDelay: cameraFlushDelay)
        await model.load()   // deterministic initial state (init's load Task is async)
        return (model, services, space.id)
    }

    private func storedCamera(_ services: AppServices, _ id: UUID) async throws -> SpaceCamera? {
        SpaceCamera(jsonString: try await services.getSpace(id: id).camera)
    }

    // MARK: - Debounce

    @Test("N rapid camera changes coalesce into ONE write")
    func coalescesAGesture() async throws {
        let (model, services, spaceID) = try await makeModel()

        // A pan delivers one of these per frame; a gesture is dozens.
        for step in 1...40 {
            model.cameraChanged(
                CanvasCamera(centre: CGPoint(x: step * 10, y: step * 5), zoom: 1.5))
        }
        #expect(model.cameraWriteCount == 0)    // nothing written mid-gesture

        model.flushCameraPersist()
        await model.waitForWrites()

        #expect(model.cameraWriteCount == 1)    // …and exactly one at the end
        // The write carries the LAST frame of the gesture, not the first.
        #expect(try await storedCamera(services, spaceID)
            == SpaceCamera(x: 400, y: 200, zoom: 1.5))
    }

    @Test("two separate gestures are two writes")
    func separateGesturesEachWrite() async throws {
        let (model, services, spaceID) = try await makeModel()

        model.cameraChanged(CanvasCamera(centre: CGPoint(x: 10, y: 10), zoom: 1))
        model.cameraChanged(CanvasCamera(centre: CGPoint(x: 20, y: 20), zoom: 1))
        model.flushCameraPersist()
        model.cameraChanged(CanvasCamera(centre: CGPoint(x: 90, y: 90), zoom: 4))
        model.flushCameraPersist()
        await model.waitForWrites()

        #expect(model.cameraWriteCount == 2)
        #expect(try await storedCamera(services, spaceID) == SpaceCamera(x: 90, y: 90, zoom: 4))
    }

    @Test("the debounce timer writes on its own when nothing flushes it")
    func timerFires() async throws {
        // The one place a real duration is used — a short one, and the assertion
        // polls rather than sleeping a fixed amount.
        let (model, services, spaceID) = try await makeModel(cameraFlushDelay: .milliseconds(20))

        model.cameraChanged(CanvasCamera(centre: CGPoint(x: 7, y: 8), zoom: 2))

        for _ in 0..<200 where model.cameraWriteCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await model.waitForWrites()

        #expect(model.cameraWriteCount == 1)
        #expect(try await storedCamera(services, spaceID) == SpaceCamera(x: 7, y: 8, zoom: 2))
    }

    // MARK: - Flush (the regression that matters)

    @Test("flush-on-close persists the FINAL camera of the session")
    func flushOnClosePersists() async throws {
        let (model, services, spaceID) = try await makeModel()

        // The user's last act before closing the board.
        model.cameraChanged(CanvasCamera(centre: CGPoint(x: -640, y: 480), zoom: 0.25))
        // Without the flush the pending value dies with the view and the pan is lost.
        #expect(try await storedCamera(services, spaceID) == nil)

        model.flushCameraPersist()      // what `SpaceView.onDisappear` calls
        await model.waitForWrites()

        #expect(try await storedCamera(services, spaceID)
            == SpaceCamera(x: -640, y: 480, zoom: 0.25))
    }

    @Test("flushing with nothing pending writes nothing")
    func flushIsANoOpWhenIdle() async throws {
        let (model, services, spaceID) = try await makeModel()

        model.flushCameraPersist()
        model.flushCameraPersist()
        await model.waitForWrites()

        #expect(model.cameraWriteCount == 0)
        #expect(try await storedCamera(services, spaceID) == nil)
    }

    @Test("re-reporting the camera already on disk does not write it again")
    func echoOfTheRestoreIsNotAWrite() async throws {
        let (model, services, spaceID) = try await makeModel()
        let camera = CanvasCamera(centre: CGPoint(x: 33, y: 44), zoom: 1.75)
        model.cameraChanged(camera)
        model.flushCameraPersist()
        await model.waitForWrites()
        #expect(model.cameraWriteCount == 1)

        // A restore sets the transform to exactly the saved value, which arrives back
        // through the same seam. That must not put a write on every board open.
        model.cameraChanged(camera)
        model.flushCameraPersist()
        await model.waitForWrites()

        #expect(model.cameraWriteCount == 1)
        #expect(try await storedCamera(services, spaceID) == SpaceCamera(x: 33, y: 44, zoom: 1.75))
    }

    // MARK: - Read side

    @Test("a board with no saved camera opens with nil — i.e. fit to content")
    func nilOpeningCamera() async throws {
        let (model, _, _) = try await makeModel()
        #expect(model.openingCamera == nil)
    }

    @Test("a saved camera comes back as the opening camera")
    func savedCameraOpens() async throws {
        let (model, services, spaceID) = try await makeModel()
        try await services.setSpaceCamera(
            spaceID: spaceID, camera: SpaceCamera(x: 250, y: -125, zoom: 2.5))
        await model.load()

        let opening = try #require(model.openingCamera)
        #expect(opening.centre == CGPoint(x: 250, y: -125))
        #expect(opening.zoom == 2.5)
    }

    @Test("NULL and undecodable both open as nil — the same one fallback")
    func nullAndUndecodableShareTheFallback() {
        // NULL — never opened.
        #expect(SpaceModel.openingCamera(from: nil) == nil)
        // Undecodable — a corrupted, truncated or hand-edited blob.
        #expect(SpaceModel.openingCamera(from: "not json") == nil)
        #expect(SpaceModel.openingCamera(from: "{\"x\":1,") == nil)
        // Decodable but unusable — half a camera, or a zoom that isn't one.
        #expect(SpaceModel.openingCamera(from: "{\"x\":1,\"y\":2}") == nil)
        #expect(SpaceModel.openingCamera(from: "{\"x\":1,\"y\":2,\"zoom\":0}") == nil)
        // …and the one shape that IS usable, so the guard isn't just refusing
        // everything.
        #expect(SpaceModel.openingCamera(from: "{\"x\":1,\"y\":2,\"zoom\":3}")
            == CanvasCamera(centre: CGPoint(x: 1, y: 2), zoom: 3))
    }
}
