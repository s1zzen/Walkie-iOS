import Foundation
import XCTest
import WalkieCore
@testable import Walkie

@MainActor
final class WalkSessionCoordinatorTests: XCTestCase {
    func testStartPauseResumeAndFinishPersistOneSessionAndControlSensors() async throws {
        let environment = try makeEnvironment()
        let coordinator = environment.coordinator
        XCTAssertFalse(environment.sensors.isRunning)
        XCTAssertNil(coordinator.record)

        await coordinator.start(route: .demo)
        let sessionID = try XCTUnwrap(coordinator.record?.id)
        XCTAssertTrue(environment.sensors.isRunning)
        XCTAssertTrue(coordinator.hasOpenSession)
        XCTAssertEqual(coordinator.record?.state, .recording)
        XCTAssertEqual(environment.sensors.startCount, 1)
        let started = try await environment.store.read(sessionID: sessionID)
        XCTAssertEqual(started.state, .recording)

        await coordinator.pause()
        XCTAssertFalse(environment.sensors.isRunning)
        XCTAssertEqual(coordinator.record?.state, .paused)
        XCTAssertTrue(coordinator.hasOpenSession)

        await coordinator.resume()
        XCTAssertTrue(environment.sensors.isRunning)
        XCTAssertEqual(coordinator.record?.id, sessionID)
        XCTAssertEqual(coordinator.record?.state, .recording)
        XCTAssertEqual(environment.sensors.startCount, 2)

        await coordinator.finish()
        XCTAssertFalse(environment.sensors.isRunning)
        XCTAssertEqual(environment.sensors.stopCount, 2)
        XCTAssertEqual(coordinator.record?.id, sessionID)
        XCTAssertEqual(coordinator.record?.state, .interrupted)
        XCTAssertFalse(coordinator.hasOpenSession)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertNil(coordinator.errorMessage)
        let finished = try await environment.store.read(sessionID: sessionID)
        XCTAssertEqual(finished.state, .interrupted)
        XCTAssertNotNil(finished.endedAt)
        XCTAssertEqual(finished.completionLabel, "unknown", "Stopping recording is not route completion")
        let events: [SessionEvent] = try readJournal(environment: environment, sessionID: sessionID, filename: "events.jsonl")
        XCTAssertEqual(events.compactMap(\.state), [.recording, .paused, .recording, .interrupted])
    }

    func testFinishDrainsAlreadyDeliveredBatchBeforeFinalEvent() async throws {
        let environment = try makeEnvironment()
        await environment.coordinator.start(route: .demo)
        let sessionID = try XCTUnwrap(environment.coordinator.record?.id)
        for index in 0..<40 {
            environment.sensors.emit(sample(index: index))
        }
        // No intermediate await: writes are still queued when Finish is pressed.
        await environment.coordinator.finish()
        XCTAssertEqual(environment.coordinator.record?.observationCount, 40)
        let persisted = try await environment.store.read(sessionID: sessionID)
        XCTAssertEqual(persisted.observationCount, 40)
        XCTAssertEqual(persisted.state, .interrupted)
        let locations: [LocationObservation] = try readJournal(environment: environment, sessionID: sessionID, filename: "locations.jsonl")
        let events: [SessionEvent] = try readJournal(environment: environment, sessionID: sessionID, filename: "events.jsonl")
        XCTAssertEqual(locations.count, 40)
        XCTAssertEqual(locations.map(\.metadata.sequence), Array(2...41))
        XCTAssertEqual(events.last?.state, .interrupted)
        XCTAssertEqual(events.last?.metadata.sequence, 42)
        XCTAssertEqual(locations.map(\.metadata.monotonicTime), (0..<40).map { 1_000 + Double($0) })
    }

