import Foundation
import XCTest
import WalkieCore
@testable import Walkie

final class ProductWalkSyncTests: XCTestCase {
    func testOfflineOutboxSurvivesRestartReplaysInOrderAndContainsNoGPS() async throws {
        let environment = try makeEnvironment()
        let offline = RecordingWalkTransport(fails: true)
        let first = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: offline, owner: { "owner" })
        try await first.start(environment.record)
        try await first.checkpoint(environment.record, poiID: "p1", skipped: false, at: environment.record.startedAt)
        var finished = environment.record
        finished.state = .finished; finished.endedAt = finished.startedAt.addingTimeInterval(60)
        try await first.finish(finished, method: "all_points", distanceEstimateMeters: 50)
        try await first.rating(finished, stars: 5, comment: "Хорошая прогулка")
        await first.flush()
        let pending = await first.pendingCount()
        XCTAssertEqual(pending, 4)
        let online = RecordingWalkTransport(fails: false)
        let restored = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" })
        await restored.flush()
        let calls = await online.calls
        XCTAssertEqual(calls.map(\.method), ["POST", "POST", "POST", "PUT"])
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls[0].path == "/v1/walks")
        XCTAssertTrue(calls[1].path.hasSuffix("/checkpoints"))
        XCTAssertTrue(calls[2].path.hasSuffix("/finish"))
        let checkpoint = try XCTUnwrap(try JSONSerialization.jsonObject(with: calls[1].body!) as? [String: Any])
        let items = try XCTUnwrap(checkpoint["items"] as? [[String: Any]])
        XCTAssertNotNil(UUID(uuidString: items[0]["id"] as? String ?? ""))
        XCTAssertNil(items[0]["accuracy_m"]); XCTAssertNil(items[0]["dwell_s"])
        let bodies = calls.compactMap(\.body).compactMap { String(data: $0, encoding: .utf8) }.joined()
        for privateField in ["latitude", "longitude", "location", "research", "track", "steps_total"] {
            XCTAssertFalse(bodies.contains(privateField))
        }
        let finalPending = await restored.pendingCount()
        XCTAssertEqual(finalPending, 0)
    }

    func testDifferentAccountCannotSendPreviousOwnersJobs() async throws {
        let environment = try makeEnvironment()
        let offline = RecordingWalkTransport(fails: true)
        let queue = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: offline, owner: { "first-owner" })
        try await queue.start(environment.record)
        await queue.flush()
        let newAccount = RecordingWalkTransport(fails: false)
        let restored = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: newAccount, owner: { "second-owner" })
        await restored.flush()
        let calls = await newAccount.calls
        XCTAssertTrue(calls.isEmpty)
        let pending = await restored.pendingCount()
        XCTAssertEqual(pending, 1)
    }

    func testMissingDistanceIsDurablyBlockedInsteadOfPretendingZero() async throws {
        let environment = try makeEnvironment()
        let transport = RecordingWalkTransport(fails: true)
        let queue = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: transport, owner: { "owner" })
        try await queue.start(environment.record)
        var record = environment.record; record.state = .finished; record.endedAt = record.startedAt.addingTimeInterval(60)
        try await queue.finish(record, method: "interrupted", distanceEstimateMeters: nil)
        let saved = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: environment.queue)) as? [String: Any])
        let blocked = try XCTUnwrap(saved["blockedFinishes"] as? [String: Any])
        XCTAssertNotNil(blocked[record.id.uuidString])
        let data = try Data(contentsOf: environment.queue)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("missing_distance_estimate"))
        let online = RecordingWalkTransport(fails: false)
        let restored = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" })
        await restored.flush()
        let status = await restored.snapshot(for: record.id)
        XCTAssertEqual(status.phase, .requiresDistance)
        XCTAssertNotNil(status.problem)
        XCTAssertFalse(status.showProOffer)
        let calls = await online.calls
        XCTAssertFalse(calls.contains { $0.path.hasSuffix("/finish") })
        XCTAssertFalse(calls.contains { $0.path.hasSuffix("/rating") })
    }

    func testFinishAcknowledgementAndServerProOfferSurviveRestartAndAreConsumedOnce() async throws {
        let environment = try makeEnvironment()
        let offline = RecordingWalkTransport(fails: true)
        let first = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: offline, owner: { "owner" })
        try await first.start(environment.record)
        var record = environment.record; record.state = .finished; record.endedAt = record.startedAt.addingTimeInterval(60)
        try await first.finish(record, method: "all_points", distanceEstimateMeters: 20)
        try await first.rating(record, stars: 5, comment: "")
        // A pre-fix journal had rating jobs but no explicit summary decision set.
        var legacy = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: environment.queue)) as? [String: Any])
        legacy.removeValue(forKey: "summaryDecisionIDs")
        try JSONSerialization.data(withJSONObject: legacy).write(to: environment.queue, options: .atomic)
        let online = RecordingWalkTransport(fails: false)
        let second = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" })
        await second.flush()
        let secondStatus = await second.snapshot(for: record.id)
        XCTAssertEqual(secondStatus.phase, .acknowledged)
        XCTAssertTrue(secondStatus.showProOffer)
        let third = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" })
        let pendingOffer = await third.nextPendingProOffer()
        XCTAssertEqual(pendingOffer, record.id)
        try await third.markProOfferShown(walkID: record.id)
        let fourth = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" })
        let shownOffer = await fourth.nextPendingProOffer()
        XCTAssertNil(shownOffer)
        let acknowledged = await fourth.snapshot(for: record.id)
        XCTAssertEqual(acknowledged.phase, .acknowledged)
        XCTAssertFalse(acknowledged.showProOffer)
    }

    func testInvalidFinishResponseKeepsRequestAndRatingPending() async throws {
        let environment = try makeEnvironment()
        let offline = RecordingWalkTransport(fails: true)
        let queue = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: offline, owner: { "owner" })
        try await queue.start(environment.record)
        var record = environment.record; record.state = .finished; record.endedAt = record.startedAt.addingTimeInterval(60)
        try await queue.finish(record, method: "all_points", distanceEstimateMeters: 20)
        try await queue.rating(record, stars: 5, comment: "")
        let bad = RecordingWalkTransport(fails: false, invalidFinish: true)
        let restored = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: bad, owner: { "owner" })
        await restored.flush()
        let status = await restored.snapshot(for: record.id)
        XCTAssertEqual(status.phase, .queued)
        XCTAssertEqual(status.pendingOperations, 2)
        XCTAssertNotNil(status.problem)
        let calls = await bad.calls
        XCTAssertFalse(calls.contains { $0.path.hasSuffix("/rating") })
        let pendingOffer = await restored.nextPendingProOffer()
        XCTAssertNil(pendingOffer)
    }

    func testLostFinishResponseRetriesIdenticalPayloadAndThenReleasesSkippedRating() async throws {
        let environment = try makeEnvironment()
        let offline = RecordingWalkTransport(fails: true)
        let queue = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: offline, owner: { "owner" })
        try await queue.start(environment.record)
        var record = environment.record; record.state = .interrupted; record.endedAt = record.startedAt.addingTimeInterval(30)
        try await queue.finish(record, method: "interrupted", distanceEstimateMeters: 10)
        try await queue.skipRating(record)
        let transport = RecordingWalkTransport(fails: false, loseFirstFinishResponse: true)
        let restored = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: transport, owner: { "owner" })
        await restored.flush()
        let restarted = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: transport, owner: { "owner" })
        await restarted.flush()
        let calls = await transport.calls
        let finishes = calls.filter { $0.path.hasSuffix("/finish") }
        XCTAssertEqual(finishes.count, 2)
        XCTAssertEqual(finishes.first?.body, finishes.last?.body)
        let ratings = calls.filter { $0.path.hasSuffix("/rating") }
        XCTAssertEqual(ratings.count, 1)
        let rating = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(ratings.first?.body)) as? [String: Any])
        XCTAssertEqual(rating["kind"] as? String, "skip")
        let status = await restarted.snapshot(for: record.id)
        XCTAssertEqual(status.phase, .acknowledged)
    }

    func testRestartReconstructsBlockedDistanceFromLocalJournalBeforeSendingFinish() async throws {
        let environment = try makeEnvironment()
        let sessions = LocalSessionStore(root: environment.queue.deletingLastPathComponent().appendingPathComponent("Sessions"))
        let startedAt = Date().addingTimeInterval(-60)
        var record = try await sessions.create(route: environment.record.route, at: startedAt)
        let origin = record.route.pois[0].coordinate
        try await sessions.appendLocation(sessionID: record.id, coordinate: origin, horizontalAccuracy: 5,
            observedAt: startedAt.addingTimeInterval(1), receivedAt: startedAt.addingTimeInterval(1), monotonicTime: 1)
        try await sessions.appendLocation(sessionID: record.id, coordinate: Coordinate(latitude: origin.latitude + 0.00005, longitude: origin.longitude), horizontalAccuracy: 5,
            observedAt: startedAt.addingTimeInterval(6), receivedAt: startedAt.addingTimeInterval(6), monotonicTime: 6)
        record = try await sessions.setState(sessionID: record.id, state: .interrupted, at: startedAt.addingTimeInterval(30), productFinishMethod: "interrupted")
        let offline = RecordingWalkTransport(fails: true)
        // The old process did not have a store reference and durably blocked its finish.
        let queue = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: offline, owner: { "owner" })
        try await queue.start(record)
        try await queue.finish(record, method: "interrupted", distanceEstimateMeters: nil)
        try await queue.rating(record, stars: 4, comment: "")
        let online = RecordingWalkTransport(fails: false)
        let recoveredStore = LocalSessionStore(root: environment.queue.deletingLastPathComponent().appendingPathComponent("Sessions"))
        let restored = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" }, sessionStore: recoveredStore)
        await restored.flush()
        let calls = await online.calls
        let finish = try XCTUnwrap(calls.first { $0.path.hasSuffix("/finish") })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(finish.body)) as? [String: Any])
        let stats = try XCTUnwrap(body["stats"] as? [String: Any])
        XCTAssertGreaterThan(stats["distance_m"] as? Int ?? 0, 0)
        XCTAssertEqual(calls.last?.method, "PUT")
        let status = await restored.snapshot(for: record.id)
        XCTAssertEqual(status.phase, .acknowledged)
    }

    func testRepeatStartRetainsVersionButUsesDistinctWalkIDAndRepeatKind() async throws {
        let environment = try makeEnvironment()
        let offline = RecordingWalkTransport(fails: true)
        let queue = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: offline, owner: { "owner" })
        let repeated = SessionRecord(route: environment.record.route, startedAt: Date(), kind: .repeat)
        XCTAssertNotEqual(repeated.id, environment.record.id)
        try await queue.start(repeated)
        let online = RecordingWalkTransport(fails: false)
        let restored = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" })
        await restored.flush()
        let calls = await online.calls
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(calls.first?.body)) as? [String: Any])
        XCTAssertEqual(body["kind"] as? String, "repeat")
        XCTAssertEqual(body["version_id"] as? String, repeated.route.id)
        XCTAssertEqual(body["id"] as? String, repeated.id.uuidString)
    }

    func testCurrentOwnerCannotConsumeAnotherOwnersProOffer() async throws {
        let environment = try makeEnvironment()
        let offline = RecordingWalkTransport(fails: true)
        let queue = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: offline, owner: { "first" })
        try await queue.start(environment.record)
        var record = environment.record; record.state = .finished; record.endedAt = record.startedAt.addingTimeInterval(60)
        try await queue.finish(record, method: "all_points", distanceEstimateMeters: 10)
        try await queue.skipRating(record)
        let online = RecordingWalkTransport(fails: false)
        let firstOwner = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "first" })
        await firstOwner.flush()
        let secondOwner = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "second" })
        let secondOffer = await secondOwner.nextPendingProOffer()
        XCTAssertNil(secondOffer)
        try await secondOwner.markProOfferShown(walkID: record.id)
        let previousOwner = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "first" })
        let preservedOffer = await previousOwner.nextPendingProOffer()
        XCTAssertEqual(preservedOffer, record.id)
    }

    func testFinishAcknowledgementWaitsForDurableSummaryDecisionAcrossRestart() async throws {
        let environment = try makeEnvironment()
        let offline = RecordingWalkTransport(fails: true)
        let queue = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: offline, owner: { "owner" })
        try await queue.start(environment.record)
        var record = environment.record; record.state = .finished; record.endedAt = record.startedAt.addingTimeInterval(60)
        try await queue.finish(record, method: "all_points", distanceEstimateMeters: 10)
        let online = RecordingWalkTransport(fails: false)
        let acknowledged = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" })
        await acknowledged.flush()
        let beforeDecision = await acknowledged.snapshot(for: record.id)
        XCTAssertEqual(beforeDecision.phase, .acknowledged)
        XCTAssertFalse(beforeDecision.showProOffer)
        let restartedBeforeDecision = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" })
        let prematureOffer = await restartedBeforeDecision.nextPendingProOffer()
        XCTAssertNil(prematureOffer)
        try await restartedBeforeDecision.skipRating(record)
        let afterDecision = await restartedBeforeDecision.snapshot(for: record.id)
        XCTAssertTrue(afterDecision.showProOffer)
        let restartedAfterDecision = makeQueue(url: environment.queue, metadataURL: environment.metadata, client: online, owner: { "owner" })
        let offer = await restartedAfterDecision.nextPendingProOffer()
        XCTAssertEqual(offer, record.id)
    }

    private func makeQueue(url: URL, metadataURL: URL, client: any RouteBackendTransport,
                           owner: @escaping @Sendable () async -> String?, sessionStore: LocalSessionStore? = nil) -> ProductWalkSync {
        ProductWalkSync(url: url, metadataURL: metadataURL, client: client, owner: owner,
                        sessionStore: sessionStore, automaticallyFlush: false)
    }

    private struct Environment { let queue: URL; let metadata: URL; let record: SessionRecord }
    private func makeEnvironment() throws -> Environment {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WalkSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let version = UUID().uuidString, routeID = UUID().uuidString
        let coordinate = Coordinate(latitude: 55.7, longitude: 37.6)
        let plan = RoutePlan(id: version, routeID: routeID, title: "Test", pois: [RoutePOI(id: "p1", name: "Test", coordinate: coordinate)],
            legs: [RouteLeg(id: "leg", coordinates: [coordinate, Coordinate(latitude: 55.71, longitude: 37.6)])], isDemo: false)
        let details = LiveRouteDetails(routeID: routeID, versionID: version, distanceMeters: 100, durationSeconds: 60, issuedAt: "2026-10-23T09:00:00Z", stops: [])
        let metadata = folder.appendingPathComponent("route_metadata.json")
        try JSONEncoder().encode([version: details]).write(to: metadata)
        return Environment(queue: folder.appendingPathComponent("outbox.json"), metadata: metadata, record: SessionRecord(route: plan, startedAt: Date()))
    }
}

