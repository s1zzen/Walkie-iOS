import Foundation
import Combine

struct AccountInfo: Decodable {
    struct Stats: Decodable { var walks_completed: Int; var distance_total_m: Int; var steps_week: Int; var rating_avg: Double? }
    struct Pro: Decodable { var in_early_access: Bool }
    var id: String
    var display_name: String?
    var context_branch: String
    var stats: Stats
    var pro: Pro
}
struct AccountSettings: Codable {
    struct Notifications: Codable { var invites = true; var joint_routes = true; var rating_reminder = true; var weekly_results = true }
    var routes_visibility = "only_me"
    var leaderboard_enabled = false
    var notifications = Notifications()
}
struct AppConfiguration: Decodable, Equatable, Sendable {
    struct Features: Decodable, Equatable, Sendable { var social_enabled: Bool }
    var features: Features
    var generation_long_wait_s: Int?
    var inactivity_timeout_s: Int?
    var protocol_version: String?
}

@MainActor final class AccountViewModel: ObservableObject {
    @Published var info: AccountInfo?
    @Published var settings = AccountSettings()
    @Published var socialEnabled = false
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var hasSession = false
    @Published private(set) var isOfflineDemo: Bool
    @Published private(set) var configuration: AppConfiguration?
    private let client: any AccountBackendClient
    private let onLocalModeExited: @MainActor () -> Void
    private var identityGeneration = UUID()
    init(client: any AccountBackendClient = BackendClient.shared, isOfflineDemo: Bool? = nil,
         onLocalModeExited: @escaping @MainActor () -> Void = { UserDefaults.standard.set(false, forKey: "walkie.localDemo") }) {
        self.client = client
        self.isOfflineDemo = isOfflineDemo ?? (ProcessInfo.processInfo.environment["WALKIE_OFFLINE_DEMO"] == "1"
            || UserDefaults.standard.bool(forKey: "walkie.localDemo"))
        self.onLocalModeExited = onLocalModeExited
    }
    func refresh() async {
        identityGeneration = UUID()
        let generation = identityGeneration
        // Demo never observes an unrelated Keychain account or flushes its real outbox.
        if isOfflineDemo {
            resetPublishedState()
            return
        }
        guard let session = await client.currentSession() else { resetPublishedState(); return }
        guard identityGeneration == generation else { return }
        hasSession = true
        isBusy = true
        defer { if identityGeneration == generation { isBusy = false } }
        do {
            let remoteInfo = try JSONDecoder().decode(AccountInfo.self, from: await client.request(path: "/v1/me", method: "GET", body: nil, expectedUserID: session.user_id))
            let config = try JSONDecoder().decode(AppConfiguration.self, from: await client.request(path: "/v1/config", method: "GET", body: nil, expectedUserID: session.user_id))
            let remoteSettings = try JSONDecoder().decode(AccountSettings.self, from: await client.request(path: "/v1/me/settings", method: "GET", body: nil, expectedUserID: session.user_id))
            guard identityGeneration == generation, await client.currentSession()?.user_id == session.user_id else { return }
            info = remoteInfo
            configuration = config
            socialEnabled = config.features.social_enabled
            settings = remoteSettings
            errorMessage = nil
        } catch {
            guard identityGeneration == generation else { return }
            if let problem = error as? BackendProblem, problem.status == 401 {
                // A terminal server rejection is different from an offline phone.
                // Do not revoke a newer session that might have replaced this one.
                if let current = await client.currentSession(), current.user_id == session.user_id {
                    do {
                        try await client.clearSession(expectedUserID: session.user_id)
                        resetPublishedState()
                        errorMessage = "Сессия истекла. Войди в учётную запись ещё раз."
                    } catch { errorMessage = "Не удалось очистить истёкшую сессию: \(userFacingError(error))" }
                }
            } else { errorMessage = userFacingError(error) }
        }
    }
    @discardableResult
    func saveSettings() async -> Bool {
        guard !isBusy, !isOfflineDemo else { return false }
        let generation = identityGeneration
        isBusy = true
        errorMessage = nil
        defer { if identityGeneration == generation { isBusy = false } }
        guard let session = await client.currentSession(), identityGeneration == generation else { return false }
        do {
            let data = try await client.request(path: "/v1/me/settings", method: "PATCH", body: JSONEncoder().encode(settings), expectedUserID: session.user_id)
            guard identityGeneration == generation, await client.currentSession()?.user_id == session.user_id else { return false }
            settings = try JSONDecoder().decode(AccountSettings.self, from: data)
            errorMessage = nil
            return true
        } catch {
            if identityGeneration == generation { errorMessage = userFacingError(error) }
            return false
        }
    }
    func subscribe(entry: String) async -> Bool {
        guard !isBusy, !isOfflineDemo else { return false }
        let generation = identityGeneration
        isBusy = true
        errorMessage = nil
        defer { if identityGeneration == generation { isBusy = false } }
        guard let session = await client.currentSession(), identityGeneration == generation else { return false }
        do {
            let body = try JSONSerialization.data(withJSONObject: ["request_id": UUID().uuidString, "entry": entry])
            _ = try await client.request(path: "/v1/me/pro-intent", method: "POST", body: body, expectedUserID: session.user_id)
            guard identityGeneration == generation, await client.currentSession()?.user_id == session.user_id else { return false }
            info?.pro.in_early_access = true
            return true
        } catch {
            if identityGeneration == generation { errorMessage = userFacingError(error) }
            return false
        }
    }
    func signOut(deleteAccount: Bool = false) async -> Bool {
        identityGeneration = UUID()
        if isOfflineDemo {
            guard !deleteAccount else {
                errorMessage = "В локальном режиме нет серверной учётной записи для удаления. Можно выйти из локального режима; записи на iPhone сохранятся."
                return false
            }
            onLocalModeExited()
            resetPublishedState()
            return true
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let session = await client.currentSession()
            if deleteAccount {
                guard let session else { errorMessage = "Для удаления учётной записи нужно войти на сервер."; return false }
                // A failed DELETE preserves the local session and never claims account deletion.
                _ = try await client.request(path: "/v1/me", method: "DELETE", body: nil, expectedUserID: session.user_id)
                guard await client.currentSession()?.user_id == session.user_id else {
                    errorMessage = "Текущая учётная запись изменилась. Её сессия сохранена."
                    return false
                }
            }
            try await client.clearSession(expectedUserID: session?.user_id)
            onLocalModeExited()
            resetPublishedState()
            if !deleteAccount, let session {
                // Local logout completes immediately. Revocation is best effort using only
                // this captured access token, even after Keychain credentials are removed.
                Task { await client.revokeSession(session) }
            }
            return true
        } catch { errorMessage = userFacingError(error); return false }
    }

    private func resetPublishedState() {
        hasSession = false
        info = nil
        configuration = nil
        socialEnabled = false
        settings = AccountSettings()
        errorMessage = nil
        isBusy = false
    }
}
