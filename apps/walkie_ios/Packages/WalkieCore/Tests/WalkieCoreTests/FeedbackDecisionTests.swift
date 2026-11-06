import Foundation
import XCTest
@testable import WalkieCore

final class FeedbackDecisionTests: XCTestCase {
    func testSkippedRatingSurvivesRestartAndExportsWithoutInventingStars() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("Sessions")
        let store = LocalSessionStore(root: root)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let record = try await store.create(route: .demo, at: date)
        do {
            try await store.saveFeedbackSkip(sessionID: record.id, at: date)
            XCTFail("An open walk cannot have a summary decision")
        } catch SessionStorageError.invalidTransition {
            // Expected: declining a rating belongs to a closed summary only.
        } catch { XCTFail("Unexpected error: \(error)") }
        _ = try await store.setState(sessionID: record.id, state: .interrupted,
            at: date.addingTimeInterval(5), productFinishMethod: "interrupted")
        try await store.saveFeedbackSkip(sessionID: record.id, at: date.addingTimeInterval(6))

        let restarted = LocalSessionStore(root: root)
        let files = try await restarted.export(sessionID: record.id, to: folder.appendingPathComponent("Exports"))
        let decisionFile = try XCTUnwrap(files.first { $0.lastPathComponent == "feedback_decision.json" })
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let decision = try decoder.decode(WalkFeedbackDecision.self, from: Data(contentsOf: decisionFile))
        XCTAssertEqual(decision.kind, .skip)
        XCTAssertEqual(decision.sessionID, record.id)
        XCTAssertEqual(decision.at, date.addingTimeInterval(6))
        XCTAssertFalse(files.contains { $0.lastPathComponent == "feedback.json" })
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: decisionFile)) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "skip")
        XCTAssertNil(object["rating"]); XCTAssertNil(object["stars"])
    }
}
