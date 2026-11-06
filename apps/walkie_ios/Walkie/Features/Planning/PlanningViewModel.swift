import Combine
import Foundation
import WalkieCore

@MainActor
final class PlanningViewModel: ObservableObject {
    @Published var request = RouteRequest() { didSet { persistDraft() } }
    @Published var builderStep: RouteBuilderStep = .origin { didSet { persistDraft() } }
    @Published private(set) var contextBranch: RouteContextBranch = .c0
    @Published private(set) var contextQuestions = RouteContextDefinition.demo.questions
    @Published private(set) var isPreparingContext = false
    @Published private(set) var draftExists = false
    @Published private(set) var draftError: String?
    @Published private(set) var contextError: String?
    @Published var wantsBuilder = false
    @Published private(set) var generationLongWaitVisible = false
    private(set) var generationLongWaitSeconds: Double = 15
    var onPlanningEvent: ((String, [String: String]) -> Void)?
    @Published private(set) var plan: RoutePlan?
    @Published private(set) var routeDetails: LiveRouteDetails?
    @Published private(set) var generationProgress: RouteGenerationProgress?
    @Published private(set) var isLoading = false
    @Published private(set) var isCommitting = false
    @Published private(set) var errorMessage: String?

    private let api: any CoreAPI
    private let cache: any RoutePlanCaching
    private var activeOperation: Task<RoutePlan?, Error>?
    private var intentID = UUID()
    private var didAttemptCacheLoad = false
    private var pendingProfileInterests: [String]?
    private var generationNeedsNewID = false
    private let draftStore: RouteDraftStore?
    private let previewStore: RoutePreviewStore
    private var draftRevision: UInt64 = 0
    private var didAttemptDraftLoad = false
    private var draftWrite: Task<Void, Never>?
    private var draftReset: Task<Void, Error>?
    private var generationClock: Task<Void, Never>?
    private var activeGeneration: (token: UUID, routeID: String, requestID: String)?
    private var generationStartedAt: Date?
    private var longWaitReported = Set<String>()
    private var cancellationReported = Set<String>()

    convenience init(api: any CoreAPI, cacheURL: URL) {
        self.init(api: api, cache: RoutePlanCache(url: cacheURL),
            draftURL: cacheURL.deletingLastPathComponent().appendingPathComponent("route_draft.json"),
            previewURL: cacheURL.deletingLastPathComponent().appendingPathComponent("route_previews.json"))
    }

    init(api: any CoreAPI, cache: any RoutePlanCaching, draftURL: URL? = nil, previewURL: URL? = nil) {
        self.api = api
        self.cache = cache
        self.draftStore = draftURL.map(RouteDraftStore.init(url:))
        self.previewStore = RoutePreviewStore(url: previewURL)
    }

    func loadDraftIfNeeded() async {
        guard !didAttemptDraftLoad, let draftStore else { return }
        didAttemptDraftLoad = true
        let revision = draftRevision
        do {
            guard let draft = try await draftStore.load(), draftRevision == revision, !draftExists else { return }
            request = draft.request; contextBranch = draft.branch
            builderStep = draft.step == .generation ? .company : draft.step
            draftExists = !draft.isComplete
        } catch { draftError = "Черновик не удалось восстановить. Он оставлен без изменений." }
    }

    func configureContextBranch(_ branch: RouteContextBranch) { contextBranch = branch }

    func configureGenerationLongWait(seconds: Double) {
        guard seconds.isFinite, seconds > 0 else { return }
        generationLongWaitSeconds = seconds
        scheduleGenerationClock()
    }