    func testCallbacksWhilePausedAndAfterFinishAreIgnored() async throws {
        let environment = try makeEnvironment()
        await environment.coordinator.start(route: .demo)
        let sessionID = try XCTUnwrap(environment.coordinator.record?.id)
        environment.sensors.emit(sample(index: 0))
        await environment.coordinator.pause()
        XCTAssertEqual(environment.coordinator.record?.observationCount, 1)
        let lastAcceptedTime = environment.coordinator.latestObservation?.monotonicTime

        environment.sensors.emit(sample(index: 1))
        environment.sensors.emit(sample(index: 2))
        XCTAssertEqual(environment.coordinator.latestObservation?.monotonicTime, lastAcceptedTime)
        await environment.coordinator.resume()
        environment.sensors.emit(sample(index: 3))
        await environment.coordinator.finish()
        environment.sensors.emit(sample(index: 4))

        let persisted = try await environment.store.read(sessionID: sessionID)
        XCTAssertEqual(persisted.observationCount, 2)
        XCTAssertEqual(environment.coordinator.record?.observationCount, 2)
        let locations: [LocationObservation] = try readJournal(environment: environment, sessionID: sessionID, filename: "locations.jsonl")
        XCTAssertEqual(locations.map(\.metadata.monotonicTime), [1_000, 1_003])
    }

    func testManualVisitSharesWriteQueueWithIncomingSensorBatch() async throws {
        let environment = try makeEnvironment()
        await environment.coordinator.start(route: .demo)
        let sessionID = try XCTUnwrap(environment.coordinator.record?.id)
        let poiID = try XCTUnwrap(RoutePlan.demo.pois.first?.id)
        for index in 0..<30 { environment.sensors.emit(sample(index: index)) }
        let marking = Task { await environment.coordinator.markVisited(poiID: poiID) }
        await waitUntil { environment.coordinator.isBusy }
        for index in 30..<60 { environment.sensors.emit(sample(index: index)) }
        await marking.value
        await environment.coordinator.finish()

        XCTAssertEqual(environment.coordinator.record?.observationCount, 60)
        XCTAssertEqual(environment.coordinator.record?.manualVisitedPOIIDs, [poiID])
        let persisted = try await environment.store.read(sessionID: sessionID)
        XCTAssertEqual(persisted.observationCount, 60)
        XCTAssertEqual(persisted.manualVisitedPOIIDs, [poiID])
        let locations: [LocationObservation] = try readJournal(environment: environment, sessionID: sessionID, filename: "locations.jsonl")
        let events: [SessionEvent] = try readJournal(environment: environment, sessionID: sessionID, filename: "events.jsonl")
        XCTAssertEqual(locations.count, 60)
        XCTAssertEqual(events.filter { $0.kind == .manualVisit }.count, 1)
        let allSequences = (locations.map(\.metadata.sequence) + events.map(\.metadata.sequence)).sorted()
        XCTAssertEqual(allSequences, Array(1...63), "Manual and sensor events must have one ordered, gap-free journal")
    }

    func testRecordingSurvivesWalkViewModelDisposalAndRecreation() async throws {
        let environment = try makeEnvironment()
        var firstViewModel: WalkViewModel? = WalkViewModel(coordinator: environment.coordinator)
        weak var disposedViewModel = firstViewModel
        await firstViewModel?.start(route: .demo)
        let sessionID = try XCTUnwrap(firstViewModel?.record?.id)
        firstViewModel = nil
        XCTAssertNil(disposedViewModel, "Coordinator subscriptions must not retain screen ViewModels")
        XCTAssertTrue(environment.sensors.isRunning)
        XCTAssertEqual(environment.sensors.stopCount, 0)

        environment.sensors.emit(sample(index: 0))
        let secondViewModel = WalkViewModel(coordinator: environment.coordinator)
        XCTAssertEqual(secondViewModel.record?.id, sessionID)
        XCTAssertTrue(secondViewModel.hasOpenSession)
        await secondViewModel.pause()
        XCTAssertEqual(secondViewModel.record?.observationCount, 1)
        XCTAssertEqual(secondViewModel.record?.state, .paused)
        await secondViewModel.finish()
        let persisted = try await environment.store.read(sessionID: sessionID)
        XCTAssertEqual(persisted.observationCount, 1)
        XCTAssertEqual(persisted.state, .interrupted)
    }

