import Foundation
import XCTest
import WalkieCore
@testable import Walkie

@MainActor
final class PlanningViewModelTests: XCTestCase {
    func testConfiguredLongWaitAndCancellationEmitOnceWithExactGenerationIDs() async throws {
        let api = ControlledAPI()
        let model = PlanningViewModel(api: api, cacheURL: try makeCacheURL())
        model.configureGenerationLongWait(seconds: 45)
        let routeID = model.request.requestID, generationID = model.request.generationID
        var events: [(String, [String: String])] = []
        model.onPlanningEvent = { events.append(($0, $1)) }
        let operation = Task { await model.generate() }
        await api.waitForRequestCount(1)
        model.reportGenerationElapsed(44)
        XCTAssertFalse(model.generationLongWaitVisible)
        model.reportGenerationElapsed(45)
        model.reportGenerationElapsed(90)
        XCTAssertTrue(model.generationLongWaitVisible)
        model.cancel(); model.cancel()
        let slow = events.filter { $0.0 == "generation_long_wait_shown" }
        let cancelled = events.filter { $0.0 == "generation_cancelled" }
        XCTAssertEqual(slow.count, 1)
        XCTAssertEqual(cancelled.count, 1)
        for event in slow + cancelled {
            XCTAssertEqual(event.1["route_id"], routeID)
            XCTAssertEqual(event.1["request_id"], generationID)
        }
        await api.succeed(request: 0, with: .demo)
        _ = await operation.value
    }

    func testProfileInterestsAreDeferredUntilWalkFinishesAndLatestUpdateWins() throws {
        let model = PlanningViewModel(api: ImmediateAPI(result: .success(.demo)), cacheURL: try makeCacheURL())
        let original = model.request.interests
        model.updateProfileInterests(["water"], walkIsActive: true)
        model.updateProfileInterests(["parks_nature", "quiet_courtyards"], walkIsActive: true)
        XCTAssertEqual(model.request.interests, original)

        model.walkDidFinish()
        XCTAssertEqual(model.request.interests, ["parks_nature", "quiet_courtyards"])
        model.request.interests = ["architecture_history"]
        model.walkDidFinish()
        XCTAssertEqual(model.request.interests, ["architecture_history"], "Pending interests must be consumed only once")
    }

    func testProfileInterestsApplyImmediatelyWithoutActiveWalkAndClearPendingUpdate() throws {
        let model = PlanningViewModel(api: ImmediateAPI(result: .success(.demo)), cacheURL: try makeCacheURL())
        model.updateProfileInterests(["water"], walkIsActive: true)
        model.updateProfileInterests(["coffee_desserts", "local_shops"], walkIsActive: false)
        XCTAssertEqual(model.request.interests, ["coffee_desserts", "local_shops"])
        model.walkDidFinish()
        XCTAssertEqual(model.request.interests, ["coffee_desserts", "local_shops"])
    }

