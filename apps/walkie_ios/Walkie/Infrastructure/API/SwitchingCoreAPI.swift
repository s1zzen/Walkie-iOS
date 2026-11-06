import Foundation
import WalkieCore

/// Demo is chosen only by an explicit user action or a launch argument used by
/// local UI tests. A missing/expired session never silently turns into fixtures.
actor SwitchingCoreAPI: CoreAPI {
    private let live: LiveRoutesAPI
    private let demo = MockCoreAPI()
    private let localDemo: Bool
    private let serverRoutesEnabled: @Sendable () -> Bool
    init(client: any RouteBackendTransport = BackendClient.shared, detailsURL: URL? = nil, localDemo: Bool? = nil,
         serverRoutesEnabled: @escaping @Sendable () -> Bool = { UserDefaults.standard.bool(forKey: "walkie.demoServerRoutes") }) {
        live = LiveRoutesAPI(client: client, detailsURL: detailsURL)
        self.serverRoutesEnabled = serverRoutesEnabled
        self.localDemo = localDemo ?? (ProcessInfo.processInfo.environment["WALKIE_OFFLINE_DEMO"] == "1" || UserDefaults.standard.bool(forKey: "walkie.localDemo"))
    }
    private var selected: any CoreAPI {
        localDemo && !serverRoutesEnabled() ? demo : live
    }
    func generateDemoRoute() async throws -> RoutePlan { try await selected.generateDemoRoute() }
    func generateRoute(request: RouteRequest) async throws -> RoutePlan { try await selected.generateRoute(request: request) }
    func rebuildRoute(request: RouteRequest, previousPlan: RoutePlan) async throws -> RoutePlan { try await selected.rebuildRoute(request: request, previousPlan: previousPlan) }
    func prepareContext(request: RouteRequest) async throws -> RouteContextDefinition { try await selected.prepareContext(request: request) }
    func saveContextAnswer(requestID: String, questionID: String, choices: [String]?) async throws { try await selected.saveContextAnswer(requestID: requestID, questionID: questionID, choices: choices) }
    func parseCorrection(text: String, plan: RoutePlan) async throws -> RouteCorrection { try await selected.parseCorrection(text: text, plan: plan) }
    func applyCorrection(_ correction: RouteCorrection, plan: RoutePlan) async throws -> RoutePlan { try await selected.applyCorrection(correction, plan: plan) }
    func acknowledgeVersionResult(_ result: RoutePlan, replacing source: RoutePlan, correctionID: String?) async {
        await selected.acknowledgeVersionResult(result, replacing: source, correctionID: correctionID)
    }
    func routeDetails(planID: String) async -> LiveRouteDetails? { await live.routeDetails(planID: planID) }
    func createShareText(plan: RoutePlan) async throws -> String { try await selected.createShareText(plan: plan) }
    func generationProgress() async -> RouteGenerationProgress? { await selected.generationProgress() }
}
