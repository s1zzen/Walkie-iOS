import Foundation
import XCTest
@testable import WalkieCore

final class WalkCompletionPolicyTests: XCTestCase {
    func testSkippingBeginningMiddleOrFinalStopCompletesAllRemainingVisits() {
        for skipped in RoutePlan.demo.pois.map(\.id) {
            var record = SessionRecord(route: .demo, startedAt: Date())
            record.manualSkippedPOIIDs = [skipped]
            record.manualVisitedPOIIDs = RoutePlan.demo.pois.map(\.id).filter { $0 != skipped }
            XCTAssertTrue(WalkCompletionPolicy.allRequiredVisited(in: record))
            XCTAssertEqual(WalkCompletionPolicy.completion(for: record)?.method, "all_points")
        }
    }

    func testManualAndAutomaticVisitsShareRuleButNotTheirSourcesOrResearchTruth() {
        var record = SessionRecord(route: .demo, startedAt: Date())
        record.manualVisitedPOIIDs = [RoutePlan.demo.pois[0].id]
        record.autoVisitedPOIIDs = Array(RoutePlan.demo.pois.dropFirst().map(\.id))
        XCTAssertEqual(WalkCompletionPolicy.completion(for: record)?.state, .finished)
        XCTAssertEqual(record.manualVisitedPOIIDs.count, 1)
        XCTAssertEqual(record.completionLabel, "unknown")
    }

    func testSkippingEveryStopDoesNotVacuouslyCompleteWalk() {
        var record = SessionRecord(route: .demo, startedAt: Date())
        record.manualSkippedPOIIDs = RoutePlan.demo.pois.map(\.id)
        XCTAssertFalse(WalkCompletionPolicy.allRequiredVisited(in: record))
        XCTAssertFalse(WalkCompletionPolicy.canFinishAtLastPoint(in: record))
        XCTAssertNil(WalkCompletionPolicy.completion(for: record, atLastPoint: true))
        XCTAssertEqual(WalkCompletionPolicy.interruption.state, .interrupted)
    }

    func testExplicitLastEffectivePointIsDistinctFromAutomaticAllPoints() {
        var record = SessionRecord(route: .demo, startedAt: Date())
        record.manualSkippedPOIIDs = [RoutePlan.demo.pois.last!.id]
        record.manualVisitedPOIIDs = [RoutePlan.demo.pois[RoutePlan.demo.pois.count - 2].id]
        XCTAssertNil(WalkCompletionPolicy.completion(for: record))
        XCTAssertTrue(WalkCompletionPolicy.canFinishAtLastPoint(in: record))
        XCTAssertEqual(WalkCompletionPolicy.completion(for: record, atLastPoint: true)?.method, "finish_last_point")
    }

    func testRepeatPersistsAndMissingLegacyKindDefaultsRegular() throws {
        let record = SessionRecord(route: .demo, startedAt: Date(), kind: .repeat)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(SessionRecord.self, from: data).kind, .repeat)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "startKind")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertEqual(try JSONDecoder().decode(SessionRecord.self, from: legacyData).kind, .regular)
    }

    func testStoreKeepsRepeatOnNewSessionWithoutChangingOriginalVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSessionStore(root: root)
        let first = try await store.create(route: .demo, at: Date())
        _ = try await store.setState(sessionID: first.id, state: .interrupted, at: Date(), productFinishMethod: "interrupted")
        let repeated = try await store.create(route: first.route, at: Date(), kind: .repeat)
        XCTAssertNotEqual(first.id, repeated.id)
        XCTAssertEqual(first.route, repeated.route)
        let recovered = try await LocalSessionStore(root: root).read(sessionID: repeated.id)
        XCTAssertEqual(recovered.kind, .repeat)
        XCTAssertEqual(recovered.route.id, first.route.id)
    }
}
