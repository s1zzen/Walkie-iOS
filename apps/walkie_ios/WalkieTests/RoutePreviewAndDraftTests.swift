import Foundation
import XCTest
import WalkieCore
@testable import Walkie

@MainActor
final class RoutePreviewAndDraftTests: XCTestCase {
    func testHistoryAlternativeTargetsDisplayedAAndDoesNotReplacePlannerB() async throws {
        let api = PreviewSpyAPI()
        let cache = RoutePlanCache(url: temporaryURL())
        let planning = PlanningViewModel(api: api, cache: cache)
        let b = plan("B", route: "route-B")
        let selected = await planning.selectSavedRoute(b)
        XCTAssertTrue(selected)
        let preview = planning.previewModel(for: plan("A", route: "route-A"))
        let succeeded = await preview.alternative()
        XCTAssertTrue(succeeded)
        XCTAssertEqual(preview.plan.id, "A-alternative")
        XCTAssertEqual(preview.plan.routeID, "route-A")
        XCTAssertEqual(planning.plan?.id, "B")
        let targets = await api.targets
        XCTAssertEqual(targets, ["A"])
    }

    func testHistoryCorrectionTargetsDisplayedVersionWithoutAnyPlannerPlan() async throws {
        let api = PreviewSpyAPI()
        let planning = PlanningViewModel(api: api, cache: RoutePlanCache(url: temporaryURL()))
        let preview = planning.previewModel(for: plan("A", route: "route-A"))
        let correction = try await preview.parseCorrection("больше парков")
        let succeeded = await preview.applyCorrection(correction)
        XCTAssertTrue(succeeded)
        XCTAssertEqual(preview.plan.id, "A-corrected")
        XCTAssertNil(planning.plan)
        let targets = await api.targets
        XCTAssertEqual(targets, ["A", "A"])
    }

    func testPreviewReplacementSurvivesRecreationAndNextIntentUsesRestoredVersion() async throws {
        let url = temporaryURL()
        let api = PreviewSpyAPI(persistedPreviewURL: url)
        let original = plan("A", route: "route-A")
        let first = RoutePreviewViewModel(plan: original, api: api, store: RoutePreviewStore(url: url))
        let replaced = await first.alternative()
        XCTAssertTrue(replaced)
        let persistedAtACK = await api.persistedAtAcknowledgement
        XCTAssertEqual(persistedAtACK, [true])

        let recreated = RoutePreviewViewModel(plan: original, api: api, store: RoutePreviewStore(url: url))
        let restored = await recreated.loadIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertEqual(recreated.plan.id, "A-alternative")
        let next = await recreated.alternative()
        XCTAssertTrue(next)
        let targets = await api.targets
        XCTAssertEqual(targets, ["A", "A-alternative"])

        let reopened = RoutePreviewViewModel(plan: original, api: api, store: RoutePreviewStore(url: url))
        let reopenedRestored = await reopened.loadIfNeeded()
        XCTAssertTrue(reopenedRestored)
        XCTAssertEqual(reopened.plan.id, "A-alternative-alternative")
    }

