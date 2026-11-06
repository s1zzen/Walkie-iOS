import Foundation

/// Account effects are injectable; a profile test never needs the real Keychain.
protocol AccountBackendClient: Sendable {
    var baseURL: URL { get async }
    func currentSession() async -> BackendSession?
    func request(path: String, method: String, body: Data?, expectedUserID: String) async throws -> Data
    /// Clears both account and transient registration credentials only if this
    /// is still the identity captured by the caller.
    func clearSession(expectedUserID: String?) async throws
    func revokeSession(_ capturedSession: BackendSession) async
}

extension BackendClient: AccountBackendClient {
    func request(path: String, method: String, body: Data?, expectedUserID: String) async throws -> Data {
        try await request(path: path, method: method, body: body, authenticated: true, expectedUserID: expectedUserID)
    }

    func clearSession(expectedUserID: String?) throws {
        guard currentSession()?.user_id == expectedUserID else { throw URLError(.userAuthenticationRequired) }
        // No suspension between the owner check and credential changes.
        try BackendKeychain.set(nil, for: "registration_token")
        try clearSession()
    }

    func revokeSession(_ capturedSession: BackendSession) async {
        guard (try? Self.validateTransport(baseURL, allowsInsecureHTTP: allowsInsecureHTTP)) != nil else { return }
        guard let url = URL(string: baseURL.absoluteString + "/v1/auth/logout") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("Bearer \(capturedSession.access_token)", forHTTPHeaderField: "Authorization")
        _ = try? await URLSession.shared.data(for: request)
    }
}
