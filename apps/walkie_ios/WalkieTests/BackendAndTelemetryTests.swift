import XCTest
@testable import Walkie

final class BackendAndTelemetryTests: XCTestCase {
    func testKnownAndUnknownBackendErrorsNeverExposeRawServerText() throws {
        for (code, message) in BackendProblem.messages {
            let problem = BackendProblem(code: code, detail: "internal debug details")
            XCTAssertEqual(userFacingError(problem), message)
            XCTAssertNotEqual(message, code)
        }
        let unknown = BackendProblem(status: 503, code: "future_internal_error", detail: "secret debug response")
        XCTAssertFalse(userFacingError(unknown).contains("secret"))
        XCTAssertFalse(userFacingError(unknown).contains("future_internal_error"))
        XCTAssertEqual(userFacingError(BackendProblem(title: "route_not_feasible")), BackendProblem.messages["route_not_feasible"])
    }

    func testNetworkAndUnexpectedErrorsHaveActionableRussianMessages() {
        XCTAssertTrue(userFacingError(URLError(.notConnectedToInternet)).contains("интернет"))
        XCTAssertTrue(userFacingError(URLError(.timedOut)).contains("вовремя"))
        XCTAssertTrue(userFacingError(URLError(.userAuthenticationRequired)).contains("Войди"))
        XCTAssertTrue(userFacingError(URLError(.appTransportSecurityRequiresSecureConnection)).contains("безопасное"))
        XCTAssertFalse(userFacingError(NSError(domain: "internal", code: 999, userInfo: [NSLocalizedDescriptionKey: "raw internal text"])).contains("raw"))
    }