    func testCorruptPreviewCacheIsVisibleAndNeverOverwrittenOrAcknowledged() async throws {
        let url = temporaryURL()
        let original = Data("broken preview".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: url)
        let api = PreviewSpyAPI(persistedPreviewURL: url)
        let preview = RoutePreviewViewModel(plan: plan("A", route: "route-A"), api: api, store: RoutePreviewStore(url: url))
        let restored = await preview.loadIfNeeded()
        XCTAssertFalse(restored)
        XCTAssertNotNil(preview.errorMessage)
        let replaced = await preview.alternative()
        XCTAssertFalse(replaced)
        let targets = await api.targets, acknowledgements = await api.persistedAtAcknowledgement
        XCTAssertTrue(targets.isEmpty)
        XCTAssertTrue(acknowledgements.isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testSharedPreviewStoreRestoresHistoryAWithoutChangingPlannerB() async throws {
        let url = temporaryURL()
        let api = PreviewSpyAPI()
        let planning = PlanningViewModel(api: api, cache: RoutePlanCache(url: temporaryURL()), previewURL: url)
        let selected = await planning.selectSavedRoute(plan("B", route: "route-B"))
        XCTAssertTrue(selected)
        let original = plan("A", route: "route-A")
        let changed = await planning.previewModel(for: original).alternative()
        XCTAssertTrue(changed)
        let reopened = planning.previewModel(for: original)
        let restored = await reopened.loadIfNeeded()
        XCTAssertTrue(restored)
        XCTAssertEqual(reopened.plan.id, "A-alternative")
        XCTAssertEqual(planning.plan?.id, "B")
    }

    func testExplicitRepeatKeepsHistoricalVersionDespitePreviousPreviewEdits() async throws {
        let api = PreviewSpyAPI()
        let planning = PlanningViewModel(api: api, cache: RoutePlanCache(url: temporaryURL()), previewURL: temporaryURL())
        let original = plan("A", route: "route-A")
        let edited = await planning.previewModel(for: original).alternative()
        XCTAssertTrue(edited)

        let repeatCard = planning.previewModel(for: original, restoration: .exactVersion)
        let loaded = await repeatCard.loadIfNeeded()
        XCTAssertTrue(loaded)
        XCTAssertEqual(repeatCard.plan.id, "A")

        // An explicit edit in this new card still targets the displayed A.
        let correction = try await repeatCard.parseCorrection("больше парков")
        let corrected = await repeatCard.applyCorrection(correction)
        XCTAssertTrue(corrected)
        XCTAssertEqual(repeatCard.plan.id, "A-corrected")
        let targets = await api.targets
        XCTAssertEqual(targets, ["A", "A", "A"])
        let reopenedRepeat = planning.previewModel(for: original, restoration: .exactVersion)
        let reloaded = await reopenedRepeat.loadIfNeeded()
        XCTAssertTrue(reloaded)
        XCTAssertEqual(reopenedRepeat.plan.id, "A")
    }

    func testDraftStoreRejectsLateOlderRevision() async throws {
        let url = temporaryURL()
        let store = RouteDraftStore(url: url)
        var older = RouteBuilderDraft(request: RouteRequest(), step: .origin, branch: .c0)
        var newer = older
        older.request.context.phrase = "old"
        newer.request.context.phrase = "new"
        try await store.save(newer, revision: 2)
        try await store.save(older, revision: 1)
        let restored = try await RouteDraftStore(url: url).load()
        XCTAssertEqual(restored?.request.context.phrase, "new")
    }

    func testCorruptDraftCannotBeSilentlyOverwritten() async throws {
        let url = temporaryURL()
        let original = Data("broken draft".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: url)
        let store = RouteDraftStore(url: url)
        do { try await store.save(.init(request: .init(), step: .origin, branch: .c0), revision: 1); XCTFail("Overwrote corruption") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testExplicitNewOrRestartArchivesCorruptDraftAndAllowsLatestInputToPersist() async throws {
        for restart in [false, true] {
            let url = temporaryURL()
            let original = Data("broken draft".utf8)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try original.write(to: url)
            let model = PlanningViewModel(api: MockCoreAPI(), cache: RoutePlanCache(url: temporaryURL()), draftURL: url)
            await model.loadDraftIfNeeded()
            XCTAssertNotNil(model.draftError)
            if restart { model.restartDraft() } else { model.startNewDraft() }
            model.request.context.phrase = "новый парк"
            let flushed = await model.flushDraft()
            XCTAssertTrue(flushed)
            XCTAssertNil(model.draftError)
            let restored = try await RouteDraftStore(url: url).load()
            XCTAssertEqual(restored?.request.context.phrase, "новый парк")
            let archives = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.contains(".corrupt-") }
            XCTAssertEqual(archives.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archives.first)), original)
        }
    }

    func testExplicitFlushStoresLatestTypedPhraseBeforeTransition() async throws {
        let url = temporaryURL()
        let model = PlanningViewModel(api: MockCoreAPI(), cache: RoutePlanCache(url: temporaryURL()), draftURL: url)
        model.startNewDraft()
        for value in ["п", "па", "парк"] { model.request.context.phrase = value }
        let flushed = await model.flushDraft()
        XCTAssertTrue(flushed)
        let restored = PlanningViewModel(api: MockCoreAPI(), cache: RoutePlanCache(url: temporaryURL()), draftURL: url)
        await restored.loadDraftIfNeeded()
        XCTAssertEqual(restored.request.context.phrase, "парк")
    }

    func testRestartDraftCreatesNewWalkAndParameterChangeLinksToServerRoute() {
        let model = PlanningViewModel(api: MockCoreAPI(), cache: RoutePlanCache(url: temporaryURL()))
        model.startNewDraft()
        let previous = model.request.requestID
        model.restartDraft()
        XCTAssertEqual(model.request.creationOrigin, .newWalk)
        XCTAssertNil(model.request.previousRouteID)
        XCTAssertNotEqual(model.request.requestID, previous)
        model.startParametersChange(from: plan("version-A", route: "route-A"))
        XCTAssertEqual(model.request.creationOrigin, .paramsChange)
        XCTAssertEqual(model.request.previousRouteID, "route-A")
    }

    func testLegacyRestartIsRepairedBeforePreparingContext() async {
        let model = PlanningViewModel(api: MockCoreAPI(), cache: RoutePlanCache(url: temporaryURL()))
        model.startNewDraft()
        let oldID = model.request.requestID
        model.request.creationOrigin = .restart
        model.request.previousRouteID = UUID().uuidString
        model.request.durationMinutes = 180
        let prepared = await model.prepareContext()
        XCTAssertTrue(prepared)
        XCTAssertEqual(model.request.creationOrigin, .newWalk)
        XCTAssertNil(model.request.previousRouteID)
        XCTAssertNotEqual(model.request.requestID, oldID)
        XCTAssertEqual(model.request.durationMinutes, 180)
    }

    func testForgottenDraftDoesNotReturnAfterReloadOrPendingWrite() async throws {
        let url = temporaryURL()
        let model = PlanningViewModel(api: MockCoreAPI(), cache: RoutePlanCache(url: temporaryURL()), draftURL: url)
        model.startNewDraft()
        model.request.durationMinutes = 180
        model.request.context.phrase = "не возвращать этот черновик"
        let forgotten = await model.forgetDraft()
        XCTAssertTrue(forgotten)
        XCTAssertFalse(model.draftExists)
        try await Task.sleep(for: .milliseconds(300))
        let restored = PlanningViewModel(api: MockCoreAPI(), cache: RoutePlanCache(url: temporaryURL()), draftURL: url)
        await restored.loadDraftIfNeeded()
        XCTAssertFalse(restored.draftExists)
        restored.startNewDraft()
        XCTAssertTrue(restored.draftExists)
        XCTAssertTrue(restored.request.context.phrase.isEmpty)
        XCTAssertEqual(restored.request.durationMinutes, 90)
    }

    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("data.json") }
    private func plan(_ id: String, route: String) -> RoutePlan {
        let base = RoutePlan.demo
        return RoutePlan(id: id, routeID: route, title: base.title, pois: base.pois, legs: base.legs, isDemo: true)
    }
}

