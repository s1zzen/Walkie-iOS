import Foundation
import XCTest
@testable import WalkieCore

final class AutomaticVisitDetectorTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private let coordinate = Coordinate(latitude: 55.7, longitude: 37.6)
    private func poi(radius: Double? = 20, dwell: Double? = 4) -> RoutePOI {
        RoutePOI(id: "p1", name: "Место", coordinate: coordinate, visitRadiusMeters: radius, minimumDwellSeconds: dwell)
    }
    private func observe(_ detector: inout AutomaticVisitDetector, time: Double, poi: RoutePOI? = nil,
                         quality: Bool = true, accuracy: Double = 2, delivered: Double? = nil) -> AutomaticVisitEvidence? {
        detector.observe(poi: poi ?? self.poi(), coordinate: coordinate, accuracy: accuracy,
            observedAt: epoch.addingTimeInterval(time), receivedAt: epoch.addingTimeInterval(delivered ?? time),
            monotonicTime: delivered ?? time, qualityAccepted: quality)
    }

    func testContinuousFreshEvidenceProducesVisitWithExactRouteParameters() {
        var detector = AutomaticVisitDetector()
        XCTAssertNil(observe(&detector, time: 0))
        XCTAssertNil(observe(&detector, time: 2))
        let evidence = observe(&detector, time: 4)
        XCTAssertEqual(evidence?.radiusMeters, 20)
        XCTAssertEqual(evidence?.requiredDwellSeconds, 4)
        XCTAssertEqual(evidence?.observedDwellSeconds, 4)
        XCTAssertEqual(evidence?.accuracyMeters, 2)
    }

    func testAbsentRadiusOrDwellNeverUsesAnInventedDefault() {
        for missing in [poi(radius: nil), poi(dwell: nil)] {
            var detector = AutomaticVisitDetector()
            for time in [0.0, 2, 4, 8, 10] { XCTAssertNil(observe(&detector, time: time, poi: missing)) }
        }
    }

    func testQualityRejectionAndUnobservedGapResetDwell() {
        var detector = AutomaticVisitDetector()
        XCTAssertNil(observe(&detector, time: 0))
        XCTAssertNil(observe(&detector, time: 2, quality: false))
        XCTAssertNil(observe(&detector, time: 4))
        XCTAssertNil(observe(&detector, time: 6))
        XCTAssertNotNil(observe(&detector, time: 8))
        XCTAssertNil(observe(&detector, time: 10))
        XCTAssertNil(observe(&detector, time: 100), "Background silence cannot prove continuous presence")
        XCTAssertNil(observe(&detector, time: 102))
        XCTAssertNotNil(observe(&detector, time: 104))
    }

    func testAccuracyRegionMustFitInsideRadiusAndBatchCannotCreateElapsedDwell() {
        var detector = AutomaticVisitDetector()
        for time in [0.0, 2, 4, 8] { XCTAssertNil(observe(&detector, time: time, accuracy: 21)) }
        detector.reset()
        XCTAssertNil(observe(&detector, time: 10, delivered: 14))
        XCTAssertNil(observe(&detector, time: 14, delivered: 14), "Two old fixes delivered together do not prove four seconds of presence")
        detector.reset()
        XCTAssertNil(observe(&detector, time: 20))
        XCTAssertNil(observe(&detector, time: 20), "Duplicate measurement must not count")
    }

    func testStorePreservesAutomaticSourceEvidenceAndIndependentCompletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let route = RoutePlan(id: "v1", routeID: "r1", title: "Test", pois: [poi()],
            legs: [RouteLeg(id: "l1", coordinates: [coordinate, Coordinate(latitude: 55.71, longitude: 37.6)])], isDemo: false)
        let store = LocalSessionStore(root: root)
        let record = try await store.create(route: route, at: epoch)
        let evidence = AutomaticVisitEvidence(radiusMeters: 20, requiredDwellSeconds: 4, observedDwellSeconds: 5,
            accuracyMeters: 2, detectedAt: epoch.addingTimeInterval(5))
        let marked = try await store.markAutomaticallyVisited(sessionID: record.id, poiID: "p1", evidence: evidence)
        XCTAssertTrue(marked.manualVisitedPOIIDs.isEmpty)
        XCTAssertEqual(marked.autoVisitedPOIIDs, ["p1"])
        XCTAssertEqual(marked.visitedPOIIDs, ["p1"])
        _ = try await store.setState(sessionID: record.id, state: .finished, at: epoch.addingTimeInterval(6), productFinishMethod: "all_points")
        let recovered = try await LocalSessionStore(root: root).read(sessionID: record.id)
        XCTAssertEqual(recovered.autoVisitedPOIIDs, ["p1"])
        XCTAssertEqual(recovered.productFinishMethod, "all_points")
        XCTAssertEqual(recovered.completionLabel, "unknown")
        let journal = try Data(contentsOf: root.appendingPathComponent(record.id.uuidString).appendingPathComponent("events.jsonl"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let events = try journal.split(separator: 10).map { try decoder.decode(SessionEvent.self, from: Data($0)) }
        XCTAssertEqual(events.first(where: { $0.kind == .automaticVisit })?.visitEvidence, evidence)
    }
}
