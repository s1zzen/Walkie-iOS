import Foundation
import XCTest
@testable import FieldLabCore

final class DetectorTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let metersPerDegree = 111_195.0802

    private func point(_ x: Double, _ y: Double = 0) -> GeoPoint {
        GeoPoint(latitude: y / metersPerDegree, longitude: x / metersPerDegree)
    }

    private func route() -> TestRoute {
        TestRoute(name: "Test route", source: "test", segments: [[point(-1_000), point(1_000)]])
    }

    private func sample(_ t: Double, x: Double = 0, y: Double = 0, accuracy: Double = 5) -> LocationSample {
        let p = point(x, y)
        return LocationSample(elapsed: t, observedAt: epoch.addingTimeInterval(t), receivedAt: epoch.addingTimeInterval(t),
                              latitude: p.latitude, longitude: p.longitude, horizontalAccuracy: accuracy)
    }

    private func run(_ engine: DetectorEngine, t: Double, x: Double = 0, y: Double = 0,
                     accuracy: Double = 5, steps: Int? = nil, stepStamp: Double? = nil) -> [AlgorithmResult] {
        let motion = MotionSnapshot(elapsed: t, steps: steps, pedometerUpdatedAt: stepStamp)
        return engine.update(elapsed: t, location: sample(t, x: x, y: y, accuracy: accuracy), motion: motion)
    }

    private func engine(configuration: DetectorConfiguration = DetectorConfiguration()) -> DetectorEngine {
        DetectorEngine(route: route(), configuration: configuration)
    }

    func testCleanWalkHasNoAlerts() {
        let detector = engine()
        var results: [AlgorithmResult] = []
        for t in stride(from: 0.0, through: 40.0, by: 2.0) {
            results += run(detector, t: t, x: t * 1.4, y: sin(t) * 4)
        }
        XCTAssertFalse(results.contains(where: \.alert))
        XCTAssertEqual(Array(results.suffix(2)).map(\.state), [.onRoute, .onRoute])
    }

    func testHeartbeatCannotConfirmSingleOffRouteFix() {
        let detector = engine()
        _ = run(detector, t: 0, y: 60)
        for t in 1...9 {
            let results = detector.update(elapsed: Double(t), location: nil, motion: .empty(at: Double(t)))
            XCTAssertEqual(results.map(\.state), [.uncertain, .uncertain])
            XCTAssertFalse(results.contains(where: \.alert))
        }
    }

    func testColdStartFarAwayIsNotSilentlyOnRoute() {
        let detector = engine()
        XCTAssertEqual(run(detector, t: 0, y: 500).map(\.state), [.uncertain, .uncertain])
        _ = run(detector, t: 2, y: 500)
        let result = run(detector, t: 4, y: 500)
        XCTAssertEqual(result.map(\.state), [.offRoute, .offRoute])
        XCTAssertEqual(result.map(\.alert), [true, true])
    }

    func testAlertIsOneShotAndHysteresisWorks() {
        let detector = engine()
        for t in [0.0, 2, 4] { _ = run(detector, t: t) }
        _ = run(detector, t: 6, y: 30)
        _ = run(detector, t: 8, y: 30)
        XCTAssertEqual(run(detector, t: 10, y: 30).map(\.alert), [true, true])
        XCTAssertEqual(run(detector, t: 12, y: 20).map(\.state), [.offRoute, .offRoute])
        XCTAssertEqual(run(detector, t: 14, y: 20).map(\.alert), [false, false])
        for t in [16.0, 18, 20] { _ = run(detector, t: t) }
        XCTAssertEqual(run(detector, t: 22).map(\.state), [.onRoute, .onRoute])
        for t in [24.0, 26] { _ = run(detector, t: t, y: 30) }
        XCTAssertEqual(run(detector, t: 28, y: 30).map(\.alert), [true, true])
    }

    func testGoodReportedAccuracyDoesNotHideAbruptJump() {
        let detector = engine()
        for t in [0.0, 2, 4] { _ = run(detector, t: t, accuracy: 3) }
        let result = run(detector, t: 6, y: 500, accuracy: 3)
        XCTAssertEqual(result[1].state, .uncertain)
        XCTAssertTrue(result[1].suspiciousLocation)
        XCTAssertFalse(result[1].alert)
        for t in [8.0, 10] { _ = run(detector, t: t, y: 500, accuracy: 3) }
        let heartbeat = detector.update(elapsed: 11, location: nil, motion: .empty(at: 11))
        XCTAssertEqual(heartbeat[0].state, .offRoute)
        XCTAssertEqual(heartbeat[1].state, .uncertain)
    }

    func testPersistentNewClusterCanRecoverInsteadOfRejectingForever() {
        let detector = engine()
        for t in [0.0, 2, 4] { _ = run(detector, t: t) }
        for t in stride(from: 6.0, through: 24.0, by: 2.0) {
            XCTAssertEqual(run(detector, t: t, y: 500)[1].state, .uncertain)
        }
        XCTAssertEqual(run(detector, t: 26, y: 500)[1].state, .uncertain)
        XCTAssertEqual(run(detector, t: 28, y: 500)[1].state, .uncertain)
        let result = run(detector, t: 30, y: 500)
        XCTAssertEqual(result[1].state, .offRoute)
        XCTAssertTrue(result[1].alert)
        XCTAssertFalse(result[1].suspiciousLocation)
    }

    func testReturnFromSingleOutlierDoesNotRaiseGuardedAlert() {
        let detector = engine()
        for t in [0.0, 2, 4] { _ = run(detector, t: t) }
        XCTAssertTrue(run(detector, t: 6, y: 500)[1].suspiciousLocation)
        let result = run(detector, t: 8)
        XCTAssertEqual(result[1].state, .onRoute)
        XCTAssertFalse(result[1].alert)
    }

    func testStaleHeartbeatAndGapResetConfirmation() {
        let detector = engine()
        for t in [0.0, 2, 4] { _ = run(detector, t: t) }
        XCTAssertEqual(detector.update(elapsed: 14, location: nil, motion: .empty(at: 14)).map(\.state), [.onRoute, .onRoute])
        XCTAssertEqual(detector.update(elapsed: 15, location: nil, motion: .empty(at: 15)).map(\.state), [.uncertain, .uncertain])
        _ = detector.update(elapsed: 21, location: nil, motion: .empty(at: 21))
        XCTAssertEqual(run(detector, t: 22, y: 50).map(\.state), [.uncertain, .uncertain])
        XCTAssertEqual(run(detector, t: 26, y: 50).map(\.state), [.offRoute, .offRoute])
    }

    func testDelayedFixExpiresAccordingToMeasurementAge() {
        let detector = engine()
        var fix = sample(0)
        fix.elapsed = 8
        fix.receivedAt = epoch.addingTimeInterval(8)
        _ = detector.update(elapsed: 8, location: fix, motion: .empty(at: 8))
        let result = detector.update(elapsed: 11, location: nil, motion: .empty(at: 11))
        XCTAssertEqual(result.map(\.state), [.uncertain, .uncertain])
        XCTAssertTrue(result.allSatisfy { $0.reason.contains("свеж") })
    }

    func testDuplicateAndOutOfOrderFixesCannotConfirm() {
        let detector = engine()
        _ = run(detector, t: 0, y: 60)
        let duplicate = detector.update(elapsed: 5, location: sample(0, y: 60), motion: .empty(at: 5))
        XCTAssertEqual(duplicate.map(\.state), [.uncertain, .uncertain])
        var older = sample(6, y: 60)
        older.observedAt = epoch.addingTimeInterval(-1)
        XCTAssertEqual(detector.update(elapsed: 6, location: older, motion: .empty(at: 6)).map(\.state), [.uncertain, .uncertain])
    }

    func testBatchWithSameReceiveElapsedUsesDistinctObservationTimes() {
        let detector = engine()
        var result: [AlgorithmResult] = []
        for t in [0.0, 2, 4] {
            var fix = sample(t, y: 60)
            fix.elapsed = 5
            fix.receivedAt = epoch.addingTimeInterval(5)
            result = detector.update(elapsed: 5, location: fix, motion: .empty(at: 5))
        }
        XCTAssertEqual(result.map(\.state), [.offRoute, .offRoute])
        XCTAssertEqual(result.map(\.alert), [true, true])
    }

    func testPoorAccuracyMakesOnlyGuardedAbstain() {
        let detector = engine()
        for t in [0.0, 2, 4] { _ = run(detector, t: t, y: 60, accuracy: 80) }
        let result = run(detector, t: 6, y: 60, accuracy: 80)
        XCTAssertEqual(result.map(\.state), [.offRoute, .uncertain])
    }

    func testGradualConfidentDriftIsNotClaimedDetectableWithoutIndependentEvidence() {
        let detector = engine()
        var result: [AlgorithmResult] = []
        for t in stride(from: 0.0, through: 40.0, by: 2.0) {
            result = run(detector, t: t, y: t * 1.0, accuracy: 3)
        }
        // Медленная подмена неотличима от реального ухода по одним координатам.
        XCTAssertEqual(result.map(\.state), [.offRoute, .offRoute])
        XCTAssertFalse(result[1].suspiciousLocation)
    }

    func testFreshSequentialZeroStepsCanFlagContradiction() {
        let detector = engine()
        var suspicious = false
        for t in stride(from: 0.0, through: 20.0, by: 2.0) {
            let result = run(detector, t: t, y: t * 2, accuracy: 3, steps: 0, stepStamp: t)
            suspicious = suspicious || result[1].suspiciousLocation
        }
        XCTAssertTrue(suspicious)
    }

    func testStaleOrSinglePedometerReadingCannotAssertStationary() {
        for useStaleTimestamp in [true, false] {
            let detector = engine()
            var results: [AlgorithmResult] = []
            for t in stride(from: 0.0, through: 30.0, by: 2.0) {
                let steps: Int? = useStaleTimestamp || t == 0 ? 0 : nil
                results += run(detector, t: t, y: t * 2, accuracy: 3, steps: steps, stepStamp: 0)
            }
            XCTAssertFalse(results.filter { $0.algorithm == "guarded_v1" }.contains(where: \.suspiciousLocation))
            XCTAssertEqual(results.last?.state, .offRoute)
        }
    }

    func testResetStepCounterIsNotNegativeDistanceOrCrash() {
        let detector = engine()
        _ = run(detector, t: 0, steps: 100, stepStamp: 0)
        let result = run(detector, t: 2, x: 3, steps: 0, stepStamp: 2)
        XCTAssertFalse(result[1].suspiciousLocation)
    }

    func testRouteSegmentsNeverBridgeGPXGap() {
        let split = TestRoute(name: "Gap", source: "test", segments: [[point(0), point(100)], [point(300), point(400)]])
        XCTAssertEqual(RouteGeometry.distance(from: point(200), to: split), 100, accuracy: 0.01)
        XCTAssertEqual(RouteGeometry.distance(from: point(50, 12), to: split), 12, accuracy: 0.01)
    }

    func testDistanceCrossingInternationalDateLine() {
        let split = TestRoute(name: "Date line", source: "test", segments: [[GeoPoint(latitude: 0, longitude: 179.99), GeoPoint(latitude: 0, longitude: -179.99)]])
        XCTAssertLessThan(RouteGeometry.distance(from: GeoPoint(latitude: 0, longitude: 180), to: split), 0.01)
        XCTAssertEqual(RouteGeometry.distance(from: GeoPoint(latitude: 0.001, longitude: 180), to: split), 111.195, accuracy: 0.01)
    }

    func testNonfiniteInputsAndInvalidRouteDoNotCrash() {
        let detector = engine()
        _ = detector.update(elapsed: .nan, location: nil, motion: .empty(at: .nan))
        var invalid = sample(0)
        invalid.latitude = .infinity
        XCTAssertEqual(detector.update(elapsed: 0, location: invalid, motion: .empty(at: 0)).map(\.state), [.uncertain, .uncertain])
        _ = run(detector, t: 4)
        XCTAssertFalse(detector.update(elapsed: 1, location: sample(1), motion: .empty(at: 1)).contains(where: \.alert))
        let empty = DetectorEngine(route: TestRoute(name: "Empty", source: "test", segments: []), configuration: DetectorConfiguration())
        XCTAssertEqual(run(empty, t: 0).map(\.state), [.uncertain, .uncertain])
    }

    func testReplayIsDeterministicAndPrefixCausal() throws {
        let first = engine()
        let second = engine()
        var prefixA: [AlgorithmResult] = []
        var prefixB: [AlgorithmResult] = []
        for t in stride(from: 0.0, through: 20.0, by: 2.0) {
            prefixA += run(first, t: t, y: t > 6 ? 50 : 0)
            prefixB += run(second, t: t, y: t > 6 ? 50 : 0)
        }
        for t in stride(from: 22.0, through: 40.0, by: 2.0) { _ = run(first, t: t, y: 800) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(prefixA), try encoder.encode(prefixB))
    }
}
