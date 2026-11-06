import Foundation
import XCTest
@testable import Walkie

@MainActor
final class AccountViewModelTests: XCTestCase {
    func testRefreshPublishesServerConfigurationInsteadOfDiscardingThresholds() async throws {
        let backend = FakeAccountBackend()
        let model = AccountViewModel(client: backend, isOfflineDemo: false, onLocalModeExited: {})
        await model.refresh()
        XCTAssertTrue(model.hasSession)
        XCTAssertEqual(model.info?.display_name, "Тестовый пользователь")
        XCTAssertEqual(model.configuration?.generation_long_wait_s, 71)
        XCTAssertEqual(model.configuration?.inactivity_timeout_s, 1_200)
        XCTAssertEqual(model.configuration?.protocol_version, "review-test")
        XCTAssertTrue(model.socialEnabled)
        XCTAssertNil(model.errorMessage)
        let requests = await backend.requests
        XCTAssertEqual(requests, ["GET /v1/me", "GET /v1/config", "GET /v1/me/settings"])
    }

    func testNetworkFailurePreservesExistingSessionAndLastValidatedConfiguration() async throws {
        let backend = FakeAccountBackend()
        let model = AccountViewModel(client: backend, isOfflineDemo: false, onLocalModeExited: {})
        await model.refresh()
        let previous = model.configuration
        await backend.setFailure(.offline)
        await model.refresh()
        XCTAssertTrue(model.hasSession)
        XCTAssertEqual(model.configuration, previous)
        XCTAssertNotNil(model.errorMessage)
        let clears = await backend.clearCount
        XCTAssertEqual(clears, 0)
    }

    func testFrozenDemoEnvironmentNeverReadsSessionOrTouchesNetworkAndKeychainBoundary() async throws {
        let backend = FakeAccountBackend()
        var localExits = 0
        let model = AccountViewModel(client: backend, isOfflineDemo: true, onLocalModeExited: { localExits += 1 })
        await model.refresh()
        let settingsSaved = await model.saveSettings()
        let subscribed = await model.subscribe(entry: "profile")
        let deletion = await model.signOut(deleteAccount: true)
        let logout = await model.signOut()
        XCTAssertFalse(settingsSaved)
        XCTAssertFalse(subscribed)
        XCTAssertFalse(deletion)
        XCTAssertTrue(logout)
        XCTAssertEqual(localExits, 1)
        XCTAssertTrue(model.isOfflineDemo) // A new account scope selects the next environment.
        XCTAssertFalse(model.hasSession)
        XCTAssertNil(model.configuration)
        let reads = await backend.sessionReads
        let requests = await backend.requests
        let clears = await backend.clearCount
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(clears, 0)
    }

    func testTerminalUnauthorizedClearsOnlyCapturedSessionThroughInjectedBoundary() async throws {
        let backend = FakeAccountBackend()
        let model = AccountViewModel(client: backend, isOfflineDemo: false, onLocalModeExited: {})
        await model.refresh()
        await backend.setFailure(.unauthorized)
        await model.refresh()
        XCTAssertFalse(model.hasSession)
        XCTAssertNil(model.info)
        XCTAssertNil(model.configuration)
        XCTAssertNotNil(model.errorMessage)
        let clearedOwners = await backend.clearedOwners
        XCTAssertEqual(clearedOwners, ["test-owner"])
    }

    func testOfflineLogoutCompletesLocallyButFailedDeletionDoesNotClaimDeletion() async throws {
        let logoutBackend = FakeAccountBackend()
        await logoutBackend.setFailure(.offline)
        let logoutModel = AccountViewModel(client: logoutBackend, isOfflineDemo: false, onLocalModeExited: {})
        let logout = await logoutModel.signOut()
        XCTAssertTrue(logout)
        XCTAssertFalse(logoutModel.hasSession)
        let logoutClears = await logoutBackend.clearCount
        XCTAssertEqual(logoutClears, 1)

        let deletionBackend = FakeAccountBackend()
        let deletionModel = AccountViewModel(client: deletionBackend, isOfflineDemo: false, onLocalModeExited: {})
        await deletionModel.refresh()
        await deletionBackend.setFailure(.offline)
        let deletion = await deletionModel.signOut(deleteAccount: true)
        XCTAssertFalse(deletion)
        XCTAssertTrue(deletionModel.hasSession)
        XCTAssertNotNil(deletionModel.errorMessage)
        let deletionClears = await deletionBackend.clearCount
        XCTAssertEqual(deletionClears, 0)
    }
}

private actor FakeAccountBackend: AccountBackendClient {
    enum Failure: Sendable { case offline, unauthorized }
    nonisolated let baseURL = URL(string: "https://example.invalid/api")!
    private var session: BackendSession? = BackendSession(access_token: "fake-access", refresh_token: "fake-refresh",
        expires_at: "2030-01-01T00:00:00Z", user_id: "test-owner")
    private var failure: Failure?
    private(set) var sessionReads = 0
    private(set) var requests: [String] = []
    private(set) var clearCount = 0
    private(set) var clearedOwners: [String] = []
    private(set) var revokedOwners: [String] = []

    func setFailure(_ failure: Failure?) { self.failure = failure }
    func currentSession() -> BackendSession? { sessionReads += 1; return session }
    func request(path: String, method: String, body: Data?, expectedUserID: String) async throws -> Data {
        requests.append("\(method) \(path)")
        guard session?.user_id == expectedUserID else { throw URLError(.userAuthenticationRequired) }
        if let failure {
            switch failure {
            case .offline: throw URLError(.notConnectedToInternet)
            case .unauthorized: throw BackendProblem(status: 401, code: "invalid_session")
            }
        }
        switch path {
        case "/v1/me":
            return Data(#"{"id":"test-owner","display_name":"Тестовый пользователь","context_branch":"C0","stats":{"walks_completed":1,"distance_total_m":100,"steps_week":0,"rating_avg":null},"pro":{"in_early_access":false}}"#.utf8)
        case "/v1/config":
            return Data(#"{"features":{"social_enabled":true},"generation_long_wait_s":71,"inactivity_timeout_s":1200,"protocol_version":"review-test"}"#.utf8)
        case "/v1/me/settings": return try JSONEncoder().encode(AccountSettings())
        default: return Data("{}".utf8)
        }
    }
    func clearSession(expectedUserID: String?) throws {
        guard session?.user_id == expectedUserID else { throw URLError(.userAuthenticationRequired) }
        if let expectedUserID { clearedOwners.append(expectedUserID) }
        clearCount += 1
        session = nil
    }
    func revokeSession(_ capturedSession: BackendSession) { revokedOwners.append(capturedSession.user_id) }
}
