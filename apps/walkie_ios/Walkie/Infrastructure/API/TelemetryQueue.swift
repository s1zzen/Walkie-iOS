import Foundation

enum ClientTelemetryType: String, CaseIterable {
    case onboarding_shown, login_screen_shown, login_method_selected
    case permission_prompt_shown, permission_result, question_shown, question_left
    case profile_summary_shown, profile_summary_edit_started, route_flow_started
    case generation_started, generation_long_wait_shown, generation_cancelled
    case route_received, route_shown, place_card_opened, external_maps_open, share_tapped
    case off_route_candidate, off_route_reaction, off_route_self_return, split_point_reached
    case network_lost, network_restored, pro_shown, pro_not_now
    case resume_prompt_shown, resume_action, second_method_prompt_action, notification_opened, push_opened
}

struct ClientTelemetryEvent: Codable, Sendable, Identifiable {
    let id: UUID
    let type: String
    let device_ts: String
    let install_id: String
    let screen: String?
    let payload: [String: String]
    let owner_user_id: String?
    var route_id: String? = nil
    var route_version_id: String? = nil
    var walk_id: String? = nil
    var group_id: String? = nil
}

/// Durable at-least-once delivery. IDs survive retries; the server deduplicates.
actor TelemetryQueue: ProductTelemetryRecording {
    static let shared = TelemetryQueue()
    private let url: URL
    private let client: any RouteBackendTransport
    private let owner: @Sendable () async -> String?
    private var sending = false
    private let installID: String
    private let enabled: Bool
    init(url: URL? = nil, client: any RouteBackendTransport = BackendClient.shared, respectsDemoMode: Bool = true,
         enabled: Bool? = nil, owner: @escaping @Sendable () async -> String? = { await BackendClient.shared.currentSession()?.user_id },
         installID: String? = nil) {
        // Environment is selected once per account scope, not during each event.
        self.enabled = enabled ?? (!respectsDemoMode || (ProcessInfo.processInfo.environment["WALKIE_OFFLINE_DEMO"] != "1" && !UserDefaults.standard.bool(forKey: "walkie.localDemo")))
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Walkie/telemetry.json")
        self.client = client
        self.owner = owner
        if let installID { self.installID = installID }
        else {
            let key = "walkie.install.id"
            let id = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
            UserDefaults.standard.set(id, forKey: key)
            self.installID = id
        }
    }
    func record(_ type: String, screen: String? = nil, payload: [String: String] = [:]) async throws {
        guard ClientTelemetryType(rawValue: type) != nil else { throw URLError(.dataNotAllowed) }
        guard enabled else { return }
        // Coordinates and raw research data have a separate local-only journal.
        let forbidden = ["latitude", "longitude", "lat", "lon", "gps", "track", "access_token", "refresh_token"]
        guard payload.keys.allSatisfy({ !forbidden.contains($0.lowercased()) }) else { throw URLError(.dataNotAllowed) }
        let owner = await self.owner()
        var events = try pending()
        var event = ClientTelemetryEvent(id: UUID(), type: type,
            device_ts: ISO8601DateFormatter().string(from: Date()), install_id: installID,
            screen: screen, payload: payload, owner_user_id: owner)
        event.route_id = payload["route_id"]
        event.route_version_id = payload["route_version_id"]
        event.walk_id = payload["walk_id"]
        event.group_id = payload["group_id"]
        events.append(event)
        try save(events)
    }
    func pending() throws -> [ClientTelemetryEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([ClientTelemetryEvent].self, from: Data(contentsOf: url))
    }
    func flush() async throws {
        guard enabled else { return }
        guard !sending else { return }
        sending = true; defer { sending = false }
        let owner = await self.owner()
        // Pre-login events stay anonymous, even after login. They must not wait
        // for logout or be silently reassigned to the newly signed-in person.
        var owners: [String?] = [nil]
        if let owner { owners.append(owner) }
        for batchOwner in owners {
            let batch = Array(try pending().filter { $0.owner_user_id == batchOwner }.prefix(100))
            guard !batch.isEmpty else { continue }
            let wire = try batch.map { event -> [String: Any] in
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as! [String: Any]
                object.removeValue(forKey: "owner_user_id")
                return object
            }
            let data = try JSONSerialization.data(withJSONObject: ["events": wire])
            if let batchOwner {
                guard await self.owner() == batchOwner else { throw URLError(.userAuthenticationRequired) }
                if let backend = client as? BackendClient {
                    _ = try await backend.request(path: "/v1/events", method: "POST", body: data,
                        authenticated: true, expectedUserID: batchOwner)
                } else {
                    _ = try await client.request(path: "/v1/events", method: "POST", body: data, authenticated: true)
                }
                guard await self.owner() == batchOwner else { throw URLError(.userAuthenticationRequired) }
            } else {
                _ = try await client.request(path: "/v1/events", method: "POST", body: data, authenticated: false)
            }
            let acknowledged = Set(batch.map(\.id))
            try save(pending().filter { !acknowledged.contains($0.id) })
        }
    }
    private func save(_ events: [ClientTelemetryEvent]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(events).write(to: url, options: .atomic)
    }
}