private actor PreviewSpyAPI: CoreAPI {
    private(set) var targets: [String] = []
    private(set) var persistedAtAcknowledgement: [Bool] = []
    private let persistedPreviewURL: URL?
    init(persistedPreviewURL: URL? = nil) { self.persistedPreviewURL = persistedPreviewURL }
    func acknowledgeVersionResult(_ result: RoutePlan, replacing source: RoutePlan, correctionID: String?) async {
        guard let persistedPreviewURL else { return }
        let saved = (try? Data(contentsOf: persistedPreviewURL)).flatMap { try? JSONDecoder().decode([String: RoutePlan].self, from: $0) }
        persistedAtAcknowledgement.append(saved?[source.id]?.id == result.id)
    }
    func generateDemoRoute() async throws -> RoutePlan { .demo }
    func rebuildRoute(request: RouteRequest, previousPlan: RoutePlan) async throws -> RoutePlan {
        targets.append(previousPlan.id)
        return replacement(previousPlan, suffix: "-alternative")
    }
    func parseCorrection(text: String, plan: RoutePlan) async throws -> RouteCorrection {
        targets.append(plan.id)
        return .init(id: "correction", understood: true, constraints: [text])
    }
    func applyCorrection(_ correction: RouteCorrection, plan: RoutePlan) async throws -> RoutePlan {
        targets.append(plan.id)
        return replacement(plan, suffix: "-corrected")
    }
    private func replacement(_ plan: RoutePlan, suffix: String) -> RoutePlan {
        .init(id: plan.id + suffix, routeID: plan.routeID, title: plan.title, pois: plan.pois, legs: plan.legs, isDemo: plan.isDemo)
    }
}
