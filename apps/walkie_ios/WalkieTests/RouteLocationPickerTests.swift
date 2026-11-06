import Foundation
import XCTest
import WalkieCore
@testable import Walkie

@MainActor
final class RouteLocationPickerTests: XCTestCase {
    func testDraggedPinUsesMapSourceWithoutRecenteringAndResolvesAddress() async {
        let geocoder = ControlledReverseGeocoder()
        let model = RouteLocationPickerModel(reverseGeocoder: geocoder)
        let point = Coordinate(latitude: 55.75, longitude: 37.62)
        model.selectPin(point)
        XCTAssertEqual(model.coordinate, point)
        XCTAssertEqual(model.source, "map_pin")
        XCTAssertFalse(model.shouldRecenter, "A drag must not reset the user's zoom")
        await geocoder.waitForRequests(1)
        geocoder.finish(0, result: .success("ул. Воздвиженка, 1"))
        await waitUntilResolved(model)
        XCTAssertEqual(model.address, "ул. Воздвиженка, 1")
    }

    func testLateAddressCannotOverwriteNewerPinSelection() async {
        let geocoder = ControlledReverseGeocoder()
        let model = RouteLocationPickerModel(reverseGeocoder: geocoder)
        model.selectPin(.init(latitude: 55.75, longitude: 37.62))
        await geocoder.waitForRequests(1)
        let newer = Coordinate(latitude: 55.76, longitude: 37.63)
        model.selectPin(newer, recenter: true)
        XCTAssertTrue(model.shouldRecenter)
        await geocoder.waitForRequests(2)
        geocoder.finish(1, result: .success("Новый адрес"))
        await waitUntilResolved(model)
        geocoder.finish(0, result: .success("Старый адрес"))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(model.address, "Новый адрес")
        XCTAssertEqual(model.coordinate, newer)
    }

    func testMissingNetworkKeepsChosenCoordinatesAndShowsAddressError() async {
        let geocoder = ControlledReverseGeocoder()
        let model = RouteLocationPickerModel(reverseGeocoder: geocoder)
        let point = Coordinate(latitude: 55.75, longitude: 37.62)
        model.selectPin(point)
        await geocoder.waitForRequests(1)
        geocoder.finish(0, result: .failure(URLError(.notConnectedToInternet)))
        await waitUntilResolved(model)
        XCTAssertEqual(model.coordinate, point)
        XCTAssertNil(model.address)
        XCTAssertNotNil(model.error)
    }

    private func waitUntilResolved(_ model: RouteLocationPickerModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isResolvingAddress, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(model.isResolvingAddress)
    }
}

@MainActor
private final class ControlledReverseGeocoder: RouteReverseGeocoding {
    private var pending: [CheckedContinuation<String?, Error>?] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func address(for coordinate: Coordinate) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            let ready = waiters.filter { pending.count >= $0.0 }
            waiters.removeAll { pending.count >= $0.0 }
            for waiter in ready { waiter.1.resume() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if pending.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func finish(_ index: Int, result: Result<String?, Error>) {
        pending[index]?.resume(with: result)
        pending[index] = nil
    }
}
