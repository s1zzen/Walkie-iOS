import XCTest
import WalkieCore
@testable import Walkie

@MainActor final class ReviewPresentationTests: XCTestCase {
    func testClosedHistoryWalkKeepsItsOwnPlanWhenPlannerHasAnotherPlan() async throws {
        let store = LocalSessionStore(root: temporaryURL())
        let coordinator = WalkSessionCoordinator(store: store, sensors: PresentationSensors())
        let model = WalkViewModel(coordinator: coordinator)
        let a = route("A"), b = route("B")
        await model.start(route: a, kind: .repeat)
        await model.interrupt()
        XCTAssertTrue(model.showsSummary)
        XCTAssertEqual(model.displayedPlan(fallback: b)?.id, "A")
        XCTAssertEqual(model.displayedPlan(fallback: nil)?.id, "A")
        XCTAssertEqual(model.record?.kind, .repeat)
        let skipped = await model.skipRating()
        XCTAssertTrue(skipped)
        XCTAssertTrue(model.summaryDecisionMade)
    }

    func testLastManualVisitClosesWithoutLosingSummary() async throws {
        let model = WalkViewModel(coordinator: WalkSessionCoordinator(store: LocalSessionStore(root: temporaryURL()), sensors: PresentationSensors()))
        let a = route("A")
        await model.start(route: a)
        for poi in a.pois { await model.markVisited(poi) }
        XCTAssertFalse(model.hasOpenSession)
        XCTAssertTrue(model.showsSummary)
        XCTAssertEqual(model.displayedPlan(fallback: route("B"))?.id, "A")
        XCTAssertEqual(model.record?.state, .finished)
    }

    func testConnectivityEventsAreOncePerTransitionAndScopedToWalk() {
        var transitions = WalkConnectivityTransitions()
        let a = UUID(), b = UUID()
        XCTAssertNil(transitions.update(online: false, walkID: nil))
        XCTAssertEqual(transitions.update(online: false, walkID: a), "network_lost")
        XCTAssertNil(transitions.update(online: false, walkID: a))
        XCTAssertEqual(transitions.update(online: true, walkID: a), "network_restored")
        XCTAssertNil(transitions.update(online: true, walkID: a))
        XCTAssertNil(transitions.update(online: true, walkID: b))
        XCTAssertEqual(transitions.update(online: false, walkID: b), "network_lost")
        XCTAssertNil(transitions.update(online: true, walkID: nil))
    }

    func testReleaseTransportPolicyRejectsPlainHTTPBeforeAnyRequest() {
        XCTAssertThrowsError(try BackendClient.validateTransport(URL(string: "http://178.72.149.13/api")!, allowsInsecureHTTP: false))
        XCTAssertNoThrow(try BackendClient.validateTransport(URL(string: "https://example.com/api")!, allowsInsecureHTTP: false))
        XCTAssertThrowsError(try BackendClient.validateTransport(URL(string: "https://secret:password@example.com/api")!, allowsInsecureHTTP: false))
        XCTAssertNoThrow(try BackendClient.validateTransport(URL(string: "http://127.0.0.1/api")!, allowsInsecureHTTP: true))
    }

    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ReviewTests-\(UUID().uuidString)") }
    private func route(_ id: String) -> RoutePlan {
        let demo = RoutePlan.demo
        return .init(id: id, routeID: "route-\(id)", title: id, pois: demo.pois, legs: demo.legs, isDemo: true)
    }
}

@MainActor private final class PresentationSensors: SensorSource {
    var onObservation: ((SensorObservation) -> Void)?
    var onStatus: ((String) -> Void)?
    func start() {}
    func stop() {}
}
