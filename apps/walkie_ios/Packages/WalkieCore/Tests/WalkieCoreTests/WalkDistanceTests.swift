import Foundation
import XCTest
@testable import WalkieCore

final class WalkDistanceTests: XCTestCase {
    private let origin = Coordinate(latitude: 55.75, longitude: 37.61)
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnknownIsNotInventedZeroAndRealStationaryPairMayMeasureZero() {
        var estimate = WalkDistanceAccumulator()
        let segment = UUID()
        XCTAssertNil(estimate.meters)
        estimate.observe(coordinate: origin, accuracy: 5, observedAt: date, receivedAt: date, segmentID: segment)
        XCTAssertNil(estimate.meters)
        estimate.observe(coordinate: origin, accuracy: 5, observedAt: date.addingTimeInterval(2), receivedAt: date.addingTimeInterval(2), segmentID: segment)
        XCTAssertEqual(estimate.meters, 0)
    }

    func testNoBridgeAcrossPauseSegmentStaleSampleOrImpossibleJump() throws {
        var estimate = WalkDistanceAccumulator()
        let segment = UUID()
        let next = Coordinate(latitude: origin.latitude + 0.00002, longitude: origin.longitude)
        estimate.observe(coordinate: origin, accuracy: 5, observedAt: date, receivedAt: date, segmentID: segment)
        estimate.observe(coordinate: next, accuracy: 5, observedAt: date.addingTimeInterval(2), receivedAt: date.addingTimeInterval(2), segmentID: segment)
        let measured = try XCTUnwrap(estimate.meters)
        estimate.resetContinuity()
        estimate.observe(coordinate: .init(latitude: 55.8, longitude: 37.7), accuracy: 5,
            observedAt: date.addingTimeInterval(3), receivedAt: date.addingTimeInterval(3), segmentID: UUID())
        XCTAssertEqual(estimate.meters, measured)
        estimate.observe(coordinate: origin, accuracy: 5, observedAt: date, receivedAt: date.addingTimeInterval(30), segmentID: segment)
        estimate.observe(coordinate: next, accuracy: 5, observedAt: date.addingTimeInterval(31), receivedAt: date.addingTimeInterval(31), segmentID: segment)
        XCTAssertEqual(estimate.meters, measured)
    }

    func testStoreReconstructsEstimateAcrossRestartWithoutBridgingPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalSessionStore(root: root)
        let record = try await store.create(route: .demo, at: date)
        func add(_ offset: Double, _ coordinate: Coordinate) async throws {
            try await store.appendLocation(sessionID: record.id, coordinate: coordinate, horizontalAccuracy: 5,
                observedAt: date.addingTimeInterval(offset), receivedAt: date.addingTimeInterval(offset), monotonicTime: 100 + offset)
        }
        try await add(0, origin)
        try await add(2, Coordinate(latitude: origin.latitude + 0.00002, longitude: origin.longitude))
        let beforePause = try await store.distanceEstimate(sessionID: record.id)
        XCTAssertNotNil(beforePause)
        _ = try await store.setState(sessionID: record.id, state: .paused, at: date.addingTimeInterval(3))
        _ = try await store.setState(sessionID: record.id, state: .recording, at: date.addingTimeInterval(4))
        try await add(5, Coordinate(latitude: 55.8, longitude: 37.7))
        let afterPause = try await store.distanceEstimate(sessionID: record.id)
        XCTAssertEqual(afterPause, beforePause)
        let recovered = try await LocalSessionStore(root: root).distanceEstimate(sessionID: record.id)
        XCTAssertEqual(recovered, beforePause)
    }
}