private actor RecordingWalkTransport: RouteBackendTransport {
    struct Call: Sendable { let path: String; let method: String; let body: Data? }
    let fails: Bool
    let invalidFinish: Bool
    var loseFirstFinishResponse: Bool
    var start: [String: String] = [:]
    var calls: [Call] = []
    init(fails: Bool, invalidFinish: Bool = false, loseFirstFinishResponse: Bool = false) {
        self.fails = fails; self.invalidFinish = invalidFinish; self.loseFirstFinishResponse = loseFirstFinishResponse
    }
    func request(path: String, method: String, body: Data?, authenticated: Bool) async throws -> Data {
        calls.append(Call(path: path, method: method, body: body))
        if fails { throw URLError(.notConnectedToInternet) }
        if path == "/v1/walks", let body,
           let input = try JSONSerialization.jsonObject(with: body) as? [String: String] { start = input }
        if path.hasSuffix("/finish") {
            if invalidFinish { return Data("{}".utf8) }
            if loseFirstFinishResponse { loseFirstFinishResponse = false; throw URLError(.networkConnectionLost) }
            let input = try JSONSerialization.jsonObject(with: body!) as! [String: Any]
            let method = input["method"] as! String
            let walk: [String: Any] = ["id": start["id"]!, "route_id": start["route_id"]!, "version_id": start["version_id"]!,
                "kind": start["kind"]!, "status": ["all_points", "finish_last_point"].contains(method) ? "completed" : "not_completed",
                "started_at": start["started_at"]!, "finish_method": method,
                "progress": ["visited_orders": [1], "skipped_orders": [], "total": 1]]
            return try JSONSerialization.data(withJSONObject: ["walk": walk, "show_pro_offer": true])
        }
        return Data("{}".utf8)
    }
}
