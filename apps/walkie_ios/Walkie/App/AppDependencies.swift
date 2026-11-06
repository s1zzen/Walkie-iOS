import Foundation
import CryptoKit
import Combine
import WalkieCore

@MainActor
final class AppDependencies: ObservableObject {
    let planning: PlanningViewModel
    let walk: WalkViewModel
    let history: HistoryViewModel
    let product: ProductViewModel
    let account: AccountViewModel
    let scopeID: String
    let telemetry: TelemetryQueue
    @Published private(set) var pendingProOffer: UUID?
    private let productSync: ProductWalkSync
    private let connectivity: WalkConnectivityMonitor
    private let preloginTelemetry: TelemetryQueue?
    // Recreated account scopes must not create competing writers for the same queue.
    private static var telemetryStores: [String: TelemetryQueue] = [:]
    private static func telemetryStore(at url: URL, enabled: Bool, ownerID: String?) -> TelemetryQueue {
        if let existing = telemetryStores[url.path] { return existing }
        let store = TelemetryQueue(url: url, enabled: enabled, owner: {
            if let ownerID { return ownerID }
            return await BackendClient.shared.currentSession()?.user_id
        })
        telemetryStores[url.path] = store
        return store
    }

    static func currentScopeID() -> String {
        if ProcessInfo.processInfo.environment["WALKIE_OFFLINE_DEMO"] == "1" || UserDefaults.standard.bool(forKey: "walkie.localDemo") { return "demo" }
        guard let data = BackendKeychain.data(for: "session"),
              let session = try? JSONDecoder().decode(BackendSession.self, from: data) else { return "guest" }
        return "user-" + SHA256.hash(data: Data(session.user_id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    init() {
        scopeID = Self.currentScopeID()
        let files = FileManager.default
        var support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Walkie", isDirectory: true)
        var exports = files.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        #if DEBUG
        // UI tests never reset or overwrite the user's profile and walks.
        if let rawID = ProcessInfo.processInfo.environment["WALKIE_TEST_STORAGE_ID"],
           let id = UUID(uuidString: rawID) {
            support = support.appendingPathComponent("UITests/\(id.uuidString)", isDirectory: true)
            exports = support.appendingPathComponent("Exports", isDirectory: true)
        }
        #endif
        // Legacy files remain intact. Unknown ownership is not inferred during migration.
        let installationSupport = support
        support = support.appendingPathComponent("Accounts/\(scopeID)", isDirectory: true)
        exports = exports.appendingPathComponent(scopeID, isDirectory: true)
        let rememberedOwner = BackendKeychain.data(for: "session").flatMap { try? JSONDecoder().decode(BackendSession.self, from: $0) }?.user_id
        let recorder = Self.telemetryStore(at: support.appendingPathComponent("telemetry.json"), enabled: scopeID != "demo", ownerID: scopeID.hasPrefix("user-") ? rememberedOwner : nil)
        telemetry = recorder
        preloginTelemetry = scopeID.hasPrefix("user-")
            ? Self.telemetryStore(at: installationSupport.appendingPathComponent("Accounts/guest/telemetry.json"), enabled: true, ownerID: nil) : nil
        let store = LocalSessionStore(root: support.appendingPathComponent("Sessions", isDirectory: true))
        let api: any CoreAPI
        api = SwitchingCoreAPI(client: BackendClient.shared, detailsURL: support.appendingPathComponent("route_metadata.json"))
        planning = PlanningViewModel(api: api, cacheURL: support.appendingPathComponent("route.json"))
        let sync = ProductWalkSync(url: support.appendingPathComponent("walk_outbox.json"), metadataURL: support.appendingPathComponent("route_metadata.json"), sessionStore: store)
        productSync = sync
        let coordinator = WalkSessionCoordinator(store: store, sensors: SensorService(), motion: MotionService(), productSync: sync)
        walk = WalkViewModel(coordinator: coordinator, sync: sync)
        coordinator.onProductEvent = { name, payload in Task { try? await recorder.record(name, payload: payload) } }
        Task { await sync.flush() }
        history = HistoryViewModel(store: store, exportDirectory: exports)
        product = ProductViewModel(storageURL: support.appendingPathComponent("product.json"))
        account = AccountViewModel(isOfflineDemo: scopeID == "demo")
        planning.onPlanningEvent = { name, payload in
            Task { try? await recorder.record(name, payload: payload) }
        }
        let monitor = WalkConnectivityMonitor()
        connectivity = monitor
        monitor.walkID = { [weak coordinator] in coordinator?.hasOpenSession == true ? coordinator?.record?.id : nil }
        monitor.onEvent = { [weak coordinator] name in
            guard let coordinator, let record = coordinator.record, !coordinator.researchActive else { return }
            coordinator.onProductEvent?(name, ["walk_id": record.id.uuidString, "route_id": record.route.routeID, "route_version_id": record.route.id])
        }
        monitor.onRestored = { [weak self] in Task { await self?.flushOutboxes() } }
    }

    func flushOutboxes() async {
        await productSync.flush()
        try? await telemetry.flush()
        // Offline onboarding/login events remain recoverable after the guest
        // scope is replaced. Anonymous events are still sent anonymously.
        try? await preloginTelemetry?.flush()
        await walk.refreshSynchronization()
        pendingProOffer = await productSync.nextPendingProOffer()
    }
    func markProOfferShown(_ id: UUID) async {
        do { try await productSync.markProOfferShown(walkID: id); pendingProOffer = await productSync.nextPendingProOffer() }
        catch { account.errorMessage = "Не удалось сохранить показ предложения. \(userFacingError(error))" }
    }
    func refreshConnectivity() { connectivity.refreshWalk() }
    func applyConfiguration(_ configuration: AppConfiguration) {
        planning.configureGenerationLongWait(seconds: Double(configuration.generation_long_wait_s ?? 15))
        walk.coordinator.configurePauseTimeout(seconds: Double(configuration.inactivity_timeout_s ?? 1_800))
    }
}