    private func scheduleGenerationClock() {
        generationClock?.cancel()
        guard let activeGeneration, let generationStartedAt else { return }
        let remaining = max(0, generationLongWaitSeconds - Date().timeIntervalSince(generationStartedAt))
        generationClock = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.activeGeneration?.token == activeGeneration.token else { return }
            self.reportGenerationElapsed(max(self.generationLongWaitSeconds, Date().timeIntervalSince(generationStartedAt)))
        }
    }

    func reportGenerationElapsed(_ elapsed: Double) {
        guard isLoading, elapsed >= generationLongWaitSeconds, let activeGeneration else { return }
        generationLongWaitVisible = true
        guard longWaitReported.insert(activeGeneration.requestID).inserted else { return }
        event("generation_long_wait_shown", ["route_id": activeGeneration.routeID, "request_id": activeGeneration.requestID])
    }

    func startNewDraft() {
        let interests = request.interests
        draftWrite?.cancel()
        draftExists = false
        draftRevision += 1
        if let draftStore {
            let revision = draftRevision, previous = draftReset
            draftReset = Task {
                if let previous { try? await previous.value }
                _ = try await draftStore.beginNewDraft(revision: revision)
            }
        }
        request = RouteRequest(interests: interests.isEmpty ? RouteRequest().interests : interests)
        builderStep = .origin
        draftExists = true
        persistDraft()
        event("route_flow_started")
    }

    func restartDraft() {
        startNewDraft()
        // A discarded local draft is not an owned server route.
        request.creationOrigin = .newWalk
    }

    @discardableResult
    func forgetDraft() async -> Bool {
        guard !isLoading, !isPreparingContext, !isCommitting else { return false }
        await completeDraft(requestID: request.requestID)
        guard !draftExists else { return false }
        // Keep the user's interests; forget only the unfinished planning intent.
        request = RouteRequest(interests: request.interests)
        builderStep = .origin
        contextBranch = .c0
        contextQuestions = RouteContextDefinition.demo.questions
        contextError = nil
        errorMessage = nil
        return true
    }

    func startParametersChange(from plan: RoutePlan) {
        startNewDraft()
        request.creationOrigin = .paramsChange; request.previousRouteID = plan.routeID
        request.origin = plan.start
        wantsBuilder = true
    }

    func event(_ name: String, _ payload: [String: String] = [:]) {
        onPlanningEvent?(name, payload.merging(["route_id": request.requestID]) { first, _ in first })
    }

    func persistDraft() {
        guard draftExists, let draftStore else { return }
        draftRevision += 1
        let revision = draftRevision
        let snapshot = RouteBuilderDraft(request: request, step: builderStep, branch: contextBranch)
        let reset = draftReset
        draftWrite?.cancel()
        draftWrite = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
                try Task.checkCancellation()
                try await reset?.value
                try await draftStore.save(snapshot, revision: revision)
                if self?.draftRevision == revision { self?.draftError = nil }
            } catch is CancellationError { }
            catch { if self?.draftRevision == revision { self?.draftError = "Не удалось сохранить черновик на телефоне. Освободи место и повтори." } }
        }
    }

    @discardableResult
    func flushDraft() async -> Bool {
        guard draftExists, let draftStore else { return true }
        draftWrite?.cancel()
        draftRevision += 1
        let revision = draftRevision
        let snapshot = RouteBuilderDraft(request: request, step: builderStep, branch: contextBranch)
        let reset = draftReset
        do {
            try await reset?.value
            try await draftStore.save(snapshot, revision: revision)
            if draftRevision == revision { draftError = nil }
            return true
        } catch { draftError = "Не удалось сохранить черновик на телефоне. Освободи место и повтори."; return false }
    }

    private func completeDraft(requestID: String) async {
        guard request.requestID == requestID else { return }
        draftWrite?.cancel(); draftRevision += 1
        guard let draftStore else { draftExists = false; return }
        do {
            try await draftReset?.value
            try await draftStore.save(RouteBuilderDraft(request: request, step: .origin, branch: contextBranch, isComplete: true), revision: draftRevision)
            if request.requestID == requestID { draftExists = false }
        } catch { draftError = "Маршрут сохранён, но не удалось обновить состояние черновика." }
    }

    func prepareContext() async -> Bool {
        guard !isPreparingContext else { return false }
        if request.creationOrigin == .restart {
            // Repair drafts written by the old restartDraft implementation.
            // Keep the chosen points and budget, but create a fresh server intent.
            request.requestID = UUID().uuidString
            request.creationOrigin = .newWalk
            request.previousRouteID = nil
            request.context = .init()
        }
        isPreparingContext = true
        contextError = nil
        defer { isPreparingContext = false }
        do {
            guard await flushDraft() else { return false }
            let definition = try await api.prepareContext(request: request)
            contextQuestions = definition.questions
            // The server flow is authoritative. No client hashing or random C.
            contextBranch = definition.branch
            request.context.answers.merge(definition.storedAnswers) { _, remote in remote }
            for id in definition.storedAnswers.keys { request.context.skipped.remove(id) }
            for id in definition.skippedQuestions { request.context.answers.removeValue(forKey: id); request.context.skipped.insert(id) }
            if definition.isComplete { builderStep = .generation }
            else {
                switch definition.nextQuestionID {
                case "K2": builderStep = .purpose
                case "K3": builderStep = .energy
                case "K4": builderStep = .interests
                case "K5": builderStep = .coffee
                case "phrase": builderStep = .phrase
                default: builderStep = .company
                }
            }
            _ = await flushDraft()
            return true
        } catch {
            contextError = userFacingError(error)
            return false
        }
    }

    func answerContext(_ questionID: String, choices: [String]?, timeOnScreenMS: Int = 0) async -> Bool {
        guard !isPreparingContext else { return false }
        if let choices {
            request.context.answers[questionID] = choices
            request.context.skipped.remove(questionID)
        } else {
            request.context.answers.removeValue(forKey: questionID)
            request.context.skipped.insert(questionID)
        }
        isPreparingContext = true
        contextError = nil
        defer { isPreparingContext = false }
        do {
            guard await flushDraft() else { return false }
            try await api.saveContextAnswer(requestID: request.requestID, questionID: questionID, choices: choices)
            event("question_left", ["questionnaire": "context", "question_id": questionID, "action": choices == nil ? "skipped" : "answered", "time_on_screen_ms": String(timeOnScreenMS)])
            return true
        } catch { contextError = userFacingError(error); return false }
    }

    func parseCorrection(_ text: String, plan: RoutePlan) async throws -> RouteCorrection {
        try await api.parseCorrection(text: text, plan: plan)
    }

    func previewModel(for plan: RoutePlan, restoration: RoutePreviewRestoration = .latestCardVersion) -> RoutePreviewViewModel {
        RoutePreviewViewModel(plan: plan, api: api, store: previewStore, restoration: restoration)
    }

    func shareText(plan: RoutePlan) async throws -> String { try await api.createShareText(plan: plan) }
    func refreshGenerationProgress() async { generationProgress = await api.generationProgress() }
    func details(for planID: String) async -> LiveRouteDetails? { await api.routeDetails(planID: planID) }

    func applyCorrection(_ correction: RouteCorrection, plan: RoutePlan) async -> Bool {
        let api = api
        return await loadAndSave { try await api.applyCorrection(correction, plan: plan) }
    }

    func alternative() async -> Bool {
        guard let plan else { return false }
        let api = api, request = request
        return await loadAndSave { try await api.rebuildRoute(request: request, previousPlan: plan) }
    }

    /// Keep deferred profile changes in the app-scoped model, not in a tab's
    /// view lifetime. Active walks keep the interests used to prepare them.
    func updateProfileInterests(_ interests: [String], walkIsActive: Bool) {
        if walkIsActive {
            pendingProfileInterests = interests
        } else {
            request.interests = interests
            pendingProfileInterests = nil
        }
    }

    func walkDidFinish() {
        guard let pendingProfileInterests else { return }
        request.interests = pendingProfileInterests
        self.pendingProfileInterests = nil
    }

    /// Idempotent on repeated view appearances; never interrupts a new request.
    func loadCachedPlan() {
        guard !didAttemptCacheLoad, !isLoading, plan == nil else { return }
        didAttemptCacheLoad = true
        let intent = beginIntent()
        let cache = cache
        let operation = Task<RoutePlan?, Error> { try await cache.load() }
        activeOperation = operation
        Task { [weak self] in
            await self?.receive(operation, intent: intent, loadingCache: true)
        }
    }

    /// No coordinate is read or sent: this action loads a fixed demonstration.
    func generateDemo() async {
        let api = api
        await loadAndSave { try await api.generateDemoRoute() }
    }

    /// Snapshot form values before suspension; later edits belong to the next
    /// request. Fixture selection is local and does not read location sensors.
    @discardableResult
    func generate() async -> Bool {
        guard !isCommitting, !isLoading else { return false }
        guard await flushDraft() else { return false }
        let request = request
        let api = api
        let clockToken = UUID()
        activeGeneration = (clockToken, request.requestID, request.generationID)
        generationStartedAt = Date()
        generationLongWaitVisible = false
        scheduleGenerationClock()
        defer {
            if activeGeneration?.token == clockToken {
                activeGeneration = nil
                generationStartedAt = nil
                generationClock?.cancel(); generationClock = nil
            }
        }
        event("generation_started", ["route_id": request.requestID, "request_id": request.generationID, "kind": "initial"])
        let result = await loadAndSave(isGeneration: true) {
            try request.validate()
            return try await api.generateRoute(request: request)
        }
        if result {
            await completeDraft(requestID: request.requestID)
            event("route_received", ["route_id": request.requestID, "request_id": request.generationID, "route_version_id": plan?.id ?? ""])
        }
        // A lost POST response/poll may still be running on the server. Keep
        // the persisted key on transport errors and local cancellation; a
        // retry asks for that same operation instead of competing with it.
        if generationNeedsNewID, !isLoading,
           self.request.requestID == request.requestID, self.request.generationID == request.generationID {
            self.request.generationID = UUID().uuidString
            generationNeedsNewID = false
            _ = await flushDraft()
        }
        return result
    }

    @discardableResult
    func selectSavedRoute(_ route: RoutePlan) async -> Bool {
        await loadAndSave { route }
    }

    @discardableResult
    private func loadAndSave(
        isGeneration: Bool = false,
        _ load: @escaping @Sendable () async throws -> RoutePlan
    ) async -> Bool {
        // Once persistence starts, publication belongs to that same accepted
        // transaction. Reject competing intents until save + publish finish.
        guard !isCommitting else { return false }
        let intent = beginIntent(preserveGenerationClock: isGeneration)
        let cache = cache
        let operation = Task<RoutePlan?, Error> {
            let candidate = try await load()
            // A future HTTP implementation may ignore cancellation. This check
            // is mandatory before it can replace a valid local route.
            try Task.checkCancellation()
            try candidate.validate()
            guard intentID == intent else { throw CancellationError() }
            isCommitting = true
            try await cache.save(candidate)
            // No cancellation check after the durable commit: a late cancel
            // cannot report failure while leaving the new route on disk.
            return candidate
        }
        activeOperation = operation
        return await receive(operation, intent: intent, loadingCache: false)
    }

    func cancel() {
        // Cancellation is accepted during preparation/network work. The short
        // durable-write phase cannot be safely rolled back and must finish.
        guard !isCommitting else { return }
        if isLoading, let activeGeneration,
           cancellationReported.insert(activeGeneration.requestID).inserted {
            event("generation_cancelled", ["route_id": activeGeneration.routeID, "request_id": activeGeneration.requestID])
        }
        activeGeneration = nil
        generationStartedAt = nil
        generationClock?.cancel(); generationClock = nil
        intentID = UUID()
        activeOperation?.cancel()
        activeOperation = nil
        isCommitting = false
        isLoading = false
        errorMessage = nil
        generationNeedsNewID = false
    }

    private func beginIntent(preserveGenerationClock: Bool = false) -> UUID {
        if !preserveGenerationClock {
            activeGeneration = nil; generationStartedAt = nil
            generationClock?.cancel(); generationClock = nil
        }
        activeOperation?.cancel()
        intentID = UUID()
        isLoading = true
        errorMessage = nil
        generationNeedsNewID = false
        return intentID
    }

    @discardableResult
    private func receive(
        _ operation: Task<RoutePlan?, Error>,
        intent: UUID,
        loadingCache: Bool
    ) async -> Bool {
        var didPublish = false
        do {
            let candidate = try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: {
                operation.cancel()
            }
            guard intentID == intent else { return false }
            if let candidate {
                let details = await api.routeDetails(planID: candidate.id)
                guard intentID == intent else { return false }
                routeDetails = details
                plan = candidate
                didPublish = true
            }
            errorMessage = nil
        } catch {
            guard intentID == intent else { return false }
            generationNeedsNewID = error is RouteGenerationTerminalError
            if error is CancellationError || operation.isCancelled {
                errorMessage = nil
            } else if loadingCache {
                errorMessage = "Не удалось восстановить последний маршрут. Файл оставлен без изменений. Можно создать маршрут заново."
            } else if let validationError = error as? RouteRequestError {
                errorMessage = validationError.localizedDescription
            } else {
                errorMessage = userFacingError(error)
            }
        }
        guard intentID == intent else { return false }
        activeOperation = nil
        isCommitting = false
        isLoading = false
        return didPublish
    }
}
