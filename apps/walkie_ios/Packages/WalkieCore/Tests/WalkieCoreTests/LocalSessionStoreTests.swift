import Foundation
import XCTest
@testable import WalkieCore

final class LocalSessionStoreTests: XCTestCase, @unchecked Sendable {
    private enum InjectedFailure: Error { case afterWrite }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WalkieStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func append(_ store: LocalSessionStore, sessionID: UUID, offset: Double = 1) async throws {
        try await store.appendLocation(sessionID: sessionID, coordinate: Coordinate(latitude: 55.75, longitude: 37.61),
                                       horizontalAccuracy: 12, observedAt: start.addingTimeInterval(offset),
                                       receivedAt: start.addingTimeInterval(offset + 0.1), monotonicTime: 100 + offset)
    }

    func testCreateReadAppendPauseResumeAndFinish() async throws {
        let directory = try temporaryDirectory()
        let store = LocalSessionStore(root: directory)
        let created = try await store.create(route: .demo, at: start)
        XCTAssertEqual(created.state, .recording)
        XCTAssertEqual(created.completionLabel, "unknown")
        try await append(store, sessionID: created.id)
        let activeList = try await store.list()
        XCTAssertEqual(activeList.first?.state, .recording, "Listing the active store is not a crash recovery.")
        XCTAssertEqual(activeList.first?.observationCount, 1)
        let paused = try await store.setState(sessionID: created.id, state: .paused, at: start.addingTimeInterval(2))
        XCTAssertEqual(paused.state, .paused)
        do {
            try await append(store, sessionID: created.id, offset: 3)
            XCTFail("Paused sessions must not accept samples.")
        } catch SessionStorageError.notRecording { }
        let resumed = try await store.setState(sessionID: created.id, state: .recording, at: start.addingTimeInterval(4))
        XCTAssertNil(resumed.endedAt)
        try await append(store, sessionID: created.id, offset: 5)
        let finished = try await store.setState(sessionID: created.id, state: .finished, at: start.addingTimeInterval(6))
        XCTAssertEqual(finished.observationCount, 2)
        XCTAssertEqual(finished.completionLabel, "unknown", "Stop is not evidence of route completion.")
        XCTAssertEqual(finished.endedAt, start.addingTimeInterval(6))
        let read = try await store.read(sessionID: created.id)
        XCTAssertEqual(read, finished)
        do {
            _ = try await store.setState(sessionID: created.id, state: .recording, at: start.addingTimeInterval(7))
            XCTFail("A closed recording cannot be resumed.")
        } catch SessionStorageError.invalidTransition { }
    }

    func testManualVisitIsExplicitIdempotentAndValidated() async throws {
        let store = LocalSessionStore(root: try temporaryDirectory())
        let created = try await store.create(route: .demo, at: start)
        let poiID = try XCTUnwrap(created.route.pois.first?.id)
        _ = try await store.markVisited(sessionID: created.id, poiID: poiID, at: start.addingTimeInterval(1))
        let twice = try await store.markVisited(sessionID: created.id, poiID: poiID, at: start.addingTimeInterval(2))
        XCTAssertEqual(twice.manualVisitedPOIIDs, [poiID])
        XCTAssertEqual(twice.completionLabel, "unknown")
        do {
            _ = try await store.markVisited(sessionID: created.id, poiID: "missing", at: start)
            XCTFail("Only POIs belonging to this immutable route snapshot are valid.")
        } catch SessionStorageError.unknownPOI { }
    }

    func testFreshStoreInterruptsUnclosedSessionWithoutInventingWalkTime() async throws {
        let root = try temporaryDirectory()
        let first = LocalSessionStore(root: root)
        let created = try await first.create(route: .demo, at: start)
        try await append(first, sessionID: created.id)
        _ = try await first.setState(sessionID: created.id, state: .paused, at: start.addingTimeInterval(2))
        let recovered = LocalSessionStore(root: root)
        let sessions = try await recovered.list()
        let interrupted = try XCTUnwrap(sessions.first)
        XCTAssertEqual(interrupted.state, .interrupted)
        XCTAssertEqual(interrupted.endedAt, start.addingTimeInterval(2))
        XCTAssertEqual(interrupted.observationCount, 1)
        XCTAssertEqual(interrupted.completionLabel, "unknown")
        let third = LocalSessionStore(root: root)
        let reopened = try await third.read(sessionID: created.id)
        XCTAssertEqual(reopened, interrupted, "A second launch does not extend an interrupted walk.")
    }