    func testOutboxPersistsStableIDsAcrossInstances() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("events.json")
        let first = makeQueue(url)
        try await first.record("pro_shown", screen: "S-45", payload: ["entry": "profile"])
        let stored = try await first.pending()
        let restored = try await makeQueue(url).pending()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.id, restored.first?.id)
        XCTAssertEqual(restored.first?.payload["entry"], "profile")
    }

    func testOutboxRejectsRawGPSAndSecretsBeforeWriting() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("events.json")
        let queue = makeQueue(url)
        for field in ["latitude", "longitude", "track", "access_token"] {
            do { try await queue.record("route_shown", payload: [field: "private"]); XCTFail("Accepted \(field)") }
            catch { XCTAssertEqual((error as? URLError)?.code, .dataNotAllowed) }
        }
        let pending = try await queue.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testBackendCannotCallTrackOrExternalURL() async throws {
        let client = BackendClient()
        for path in ["/v1/walks/123/track", "/v1/walks/123/return-path", "https://example.com", "/v1/../private"] {
            do { _ = try await client.request(path: path, authenticated: false); XCTFail("Allowed \(path)") }
            catch { XCTAssertEqual((error as? URLError)?.code, .unsupportedURL) }
        }
    }

    func testCorruptOutboxIsNotReplacedByEmptyEvents() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = Data("not-json".utf8)
        try original.write(to: url)
        do { try await makeQueue(url).record("pro_shown"); XCTFail("Overwrote corrupt journal") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testServerEventsCannotBeDuplicatedThroughClientQueue() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = makeQueue(url)
        do { try await queue.record("walk_completed"); XCTFail("Accepted a server-only event") }
        catch { XCTAssertEqual((error as? URLError)?.code, .dataNotAllowed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testRouteIdentifiersArePromotedForServerAttribution() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = makeQueue(url)
        let route = UUID().uuidString, version = UUID().uuidString
        try await queue.record("route_shown", payload: ["route_id": route, "route_version_id": version])
        let event = try await queue.pending().first
        XCTAssertEqual(event?.route_id, route)
        XCTAssertEqual(event?.route_version_id, version)
    }

    func testOfflineBatchRetriesOriginalEventIDsAfterRestartWithoutGPSOrLocalOwner() async throws {
        let url = testURL()
        let offline = FakeTelemetryTransport(failures: 1)
        let queue = makeQueue(url, client: offline, owner: { "test-owner" })
        let routeID = UUID().uuidString, versionID = UUID().uuidString, walkID = UUID().uuidString
        try await queue.record("off_route_reaction", screen: "S-23", payload: [
            "route_id": routeID, "route_version_id": versionID, "walk_id": walkID, "action": "reroute"])
        let originalPending = try await queue.pending()
        let original = try XCTUnwrap(originalPending.first)
        do { try await queue.flush(); XCTFail("An offline request was accepted") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let online = FakeTelemetryTransport()
        let restored = makeQueue(url, client: online, owner: { "test-owner" })
        try await restored.flush()
        let calls = await online.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.path, "/v1/events")
        XCTAssertEqual(calls.first?.method, "POST")
        XCTAssertEqual(calls.first?.authenticated, true)
        let events = try wireEvents(try XCTUnwrap(calls.first?.body))
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event["id"] as? String, original.id.uuidString)
        XCTAssertEqual(event["type"] as? String, "off_route_reaction")
        XCTAssertEqual(event["route_id"] as? String, routeID)
        XCTAssertEqual(event["route_version_id"] as? String, versionID)
        XCTAssertEqual(event["walk_id"] as? String, walkID)
        XCTAssertEqual(event["screen"] as? String, "S-23")
        XCTAssertNil(event["owner_user_id"])
        let payload = try XCTUnwrap(event["payload"] as? [String: String])
        XCTAssertEqual(payload["action"], "reroute")
        let body = String(data: try XCTUnwrap(calls.first?.body), encoding: .utf8) ?? ""
        for field in ["latitude", "longitude", "track", "access_token", "refresh_token", "owner_user_id"] { XCTAssertFalse(body.contains(field)) }
        let pending = try await restored.pending()
        XCTAssertTrue(pending.isEmpty)
    }

    func testNewEventWrittenDuringFlushSurvivesAcknowledgementOfEarlierBatch() async throws {
        let url = testURL()
        let transport = FakeTelemetryTransport(holdFirstRequest: true)
        let queue = makeQueue(url, client: transport, owner: { "test-owner" })
        try await queue.record("network_lost", payload: ["walk_id": UUID().uuidString])
        let firstPending = try await queue.pending()
        let first = try XCTUnwrap(firstPending.first)
        let flush = Task { try await queue.flush() }
        await transport.waitUntilRequestArrives()
        try await queue.record("network_restored", payload: ["walk_id": first.walk_id ?? ""])
        await transport.releaseFirstRequest()
        try await flush.value
        let pending = try await queue.pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.type, "network_restored")
        XCTAssertNotEqual(pending.first?.id, first.id)
        try await queue.flush()
        let finalPending = try await queue.pending()
        XCTAssertTrue(finalPending.isEmpty)
    }

    func testAnonymousLoginBatchRemainsAnonymousAfterLogin() async throws {
        let url = testURL()
        let identity = FakeTelemetryOwner()
        let transport = FakeTelemetryTransport()
        let queue = makeQueue(url, client: transport, owner: { await identity.read() })
        try await queue.record("login_method_selected", screen: "S-02", payload: ["method": "email"])
        await identity.set("signed-in-owner")
        try await queue.record("route_shown", screen: "S-18", payload: ["route_id": UUID().uuidString])
        try await queue.flush()
        let calls = await transport.calls
        XCTAssertEqual(calls.map(\.authenticated), [false, true])
        let anonymous = try XCTUnwrap(try wireEvents(try XCTUnwrap(calls.first?.body)).first)
        XCTAssertEqual(anonymous["type"] as? String, "login_method_selected")
        XCTAssertNotNil(UUID(uuidString: anonymous["install_id"] as? String ?? ""))
        XCTAssertNil(anonymous["owner_user_id"])
        let authenticated = try XCTUnwrap(try wireEvents(try XCTUnwrap(calls.last?.body)).first)
        XCTAssertEqual(authenticated["type"] as? String, "route_shown")
        XCTAssertNil(authenticated["owner_user_id"])
    }

    func testDisabledQueueNeverTouchesOwnerTransportOrFile() async throws {
        let url = testURL()
        let identity = FakeTelemetryOwner()
        let transport = FakeTelemetryTransport()
        let queue = makeQueue(url, client: transport, owner: { await identity.read() }, enabled: false)
        try await queue.record("permission_prompt_shown", payload: ["permission": "location"])
        try await queue.flush()
        let ownerReads = await identity.reads
        let calls = await transport.calls
        XCTAssertEqual(ownerReads, 0)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    private func makeQueue(_ url: URL, client: any RouteBackendTransport = FakeTelemetryTransport(),
                           owner: @escaping @Sendable () async -> String? = { nil }, enabled: Bool = true) -> TelemetryQueue {
        TelemetryQueue(url: url, client: client, respectsDemoMode: false, enabled: enabled, owner: owner,
            installID: "0FC1311F-656C-412D-80A0-BF2368EFEBB7")
    }
    private func testURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("events.json")
    }
    private func wireEvents(_ body: Data) throws -> [[String: Any]] {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(object["events"] as? [[String: Any]])
    }
}

private actor FakeTelemetryOwner {
    private var value: String?
    private(set) var reads = 0
    func read() -> String? { reads += 1; return value }
    func set(_ value: String?) { self.value = value }
}

private actor FakeTelemetryTransport: RouteBackendTransport {
    struct Call: Sendable { let path: String; let method: String; let body: Data?; let authenticated: Bool }
    private(set) var calls: [Call] = []
    private var failures: Int
    private var holdFirstRequest: Bool
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    init(failures: Int = 0, holdFirstRequest: Bool = false) { self.failures = failures; self.holdFirstRequest = holdFirstRequest }
    func request(path: String, method: String, body: Data?, authenticated: Bool) async throws -> Data {
        calls.append(Call(path: path, method: method, body: body, authenticated: authenticated))
        requestWaiter?.resume(); requestWaiter = nil
        if holdFirstRequest {
            holdFirstRequest = false
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        if failures > 0 { failures -= 1; throw URLError(.notConnectedToInternet) }
        return Data() // Contract /events responds 204 without a response body.
    }
    func waitUntilRequestArrives() async {
        guard calls.isEmpty else { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }
    func releaseFirstRequest() { releaseWaiter?.resume(); releaseWaiter = nil }
}