    func testReturnStubOnlyPresentsExplanationWithoutMutatingPlanOrRecord() async throws {
        let environment = try makeEnvironment()
        let viewModel = WalkViewModel(coordinator: environment.coordinator)
        await viewModel.start(route: .demo)
        let original = try XCTUnwrap(viewModel.record)
        let sessionDirectory = environment.root.appendingPathComponent(original.id.uuidString)
        let manifestBefore = try Data(contentsOf: sessionDirectory.appendingPathComponent("session.json"))
        let eventsBefore = try Data(contentsOf: sessionDirectory.appendingPathComponent("events.jsonl"))
        let locationsBefore = try Data(contentsOf: sessionDirectory.appendingPathComponent("locations.jsonl"))

        viewModel.requestReturnToPreviousRoute()

        XCTAssertTrue(viewModel.showsReturnStub)
        XCTAssertEqual(viewModel.record, original)
        XCTAssertEqual(viewModel.record?.route, RoutePlan.demo)
        XCTAssertEqual(environment.sensors.startCount, 1)
        XCTAssertEqual(environment.sensors.stopCount, 0)
        let persisted = try await environment.store.read(sessionID: original.id)
        XCTAssertEqual(persisted, original)
        XCTAssertEqual(try Data(contentsOf: sessionDirectory.appendingPathComponent("session.json")), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: sessionDirectory.appendingPathComponent("events.jsonl")), eventsBefore)
        XCTAssertEqual(try Data(contentsOf: sessionDirectory.appendingPathComponent("locations.jsonl")), locationsBefore)
        await viewModel.finish()
    }

    func testInvalidSampleInterruptsRecordingStopsSensorsAndDropsQueuedTail() async throws {
        let environment = try makeEnvironment()
        await environment.coordinator.start(route: .demo)
        let sessionID = try XCTUnwrap(environment.coordinator.record?.id)
        environment.sensors.emit(sample(index: 0))
        environment.sensors.emit(sample(index: 1, coordinate: Coordinate(latitude: 100, longitude: 37)))
        environment.sensors.emit(sample(index: 2))
        await waitUntil { environment.coordinator.record?.state == .interrupted }
        XCTAssertFalse(environment.sensors.isRunning)
        XCTAssertGreaterThanOrEqual(environment.sensors.stopCount, 1)
        XCTAssertFalse(environment.coordinator.hasOpenSession)
        XCTAssertTrue(environment.coordinator.storageUnavailable)
        XCTAssertNotNil(environment.coordinator.errorMessage)
        // After an uncertain append/sync outcome, no further write may be made
        // through the old store. Restart is the authoritative recovery boundary.
        await environment.coordinator.finish()
        await environment.coordinator.start(route: .demo)
        XCTAssertEqual(environment.sensors.startCount, 1, "A failed writer must not be reused for a new recording")
        XCTAssertEqual(environment.coordinator.record?.id, sessionID)
        let recoveredStore = LocalSessionStore(root: environment.root)
        let persisted = try await recoveredStore.read(sessionID: sessionID)
        XCTAssertEqual(persisted.state, .interrupted, "A fresh store must recover the open durable record as interrupted")
        XCTAssertEqual(persisted.observationCount, 1)
        XCTAssertEqual(environment.coordinator.record?.state, .interrupted)
        let locations: [LocationObservation] = try readJournal(environment: environment, sessionID: sessionID, filename: "locations.jsonl")
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations.first?.metadata.monotonicTime, 1_000)
    }

    private struct Environment {
        let root: URL
        let store: LocalSessionStore
        let sensors: FakeSensors
        let coordinator: WalkSessionCoordinator
    }

    func testExplicitPauseExpiresAsInactivityWithoutRestartingSensors() async throws {
        let environment = try makeEnvironment(pauseTimeoutSeconds: 0.05)
        await environment.coordinator.start(route: .demo)
        await environment.coordinator.pause()
        XCTAssertNotNil(environment.coordinator.pauseTimeoutAt)
        await waitUntil { environment.coordinator.record?.state == .interrupted }
        XCTAssertEqual(environment.coordinator.record?.productFinishMethod, "inactivity")
        XCTAssertFalse(environment.sensors.isRunning)
        XCTAssertEqual(environment.sensors.startCount, 1)
        let saved = try await environment.store.read(sessionID: XCTUnwrap(environment.coordinator.record?.id))
        XCTAssertEqual(saved.productFinishMethod, "inactivity")
        XCTAssertEqual(saved.completionLabel, "unknown")
    }

    func testSilenceWithoutExplicitPauseDoesNotCloseWalk() async throws {
        let environment = try makeEnvironment(pauseTimeoutSeconds: 0.02)
        await environment.coordinator.start(route: .demo)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(environment.coordinator.record?.state, .recording)
        XCTAssertNil(environment.coordinator.pauseTimeoutAt)
        await environment.coordinator.finish()
        XCTAssertEqual(environment.coordinator.record?.state, .interrupted)
    }

    func testResumeCancelsExplicitPauseDeadline() async throws {
        let environment = try makeEnvironment(pauseTimeoutSeconds: 0.5)
        await environment.coordinator.start(route: .demo)
        await environment.coordinator.pause()
        await environment.coordinator.resume()
        XCTAssertNil(environment.coordinator.pauseTimeoutAt)
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(environment.coordinator.record?.state, .recording)
        await environment.coordinator.finish()
    }

    func testAllPlacesFinishCompletedButDoNotBecomeIndependentGroundTruth() async throws {
        let environment = try makeEnvironment()
        await environment.coordinator.start(route: .demo)
        for place in RoutePlan.demo.pois { await environment.coordinator.markVisited(poiID: place.id) }
        await environment.coordinator.finish()
        XCTAssertEqual(environment.coordinator.record?.state, .finished)
        XCTAssertEqual(environment.coordinator.record?.productFinishMethod, "all_points")
        XCTAssertEqual(environment.coordinator.record?.completionLabel, "unknown")
    }

    func testManualVisitAutomaticallyClosesAfterAllNonSkippedStopsIncludingSkippedFinal() async throws {
        for skippedIndex in RoutePlan.demo.pois.indices {
            let environment = try makeEnvironment()
            await environment.coordinator.start(route: .demo)
            await environment.coordinator.markSkipped(poiID: RoutePlan.demo.pois[skippedIndex].id)
            for (index, place) in RoutePlan.demo.pois.enumerated() where index != skippedIndex {
                await environment.coordinator.markVisited(poiID: place.id)
            }
            XCTAssertEqual(environment.coordinator.record?.state, .finished, "Skipped index \(skippedIndex)")
            XCTAssertEqual(environment.coordinator.record?.productFinishMethod, "all_points")
            XCTAssertEqual(environment.coordinator.record?.completionLabel, "unknown")
            XCTAssertFalse(environment.sensors.isRunning)
        }
    }

    func testSkippingFinalUnprocessedStopAutomaticallyCompletesButSkippingAllNeedsExplicitInterruption() async throws {
        let completeEnvironment = try makeEnvironment()
        await completeEnvironment.coordinator.start(route: .demo)
        for place in RoutePlan.demo.pois.dropLast() { await completeEnvironment.coordinator.markVisited(poiID: place.id) }
        await completeEnvironment.coordinator.markSkipped(poiID: RoutePlan.demo.pois.last!.id)
        XCTAssertEqual(completeEnvironment.coordinator.record?.state, .finished)

        let skippedEnvironment = try makeEnvironment()
        await skippedEnvironment.coordinator.start(route: .demo)
        for place in RoutePlan.demo.pois { await skippedEnvironment.coordinator.markSkipped(poiID: place.id) }
        XCTAssertEqual(skippedEnvironment.coordinator.record?.state, .recording)
        let accepted = await skippedEnvironment.coordinator.complete(atLastPoint: true)
        XCTAssertFalse(accepted)
        XCTAssertNotNil(skippedEnvironment.coordinator.completionMessage)
        await skippedEnvironment.coordinator.interrupt()
        XCTAssertEqual(skippedEnvironment.coordinator.record?.state, .interrupted)
        XCTAssertEqual(skippedEnvironment.coordinator.record?.productFinishMethod, "interrupted")
    }

    func testRepeatStartKeepsVersionButCreatesNewTypedSession() async throws {
        let environment = try makeEnvironment()
        await environment.coordinator.start(route: .demo)
        let first = try XCTUnwrap(environment.coordinator.record)
        await environment.coordinator.interrupt()
        await environment.coordinator.start(route: first.route, kind: .repeat)
        let repeated = try XCTUnwrap(environment.coordinator.record)
        XCTAssertNotEqual(repeated.id, first.id)
        XCTAssertEqual(repeated.kind, .repeat)
        XCTAssertEqual(repeated.route, first.route)
        let saved = try await environment.store.read(sessionID: repeated.id)
        XCTAssertEqual(saved.kind, .repeat)
        await environment.coordinator.interrupt()
    }

    func testConfiguredPauseTimeoutPreservesElapsedPause() async throws {
        let environment = try makeEnvironment(pauseTimeoutSeconds: 10)
        await environment.coordinator.start(route: .demo)
        await environment.coordinator.pause()
        let previousDeadline = try XCTUnwrap(environment.coordinator.pauseTimeoutAt)
        environment.coordinator.configurePauseTimeout(seconds: 0.05)
        let updatedDeadline = try XCTUnwrap(environment.coordinator.pauseTimeoutAt)
        XCTAssertEqual(updatedDeadline.timeIntervalSince(previousDeadline), -9.95, accuracy: 0.02)
        await waitUntil { environment.coordinator.record?.state == .interrupted }
        XCTAssertEqual(environment.coordinator.record?.productFinishMethod, "inactivity")
        environment.coordinator.configurePauseTimeout(seconds: .nan)
        XCTAssertEqual(environment.coordinator.pauseTimeoutSeconds, 0.05)
    }

    func testDeviationCandidatesIncludeRejectionsAndSelfReturnOnceWithoutCoordinates() async throws {
        let environment = try makeEnvironment()
        let onLine = Coordinate(latitude: 55.751, longitude: 37.61)
        let outside = Coordinate(latitude: 55.751, longitude: 37.6106)
        let route = RoutePlan(id: UUID().uuidString, routeID: UUID().uuidString, title: "Тест",
            pois: [RoutePOI(id: "stop", name: "Точка", coordinate: onLine)],
            legs: [RouteLeg(id: "leg", coordinates: [Coordinate(latitude: 55.75, longitude: 37.61), Coordinate(latitude: 55.752, longitude: 37.61)])], isDemo: false)
        var events: [(String, [String: String])] = []
        environment.coordinator.onProductEvent = { events.append(($0, $1)) }
        await environment.coordinator.start(route: route)
        let walkID = try XCTUnwrap(environment.coordinator.record?.id.uuidString)
        let date = Date(), time = ProcessInfo.processInfo.systemUptime
        func deliver(_ offset: Double, _ coordinate: Coordinate, accuracy: Double = 5) {
            environment.sensors.emit(SensorObservation(coordinate: coordinate, accuracy: accuracy,
                observedAt: date.addingTimeInterval(offset), receivedAt: date.addingTimeInterval(offset), monotonicTime: time + offset))
        }
        deliver(0, outside)
        deliver(5, outside)
        deliver(5, outside) // duplicate delivered fix is not another candidate
        deliver(6, outside, accuracy: 100) // rejected coordinate gate is still visible to telemetry
        deliver(8, onLine)
        deliver(13, onLine)
        deliver(18, onLine)
        await environment.coordinator.pause() // drain delivered writes
        let candidates = events.filter { $0.0 == "off_route_candidate" }
        XCTAssertEqual(candidates.count, 6)
        XCTAssertTrue(candidates.contains { $0.1["decision"] == "confirmed" })
        XCTAssertTrue(candidates.contains { $0.1["decision"] == "rejected" && $0.1["accuracy_m"] == "100.0" })
        XCTAssertEqual(events.filter { $0.0 == "off_route_self_return" }.count, 1)
        for (_, payload) in events {
            XCTAssertEqual(payload["walk_id"], walkID)
            XCTAssertEqual(payload["route_id"], route.routeID)
            XCTAssertEqual(payload["route_version_id"], route.id)
            XCTAssertNil(payload["latitude"]); XCTAssertNil(payload["longitude"])
        }
        await environment.coordinator.interrupt()
    }

    func testSkippingRatingIsLocallyAcceptedWhenOutboxCannotWrite() async throws {
        let environment = try makeEnvironment()
        let routeID = UUID().uuidString, versionID = UUID().uuidString
        let coordinate = Coordinate(latitude: 55.75, longitude: 37.61)
        let route = RoutePlan(id: versionID, routeID: routeID, title: "Тест пропуска оценки",
            pois: [RoutePOI(id: "place", name: "Точка", coordinate: coordinate)],
            legs: [RouteLeg(id: "leg", coordinates: [coordinate, Coordinate(latitude: 55.751, longitude: 37.61)])], isDemo: false)
        let metadata = environment.root.appendingPathComponent("route_metadata.json")
        try JSONEncoder().encode([versionID: LiveRouteDetails(routeID: routeID, versionID: versionID,
            distanceMeters: 100, durationSeconds: 60, issuedAt: "2026-10-25T09:00:00Z", stops: [])]).write(to: metadata)
        let outbox = environment.root.appendingPathComponent("outbox.json")
        let sync = ProductWalkSync(url: outbox, metadataURL: metadata, owner: { "test-owner" }, automaticallyFlush: false)
        let coordinator = WalkSessionCoordinator(store: environment.store, sensors: environment.sensors, productSync: sync)
        await coordinator.start(route: route)
        await coordinator.interrupt()
        let record = try XCTUnwrap(coordinator.record)
        // Only this test's disposable queue is made unwritable. The session
        // directory remains healthy and must accept the independent decision.
        try FileManager.default.removeItem(at: outbox)
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        let accepted = await coordinator.skipFeedback()
        XCTAssertTrue(accepted)
        XCTAssertFalse(coordinator.feedbackSaved, "A skip must not become a real rating")
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertTrue((coordinator.syncStatus ?? "").contains("Пропуск оценки сохранён локально"))
        let decisionFile = environment.root.appendingPathComponent(record.id.uuidString).appendingPathComponent("feedback_decision.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let decision = try decoder.decode(WalkFeedbackDecision.self, from: Data(contentsOf: decisionFile))
        XCTAssertEqual(decision.kind, .skip)
        XCTAssertEqual(decision.sessionID, record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: decisionFile.deletingLastPathComponent().appendingPathComponent("feedback.json").path))
    }

    private func makeEnvironment(pauseTimeoutSeconds: Double = 1_800) throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkieCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let store = LocalSessionStore(root: root)
        let sensors = FakeSensors()
        return Environment(root: root, store: store, sensors: sensors,
                           coordinator: WalkSessionCoordinator(store: store, sensors: sensors, pauseTimeoutSeconds: pauseTimeoutSeconds))
    }

    private func sample(index: Int, coordinate: Coordinate? = nil) -> SensorObservation {
        let time = Date(timeIntervalSince1970: 1_790_000_000 + Double(index))
        return SensorObservation(
            coordinate: coordinate ?? Coordinate(latitude: 55.76 + Double(index) * 0.00001, longitude: 37.61),
            accuracy: 10, observedAt: time, receivedAt: time.addingTimeInterval(0.2),
            monotonicTime: 1_000 + Double(index)
        )
    }

    private func readJournal<T: Decodable>(environment: Environment, sessionID: UUID, filename: String) throws -> [T] {
        let file = environment.root.appendingPathComponent(sessionID.uuidString).appendingPathComponent(filename)
        let data = try Data(contentsOf: file)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try data.split(separator: 0x0A).map { try decoder.decode(T.self, from: Data($0)) }
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Asynchronous coordinator operation did not complete")
    }

}

@MainActor
private final class FakeSensors: SensorSource {
    var onObservation: ((SensorObservation) -> Void)?
    var onStatus: ((String) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    func start() { startCount += 1; isRunning = true }
    func stop() { stopCount += 1; isRunning = false }

    /// Even stopped sensors may have an already-delivered callback in flight.
    /// Deliberately bypass isRunning so the coordinator's own guard is exercised.
    func emit(_ observation: SensorObservation) { onObservation?(observation) }
}