    func testProductGenerationUsesEditedRequestAndPersistsIt() async throws {
        let cacheURL = try makeCacheURL()
        let api = RequestSpyAPI()
        let model = PlanningViewModel(api: api, cacheURL: cacheURL)
        let request = RouteRequest(
            startArea: "Замоскворечье", durationMinutes: 45,
            mood: "Новые впечатления", interests: ["water"], finishAtStart: true
        )
        model.request = request
        let succeeded = await model.generate()

        let received = await api.lastRequest
        XCTAssertEqual(received, request)
        XCTAssertTrue(succeeded)
        let plan = try XCTUnwrap(model.plan)
        XCTAssertEqual(plan, try DemoRouteCatalog.route(for: request))
        XCTAssertEqual(plan.start, plan.end)
        XCTAssertTrue(plan.isDemo)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try JSONDecoder().decode(RoutePlan.self, from: Data(contentsOf: cacheURL)), plan)
    }

    func testSavedRouteSelectionIsValidatedAndCached() async throws {
        let cacheURL = try makeCacheURL()
        let model = PlanningViewModel(api: ImmediateAPI(result: .failure(TestFailure.offline)), cacheURL: cacheURL)
        let saved = try DemoRouteCatalog.route(for: RouteRequest(startArea: "Замоскворечье"))
        let succeeded = await model.selectSavedRoute(saved)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.plan, saved)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try JSONDecoder().decode(RoutePlan.self, from: Data(contentsOf: cacheURL)), saved)
    }

    func testInvalidRequestPreservesPreviousPlanAndDoesNotCallAPI() async throws {
        let cacheURL = try makeCacheURL()
        let api = RequestSpyAPI()
        let model = PlanningViewModel(api: api, cacheURL: cacheURL)
        await model.selectSavedRoute(.demo)
        let previousData = try Data(contentsOf: cacheURL)
        model.request.durationMinutes = 0
        let succeeded = await model.generate()

        let received = await api.lastRequest
        XCTAssertNil(received)
        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.plan?.id, RoutePlan.demo.id)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(try Data(contentsOf: cacheURL), previousData)
    }

    func testFixtureAreaChangesPlacesAndGeometry() throws {
        let ponds = try DemoRouteCatalog.route(for: RouteRequest())
        let zamoskvorechye = try DemoRouteCatalog.route(for: RouteRequest(startArea: "Замоскворечье"))
        XCTAssertNotEqual(ponds.start, zamoskvorechye.start)
        XCTAssertTrue(Set(ponds.pois.map(\.id)).isDisjoint(with: zamoskvorechye.pois.map(\.id)))
        try ponds.validate()
        try zamoskvorechye.validate()
        XCTAssertTrue(ponds.approximateDistanceMeters > 0)
        XCTAssertTrue(ponds.estimatedMinutes > 0)
    }

    func testCancelledProductGenerationReportsFalseWithPreviousPlanRetained() async throws {
        let cacheURL = try makeCacheURL()
        let api = ControlledAPI()
        let model = PlanningViewModel(api: api, cacheURL: cacheURL)
        await model.selectSavedRoute(.demo)
        let generation = Task { await model.generate() }
        await api.waitForRequestCount(1)
        model.cancel()
        await api.succeed(request: 0, with: renamedDemo("cancelled-product"))
        let succeeded = await generation.value
        XCTAssertFalse(succeeded)
        XCTAssertEqual(model.plan?.id, RoutePlan.demo.id)
        XCTAssertNil(model.errorMessage)
    }

    func testCommitPhaseFinishesDespiteCancelAndRejectsCompetingIntent() async throws {
        let cache = ControlledCommitCache(initial: .demo)
        let next = renamedDemo("accepted-commit")
        let model = PlanningViewModel(api: ImmediateAPI(result: .success(next)), cache: cache)
        model.loadCachedPlan()
        await waitUntilLoaded(model)

        let generation = Task { await model.generate() }
        await cache.waitForSave()
        XCTAssertTrue(model.isCommitting)
        model.cancel()
        XCTAssertTrue(model.isLoading, "An accepted durable write must not be reported as cancelled")
        let competing = await model.selectSavedRoute(renamedDemo("rejected-competing-intent"))
        XCTAssertFalse(competing)
        XCTAssertEqual(model.plan?.id, RoutePlan.demo.id)

        await cache.finishSave()
        let succeeded = await generation.value
        let stored = await cache.stored
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.plan?.id, next.id)
        XCTAssertEqual(stored?.id, next.id)
        XCTAssertFalse(model.isCommitting)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    func testTaskCancellationAfterAcceptedWriteDoesNotDivergePublishedAndCachedPlans() async throws {
        let cache = ControlledCommitCache(initial: .demo)
        let next = renamedDemo("durable-before-late-task-cancel")
        let model = PlanningViewModel(api: ImmediateAPI(result: .success(next)), cache: cache)
        let generation = Task { await model.generate() }
        await cache.waitForSave()
        generation.cancel()
        await cache.finishSave()
        let succeeded = await generation.value
        let stored = await cache.stored
        XCTAssertTrue(succeeded)
        XCTAssertEqual(model.plan, stored)
        XCTAssertEqual(model.plan?.id, next.id)
        XCTAssertFalse(model.isCommitting)
    }

    func testFixtureTimeAndInterestsAffectStopSelection() throws {
        let short = try DemoRouteCatalog.route(for: RouteRequest(durationMinutes: 30, interests: ["architecture_history"]))
        let long = try DemoRouteCatalog.route(for: RouteRequest(durationMinutes: 120, interests: ["architecture_history"]))
        let water = try DemoRouteCatalog.route(for: RouteRequest(durationMinutes: 30, interests: ["water"]))
        XCTAssertLessThan(short.pois.count, long.pois.count)
        XCTAssertNotEqual(short.pois.map(\.id), water.pois.map(\.id))
        XCTAssertTrue(water.pois.contains { $0.id == "ponds-water" })
        XCTAssertEqual(short, try DemoRouteCatalog.route(for: RouteRequest(durationMinutes: 30, interests: ["architecture_history"])))
    }

    func testFixtureLoopEndsAtStartAndAddsALeg() throws {
        let open = try DemoRouteCatalog.route(for: RouteRequest())
        let loop = try DemoRouteCatalog.route(for: RouteRequest(finishAtStart: true))
        XCTAssertEqual(loop.start, loop.end)
        XCTAssertEqual(loop.legs.last?.coordinates.last, loop.start)
        XCTAssertEqual(loop.legs.count, open.legs.count + 1)
        XCTAssertGreaterThan(loop.approximateDistanceMeters, open.approximateDistanceMeters)
    }

    func testFixtureRejectsUnknownOrIncompleteRequests() {
        XCTAssertThrowsError(try DemoRouteCatalog.route(for: RouteRequest(startArea: "unknown")))
        XCTAssertThrowsError(try DemoRouteCatalog.route(for: RouteRequest(durationMinutes: 241)))
        XCTAssertThrowsError(try DemoRouteCatalog.route(for: RouteRequest(mood: "unknown")))
        XCTAssertThrowsError(try DemoRouteCatalog.route(for: RouteRequest(interests: [])))
        XCTAssertThrowsError(try DemoRouteCatalog.route(for: RouteRequest(interests: ["unknown"])))
        XCTAssertThrowsError(try DemoRouteCatalog.route(for: RouteRequest(interests: ["water", "water"])))
    }

    func testGeneratedPlanIsPersistedAndRestoredAfterFreshLaunch() async throws {
        let cacheURL = try makeCacheURL()
        let api = ImmediateAPI(result: .success(.demo))
        let original = PlanningViewModel(api: api, cacheURL: cacheURL)
        await original.generateDemo()
        XCTAssertEqual(original.plan?.id, RoutePlan.demo.id)
        XCTAssertNil(original.errorMessage)
        XCTAssertFalse(original.isLoading)

        let restored = PlanningViewModel(api: api, cacheURL: cacheURL)
        restored.loadCachedPlan()
        await waitUntilLoaded(restored)
        XCTAssertEqual(restored.plan?.id, RoutePlan.demo.id)
        XCTAssertNil(restored.errorMessage)
    }

    func testMissingCacheIsNotAnError() async throws {
        let cacheURL = try makeCacheURL()
        let model = PlanningViewModel(api: ImmediateAPI(result: .success(.demo)), cacheURL: cacheURL)
        model.loadCachedPlan()
        await waitUntilLoaded(model)
        XCTAssertNil(model.plan)
        XCTAssertNil(model.errorMessage)
    }

    func testCorruptCacheRemainsIntactAndShowsRecoveryError() async throws {
        let cacheURL = try makeCacheURL()
        let corrupt = Data("not valid JSON".utf8)
        try corrupt.write(to: cacheURL)
        let model = PlanningViewModel(api: ImmediateAPI(result: .success(.demo)), cacheURL: cacheURL)
        model.loadCachedPlan()
        await waitUntilLoaded(model)
        XCTAssertNil(model.plan)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: cacheURL), corrupt)
    }

    func testFailedRequestDoesNotReplaceLastPlanOrCache() async throws {
        let cacheURL = try makeCacheURL()
        try JSONEncoder().encode(RoutePlan.demo).write(to: cacheURL)
        let previousData = try Data(contentsOf: cacheURL)
        let model = PlanningViewModel(api: ImmediateAPI(result: .failure(TestFailure.offline)), cacheURL: cacheURL)
        model.loadCachedPlan()
        await waitUntilLoaded(model)
        await model.generateDemo()
        XCTAssertEqual(model.plan?.id, RoutePlan.demo.id)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: cacheURL), previousData)
    }

    func testInvalidRouteDoesNotReplaceLastPlanOrCache() async throws {
        let cacheURL = try makeCacheURL()
        try JSONEncoder().encode(RoutePlan.demo).write(to: cacheURL)
        let previousData = try Data(contentsOf: cacheURL)
        let invalid = RoutePlan(id: "invalid", routeID: "invalid", title: "", pois: [], legs: [], isDemo: true)
        let model = PlanningViewModel(api: ImmediateAPI(result: .success(invalid)), cacheURL: cacheURL)
        model.loadCachedPlan()
        await waitUntilLoaded(model)
        await model.generateDemo()
        XCTAssertEqual(model.plan?.id, RoutePlan.demo.id)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: cacheURL), previousData)
    }

    func testWriteFailureDoesNotPublishUnsavedPlan() async throws {
        let cacheURL = try makeCacheURL()
        let notADirectory = cacheURL.deletingLastPathComponent().appendingPathComponent("regular-file")
        try Data("block parent directory".utf8).write(to: notADirectory)
        let model = PlanningViewModel(
            api: ImmediateAPI(result: .success(.demo)),
            cacheURL: notADirectory.appendingPathComponent("plan.json")
        )
        await model.generateDemo()
        XCTAssertNil(model.plan)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.isCommitting)
    }

    func testCancelledUncooperativeResponseCannotChangePlanOrCache() async throws {
        let cacheURL = try makeCacheURL()
        try JSONEncoder().encode(RoutePlan.demo).write(to: cacheURL)
        let previousData = try Data(contentsOf: cacheURL)
        let api = ControlledAPI()
        let model = PlanningViewModel(api: api, cacheURL: cacheURL)
        model.loadCachedPlan()
        await waitUntilLoaded(model)
        let generation = Task { await model.generateDemo() }
        await api.waitForRequestCount(1)
        model.cancel()
        XCTAssertFalse(model.isLoading)
        await api.succeed(request: 0, with: renamedDemo("cancelled"))
        await generation.value
        XCTAssertEqual(model.plan?.id, RoutePlan.demo.id)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try Data(contentsOf: cacheURL), previousData)
    }

    func testOlderResponseCannotOverwriteNewerIntent() async throws {
        let cacheURL = try makeCacheURL()
        let api = ControlledAPI()
        let model = PlanningViewModel(api: api, cacheURL: cacheURL)
        let first = Task { await model.generateDemo() }
        await api.waitForRequestCount(1)
        let second = Task { await model.generateDemo() }
        await api.waitForRequestCount(2)
        await api.succeed(request: 1, with: renamedDemo("newest"))
        await second.value
        await api.succeed(request: 0, with: renamedDemo("stale"))
        await first.value
        XCTAssertEqual(model.plan?.id, "newest")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
        let saved = try JSONDecoder().decode(RoutePlan.self, from: Data(contentsOf: cacheURL))
        XCTAssertEqual(saved.id, "newest")
    }

    private func renamedDemo(_ id: String) -> RoutePlan {
        let demo = RoutePlan.demo
        return RoutePlan(id: id, routeID: demo.routeID, title: demo.title, pois: demo.pois, legs: demo.legs, isDemo: true)
    }

    private func makeCacheURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WalkiePlanningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("plan.json")
    }

    private func waitUntilLoaded(_ model: PlanningViewModel) async {
        // Cache IO runs on its own actor; bounded polling avoids fixed sleeps.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while model.isLoading, ContinuousClock.now < deadline {
            await Task.yield()
        }
        XCTAssertFalse(model.isLoading, "Cache loading did not complete")
    }
}

