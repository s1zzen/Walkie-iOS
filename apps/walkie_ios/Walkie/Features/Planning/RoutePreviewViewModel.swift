import Combine
import Foundation
import WalkieCore

enum RoutePreviewRestoration: Equatable {
    case latestCardVersion
    case exactVersion
}

/// A route card owns its displayed version. History A must never borrow the
/// planning draft B as either an operation target or a replacement result.
@MainActor
final class RoutePreviewViewModel: ObservableObject {
    @Published private(set) var plan: RoutePlan
    @Published private(set) var isBusy = false
    @Published private(set) var isRestored = false
    @Published private(set) var errorMessage: String?
    private let api: (any CoreAPI)?
    private let store: RoutePreviewStore
    private let restoration: RoutePreviewRestoration
    init(plan: RoutePlan, api: (any CoreAPI)?, store: RoutePreviewStore = RoutePreviewStore(), restoration: RoutePreviewRestoration = .latestCardVersion) {
        self.plan = plan; self.api = api; self.store = store; self.restoration = restoration
    }

    @discardableResult
    func loadIfNeeded() async -> Bool {
        if isRestored { return true }
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            // An explicit repeat selects the immutable version from history.
            // Earlier edits to another preview must not silently replace it.
            if restoration == .latestCardVersion { plan = try await store.current(for: plan) }
            isRestored = true; errorMessage = nil
            return true
        } catch {
            errorMessage = "Не удалось восстановить версию маршрута. Локальный файл сохранён без изменений."
            return false
        }
    }

    func alternative() async -> Bool {
        guard let api, await loadIfNeeded() else { return false }
        let source = plan
        return await replace { try await api.rebuildRoute(request: RouteRequest(), previousPlan: source) }
    }
    func parseCorrection(_ text: String) async throws -> RouteCorrection {
        guard let api else { throw RouteRequestError.backendUnavailable }
        guard await loadIfNeeded() else { throw CocoaError(.fileReadCorruptFile) }
        return try await api.parseCorrection(text: text, plan: plan)
    }
    func applyCorrection(_ correction: RouteCorrection) async -> Bool {
        guard let api, await loadIfNeeded() else { return false }
        let source = plan
        return await replace(correctionID: correction.id) { try await api.applyCorrection(correction, plan: source) }
    }
    private func replace(correctionID: String? = nil, _ operation: @escaping () async throws -> RoutePlan) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; errorMessage = nil
        defer { isBusy = false }
        do {
            let source = plan
            let candidate = try await operation()
            try candidate.validate()
            try Task.checkCancellation()
            guard candidate.routeID == plan.routeID else { throw URLError(.badServerResponse) }
            // ACK retires the old intent. Persist its visible replacement first
            // so dismiss/restart cannot spend another alternative on that source.
            try await store.save(candidate, replacing: source)
            plan = candidate
            await api?.acknowledgeVersionResult(candidate, replacing: source, correctionID: correctionID)
            return true
        } catch { errorMessage = userFacingError(error); return false }
    }
}
