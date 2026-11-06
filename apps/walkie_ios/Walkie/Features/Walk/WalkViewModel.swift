import Combine
import Foundation
import WalkieCore

@MainActor
final class WalkViewModel: ObservableObject {
    let coordinator: WalkSessionCoordinator
    @Published var showsReturnStub = false
    @Published var showsFinishConfirmation = false
    @Published var showsObserver = false
    @Published var showsWalkMenu = false
    @Published var showsVisitConfirmation = false
    @Published var showsExportConfirmation = false
    @Published var showsShare = false
    @Published var exportFiles: [URL] = []
    @Published private(set) var synchronization: ProductWalkSyncStatus?
    @Published private(set) var summaryDecisionMade = false
    private let sync: ProductWalkSync?
    private var subscription: AnyCancellable?

    init(coordinator: WalkSessionCoordinator, sync: ProductWalkSync? = nil) {
        self.coordinator = coordinator
        self.sync = sync
        subscription = coordinator.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var record: SessionRecord? { coordinator.record }
    var isBusy: Bool { coordinator.isBusy }
    var hasOpenSession: Bool { coordinator.hasOpenSession }
    // A closed session still owns its result until the user dismisses it.
    func displayedPlan(fallback: RoutePlan?) -> RoutePlan? { record?.route ?? fallback }
    var showsSummary: Bool { record?.state.isClosed == true }

    func visitedIDs(for plan: RoutePlan) -> Set<String> {
        guard record?.route.id == plan.id else { return [] }
        return Set(record?.visitedPOIIDs ?? [])
    }

    func nextPlace(in plan: RoutePlan) -> RoutePOI? {
        let visited = visitedIDs(for: plan)
        let skipped = Set(record?.route.id == plan.id ? record?.manualSkippedPOIIDs ?? [] : [])
        return plan.pois.first { !visited.contains($0.id) && !skipped.contains($0.id) }
    }

    func start(route: RoutePlan, kind: WalkStartKind = .regular) async {
        await coordinator.start(route: route, kind: kind)
        if coordinator.hasOpenSession { summaryDecisionMade = false; synchronization = nil }
    }
    func pause() async { await coordinator.pause() }
    func resume() async { resumeAction("continue_walk"); await coordinator.resume() }
    func finish(atLastPoint: Bool = false) async { await coordinator.finish(atLastPoint: atLastPoint) }
    func complete() async { _ = await coordinator.complete(atLastPoint: canFinishAtLastPoint) }
    func interrupt() async { if record?.state == .paused { resumeAction("interrupt_walk") }; await coordinator.interrupt() }
    var canFinishAtLastPoint: Bool {
        record.map(WalkCompletionPolicy.canFinishAtLastPoint) ?? false
    }
    var canComplete: Bool { record.flatMap { WalkCompletionPolicy.completion(for: $0, atLastPoint: canFinishAtLastPoint) } != nil }
    func markVisited(_ poi: RoutePOI) async { await coordinator.markVisited(poiID: poi.id) }
    func skip(_ poi: RoutePOI) async { await coordinator.markSkipped(poiID: poi.id) }
    func refreshSynchronization() async {
        guard let sync, let record else { return }
        let updated = await sync.snapshot(for: record.id)
        if synchronization != updated { synchronization = updated }
    }
    func retrySynchronization() async {
        await sync?.retryPendingFinishes(); await sync?.flush(); await refreshSynchronization()
    }
    func saveRating(_ rating: Int, comment: String) async -> Bool {
        let saved = await coordinator.saveFeedback(rating: rating, comment: comment)
        if saved { summaryDecisionMade = true }
        await refreshSynchronization()
        return saved
    }
    func skipRating() async -> Bool {
        guard let record, record.state.isClosed else { return false }
        if summaryDecisionMade { return true }
        let saved = await coordinator.skipFeedback()
        if saved { summaryDecisionMade = true }
        await refreshSynchronization()
        return saved
    }
    func resumeAction(_ action: String) {
        guard let record else { return }
        coordinator.onProductEvent?("resume_action", ["walk_id": record.id.uuidString,
            "route_id": record.route.routeID, "route_version_id": record.route.id, "action": action])
    }
    func reaction(_ action: String) {
        guard let record, !coordinator.researchActive else { return }
        coordinator.onProductEvent?("off_route_reaction", ["walk_id": record.id.uuidString,
            "route_id": record.route.routeID, "route_version_id": record.route.id, "action": action])
    }
    func export() async {
        exportFiles = await coordinator.exportCurrentSession()
        showsShare = !exportFiles.isEmpty
    }

    var elapsedText: String {
        guard let record else { return "0 мин" }
        let seconds = max(0, Int((record.endedAt ?? Date()).timeIntervalSince(record.startedAt)))
        return seconds >= 3_600 ? "\(seconds / 3_600) ч \(seconds % 3_600 / 60) мин" : "\(seconds / 60) мин"
    }

    func distanceToNext(in plan: RoutePlan) -> String {
        guard let next = nextPlace(in: plan), let sample = coordinator.latestObservation,
              Date().timeIntervalSince(sample.observedAt) <= 10,
              sample.accuracy <= 35 else { return "—" }
        let distance = ResearchDistance.between(sample.coordinate, next.coordinate)
        return distance >= 1_000 ? String(format: "%.1f км", distance / 1_000) : "\(Int(distance.rounded())) м"
    }

    /// Явная заглушка: без запросов, замены плана и имитации результата маршрутизации.
    func requestReturnToPreviousRoute() { reaction("return"); showsReturnStub = true }
}