private enum TestFailure: Error, Sendable { case offline }

private actor RequestSpyAPI: CoreAPI {
    private(set) var lastRequest: RouteRequest?
    func generateDemoRoute() async throws -> RoutePlan { .demo }
    func generateRoute(request: RouteRequest) async throws -> RoutePlan {
        lastRequest = request
        return try DemoRouteCatalog.route(for: request)
    }
}

/// Suspends inside the accepted save phase. Like an atomic write that has
/// already started, it does not promise cancellation or rollback.
private actor ControlledCommitCache: RoutePlanCaching {
    private(set) var stored: RoutePlan?
    private var saveGate: CheckedContinuation<Void, Never>?
    private var saveStarted = false
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []

    init(initial: RoutePlan?) { stored = initial }

    func load() -> RoutePlan? { stored }

    func save(_ plan: RoutePlan) async throws {
        try plan.validate()
        saveStarted = true
        let waiters = saveWaiters
        saveWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { saveGate = $0 }
        stored = plan
    }

    func waitForSave() async {
        guard !saveStarted else { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    func finishSave() {
        saveGate?.resume()
        saveGate = nil
    }
}

private struct ImmediateAPI: CoreAPI {
    let result: Result<RoutePlan, TestFailure>
    func generateDemoRoute() async throws -> RoutePlan { try result.get() }
}

/// Deliberately ignores Task cancellation to exercise late-response defenses.
private actor ControlledAPI: CoreAPI {
    private var pending: [CheckedContinuation<RoutePlan, Error>?] = []
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func generateDemoRoute() async throws -> RoutePlan {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            let ready = arrivalWaiters.filter { pending.count >= $0.count }
            arrivalWaiters.removeAll { pending.count >= $0.count }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func waitForRequestCount(_ count: Int) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append((count, continuation))
        }
    }

    func succeed(request index: Int, with plan: RoutePlan) {
        let continuation = pending[index]
        pending[index] = nil
        continuation?.resume(returning: plan)
    }
}
