import Foundation
import XCTest
@testable import WalkieCore

final class SessionRecoveryTests: XCTestCase {
    func testLatestRestartInterruptedSessionRestoresPausedWithVisitSources() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = LocalSessionStore(root: root)
        let original = try await first.create(route: .demo, at: date)
        _ = try await first.markVisited(sessionID: original.id, poiID: RoutePlan.demo.pois[0].id, at: date)
        _ = try await first.markSkipped(sessionID: original.id, poiID: RoutePlan.demo.pois[1].id, at: date)
        let restarted = LocalSessionStore(root: root)
        let result = try await restarted.restoreLatestInterruptedAsPaused(at: date.addingTimeInterval(10))
        let recovered = try XCTUnwrap(result)
        XCTAssertEqual(recovered.record.id, original.id)
        XCTAssertEqual(recovered.record.state, .paused)
        XCTAssertNil(recovered.record.endedAt)
        XCTAssertNil(recovered.explicitPauseMetadata, "A killed recording is not an explicit inactivity pause")
        XCTAssertEqual(recovered.record.manualVisitedPOIIDs, [RoutePlan.demo.pois[0].id])
        XCTAssertEqual(recovered.record.manualSkippedPOIIDs, [RoutePlan.demo.pois[1].id])
        XCTAssertEqual(recovered.record.completionLabel, "unknown")
        XCTAssertFalse(recovered.hasResearchJournal)
        let again = try await restarted.restoreLatestInterruptedAsPaused(at: date.addingTimeInterval(11))
        XCTAssertNil(again, "Do not create a second recovery boundary on the live writer")
    }

    func testExplicitPauseMetadataAndResearchPresenceSurviveRestart() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = LocalSessionStore(root: root)
        let original = try await first.create(route: .demo, at: date)
        try await first.beginResearch(ResearchManifest(sessionID: original.id, configuration: .init(), startedAt: date, monotonicStart: 0))
        _ = try await first.setState(sessionID: original.id, state: .paused, at: date.addingTimeInterval(1))
        let restarted = LocalSessionStore(root: root)
        let result = try await restarted.restoreLatestInterruptedAsPaused(at: date.addingTimeInterval(10))
        let recovered = try XCTUnwrap(result)
        XCTAssertEqual(recovered.explicitPauseMetadata?.recordedAt, date.addingTimeInterval(1))
        XCTAssertNotNil(recovered.explicitPauseMetadata?.monotonicTime)
        XCTAssertTrue(recovered.hasResearchJournal)
        XCTAssertEqual(recovered.record.state, .paused)
    }

    func testUserInterruptionAndNewerClosedSessionAreNeverReopened() async throws {
        let root = makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let first = LocalSessionStore(root: root)
        _ = try await first.create(route: .demo, at: date)
        let newer = try await first.create(route: .demo, at: date.addingTimeInterval(2))
        _ = try await first.setState(sessionID: newer.id, state: .interrupted, at: date.addingTimeInterval(3), productFinishMethod: "interrupted")
        let restarted = LocalSessionStore(root: root)
        let recovery = try await restarted.restoreLatestInterruptedAsPaused(at: date.addingTimeInterval(10))
        XCTAssertNil(recovery, "Do not reopen an older crash record after the user finished a newer walk")
        let saved = try await restarted.read(sessionID: newer.id)
        XCTAssertEqual(saved.productFinishMethod, "interrupted")
    }

    private func makeRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("WalkRecovery-\(UUID().uuidString)")
    }
}