    func testExportRequiresClosedSessionAndMakesIndependentSnapshot() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("internal")
        let exports = directory.appendingPathComponent("exports")
        let store = LocalSessionStore(root: root)
        let created = try await store.create(route: .demo, at: start)
        do {
            _ = try await store.export(sessionID: created.id, to: exports)
            XCTFail("Active recordings cannot be exported.")
        } catch SessionStorageError.exportRequiresClosedSession { }
        try await append(store, sessionID: created.id)
        _ = try await store.setState(sessionID: created.id, state: .finished, at: start.addingTimeInterval(2))
        let files = try await store.export(sessionID: created.id, to: exports)
        let again = try await store.export(sessionID: created.id, to: exports)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(["session.json", "events.jsonl", "locations.jsonl"]))
        XCTAssertNotEqual(files.first?.deletingLastPathComponent(), again.first?.deletingLastPathComponent())
        for file in files {
            let source = root.appendingPathComponent(created.id.uuidString).appendingPathComponent(file.lastPathComponent)
            XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: source))
        }
        do {
            _ = try await store.export(sessionID: created.id, to: root.appendingPathComponent("exports"))
            XCTFail("Do not mix exports into the app's backing store.")
        } catch SessionStorageError.exportInsideStorage { }
    }

    func testInvalidSamplesDoNotEnterJournal() async throws {
        let store = LocalSessionStore(root: try temporaryDirectory())
        let created = try await store.create(route: .demo, at: start)
        do {
            try await store.appendLocation(sessionID: created.id, coordinate: Coordinate(latitude: .nan, longitude: 37),
                                           horizontalAccuracy: 2, observedAt: start, receivedAt: start, monotonicTime: 1)
            XCTFail("NaN must be rejected before encoding.")
        } catch SessionStorageError.invalidCoordinate { }
        do {
            try await store.appendLocation(sessionID: created.id, coordinate: Coordinate(latitude: 55, longitude: 37),
                                           horizontalAccuracy: -1, observedAt: start, receivedAt: start, monotonicTime: 1)
            XCTFail("Core Location's invalid accuracy must not be treated as an accurate sample.")
        } catch SessionStorageError.invalidAccuracy { }
        let record = try await store.read(sessionID: created.id)
        XCTAssertEqual(record.observationCount, 0)
    }

    func testTornTrailingLineRecoveryPreservesValidSamplesAndSequence() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("internal")
        let store = LocalSessionStore(root: root)
        let created = try await store.create(route: .demo, at: start)
        try await append(store, sessionID: created.id)
        let locations = root.appendingPathComponent(created.id.uuidString).appendingPathComponent("locations.jsonl")
        let validData = try Data(contentsOf: locations)
        let handle = try FileHandle(forWritingTo: locations)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"metadata\":".utf8))
        try handle.close()
        let recovery = LocalSessionStore(root: root)
        let record = try await recovery.read(sessionID: created.id)
        XCTAssertEqual(record.observationCount, 1)
        XCTAssertEqual(record.state, .interrupted)
        XCTAssertEqual(try Data(contentsOf: locations), validData)
        let diagnostics = try FileManager.default.contentsOfDirectory(
            at: locations.deletingLastPathComponent().appendingPathComponent("recovery_diagnostics"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(diagnostics.first)), Data("{\"metadata\":".utf8),
                       "Recovery must preserve the exact torn bytes before trimming the active journal.")
        let files = try await recovery.export(sessionID: created.id, to: directory.appendingPathComponent("exports"))
        let events = try XCTUnwrap(files.first(where: { $0.lastPathComponent == "events.jsonl" }))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let entries = try Data(contentsOf: events).split(separator: 0x0A).map { try decoder.decode(SessionEvent.self, from: Data($0)) }
        XCTAssertEqual(entries.map(\.metadata.sequence), [1, 3])
        XCTAssertTrue(entries.last?.reason?.contains("preservedPartialBytes=12") == true)
        XCTAssertNotEqual(entries.first?.metadata.segmentID, entries.last?.metadata.segmentID)
    }

    func testCompleteMalformedLineFailsVisibly() async throws {
        let root = try temporaryDirectory()
        let store = LocalSessionStore(root: root)
        let created = try await store.create(route: .demo, at: start)
        let locations = root.appendingPathComponent(created.id.uuidString).appendingPathComponent("locations.jsonl")
        try Data("not-json\n".utf8).write(to: locations)
        let recovery = LocalSessionStore(root: root)
        do {
            _ = try await recovery.list()
            XCTFail("Complete corrupted records must not disappear silently.")
        } catch SessionStorageError.corruptData { }
    }

    func testJournalReplaysObservationAndVisitAfterStaleManifest() async throws {
        let root = try temporaryDirectory()
        let store = LocalSessionStore(root: root)
        let created = try await store.create(route: .demo, at: start)
        let manifest = root.appendingPathComponent(created.id.uuidString).appendingPathComponent("session.json")
        let oldManifest = try Data(contentsOf: manifest)
        try await append(store, sessionID: created.id)
        let poiID = try XCTUnwrap(created.route.pois.first?.id)
        _ = try await store.markVisited(sessionID: created.id, poiID: poiID, at: start.addingTimeInterval(2))
        // Simulate a crash after a durable journal append but before manifest replacement.
        try oldManifest.write(to: manifest, options: .atomic)
        let recovery = LocalSessionStore(root: root)
        let record = try await recovery.read(sessionID: created.id)
        XCTAssertEqual(record.observationCount, 1)
        XCTAssertEqual(record.manualVisitedPOIIDs, [poiID])
        XCTAssertEqual(record.state, .interrupted)
    }

    func testActorSerializesConcurrentAppends() async throws {
        let root = try temporaryDirectory()
        let store = LocalSessionStore(root: root)
        let created = try await store.create(route: .demo, at: start)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for offset in 1...25 {
                group.addTask { try await self.append(store, sessionID: created.id, offset: Double(offset)) }
            }
            try await group.waitForAll()
        }
        let record = try await store.read(sessionID: created.id)
        XCTAssertEqual(record.observationCount, 25)
        _ = try await store.setState(sessionID: created.id, state: .finished, at: start.addingTimeInterval(30))
        let recovered = LocalSessionStore(root: root)
        let reloaded = try await recovered.read(sessionID: created.id)
        XCTAssertEqual(reloaded.observationCount, 25)
        XCTAssertEqual(reloaded.state, .finished)
    }

    func testUncertainLocationAppendQuarantinesAllOperationsUntilFreshRecovery() async throws {
        let directory = try temporaryDirectory()
        let root = directory.appendingPathComponent("internal")
        let store = LocalSessionStore(root: root, afterJournalWrite: { throw InjectedFailure.afterWrite })
        let created = try await store.create(route: .demo, at: start)
        do {
            try await append(store, sessionID: created.id)
            XCTFail("Injected write/sync failure must be surfaced.")
        } catch InjectedFailure.afterWrite { }
        let sessionDirectory = root.appendingPathComponent(created.id.uuidString)
        let locations = sessionDirectory.appendingPathComponent("locations.jsonl")
        let events = sessionDirectory.appendingPathComponent("events.jsonl")
        let uncertainLocationBytes = try Data(contentsOf: locations)
        let eventsBefore = try Data(contentsOf: events)
        let operations: [() async throws -> Void] = [
            { _ = try await store.read(sessionID: created.id) },
            { _ = try await store.list() },
            { try await self.append(store, sessionID: created.id, offset: 2) },
            { _ = try await store.setState(sessionID: created.id, state: .interrupted, at: self.start) },
            { _ = try await store.markVisited(sessionID: created.id, poiID: created.route.pois[0].id, at: self.start) },
            { _ = try await store.export(sessionID: created.id, to: directory.appendingPathComponent("exports")) },
            { _ = try await store.create(route: .demo, at: self.start) }
        ]
        for operation in operations {
            do {
                try await operation()
                XCTFail("A quarantined instance must not continue or return an authoritative snapshot.")
            } catch LocalSessionStoreError.quarantined { }
        }
        XCTAssertEqual(try Data(contentsOf: locations), uncertainLocationBytes)
        XCTAssertEqual(try Data(contentsOf: events), eventsBefore, "Do not append a best-effort interrupted event.")
        let recovery = LocalSessionStore(root: root)
        let recovered = try await recovery.read(sessionID: created.id)
        XCTAssertEqual(recovered.observationCount, 1, "Recovery, not the failed writer, determines what reached disk.")
        XCTAssertEqual(recovered.state, .interrupted)
    }

    func testUncertainStateAppendAlsoQuarantinesWithoutSequenceReuse() async throws {
        let root = try temporaryDirectory()
        let store = LocalSessionStore(root: root, afterJournalWrite: { throw InjectedFailure.afterWrite })
        let created = try await store.create(route: .demo, at: start)
        do {
            _ = try await store.setState(sessionID: created.id, state: .paused, at: start.addingTimeInterval(2))
            XCTFail("The event's sync result is unknown.")
        } catch InjectedFailure.afterWrite { }
        do {
            _ = try await store.setState(sessionID: created.id, state: .finished, at: start.addingTimeInterval(3))
            XCTFail("No second event may reuse the uncertain sequence.")
        } catch LocalSessionStoreError.quarantined { }
        let recovery = LocalSessionStore(root: root)
        let recovered = try await recovery.read(sessionID: created.id)
        XCTAssertEqual(recovered.state, .interrupted)
        XCTAssertEqual(recovered.endedAt, start.addingTimeInterval(2))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let events = root.appendingPathComponent(created.id.uuidString).appendingPathComponent("events.jsonl")
        let entries = try Data(contentsOf: events).split(separator: 0x0A).map { try decoder.decode(SessionEvent.self, from: Data($0)) }
        XCTAssertEqual(entries.map(\.metadata.sequence), [1, 2, 3])
        XCTAssertEqual(entries.map(\.state), [.recording, .paused, .interrupted])
    }

    func testRejectedRouteDoesNotQuarantineStore() async throws {
        let store = LocalSessionStore(root: try temporaryDirectory())
        let invalid = RoutePlan(id: "invalid", routeID: "invalid", title: "Invalid", pois: [], legs: [], isDemo: true)
        do {
            _ = try await store.create(route: invalid, at: start)
            XCTFail("Validate route before writing a session.")
        } catch RouteValidationError.emptyRoute { }
        let valid = try await store.create(route: .demo, at: start)
        XCTAssertEqual(valid.state, .recording)
    }
}
