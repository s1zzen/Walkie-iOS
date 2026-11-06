import Foundation
import XCTest
@testable import Walkie

final class WalkPermissionsTests: XCTestCase {
    @MainActor
    func testConstructionAndExplanationNeverRequestSystemPermission() async {
        let client = PermissionClientFixture(location: .notDetermined, motion: .notDetermined)
        let telemetry = PermissionTelemetryFixture()
        let model = WalkPermissionsViewModel(client: client, telemetry: telemetry)
        XCTAssertNil(model.current)
        XCTAssertTrue(client.requests.isEmpty)
        await model.begin()
        await model.begin()
        XCTAssertEqual(model.current, .location)
        XCTAssertTrue(client.requests.isEmpty)
        let events = await telemetry.events
        XCTAssertEqual(events.map(\.type), ["permission_prompt_shown"])
        XCTAssertEqual(events.first?.payload["permission"], "location")
    }

    @MainActor
    func testLocationNotNowBlocksSensorStartAndLogsOnlyOneResult() async {
        let client = PermissionClientFixture(location: .notDetermined, motion: .notDetermined)
        let telemetry = PermissionTelemetryFixture()
        let model = WalkPermissionsViewModel(client: client, telemetry: telemetry)
        await model.begin()
        await model.notNow()
        await model.notNow()
        XCTAssertEqual(model.outcome, .locationUnavailable)
        XCTAssertTrue(client.requests.isEmpty)
        let events = await telemetry.events
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.payload["result"], "not_now")
    }

    @MainActor
    func testExplicitAllowIsTheOnlySystemRequestAndMotionDenialDegrades() async {
        let client = PermissionClientFixture(location: .notDetermined, motion: .notDetermined)
        client.responses = [.location: .granted, .motion: .denied]
        let telemetry = PermissionTelemetryFixture()
        let model = WalkPermissionsViewModel(client: client, telemetry: telemetry)
        await model.begin()
        await model.allow()
        XCTAssertEqual(model.current, .motion)
        XCTAssertNil(model.outcome)
        XCTAssertEqual(client.requests, [.location])
        await model.allow()
        XCTAssertEqual(client.requests, [.location, .motion])
        XCTAssertEqual(model.outcome, .ready)
        let events = await telemetry.events
        XCTAssertEqual(events.filter { $0.type == "permission_prompt_shown" }.count, 2)
        XCTAssertEqual(events.filter { $0.type == "permission_result" }.map { $0.payload["result"] }, ["granted", "denied"])
    }

    @MainActor
    func testExistingGrantsDoNotShowOrRequestAgain() async {
        let client = PermissionClientFixture(location: .granted, motion: .granted)
        let telemetry = PermissionTelemetryFixture()
        let model = WalkPermissionsViewModel(client: client, telemetry: telemetry)
        await model.begin()
        XCTAssertEqual(model.outcome, .ready)
        XCTAssertNil(model.current)
        XCTAssertTrue(client.requests.isEmpty)
        let events = await telemetry.events
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testPreviouslyDeniedShowsSettingsAndNeverPretendsItWasGranted() async {
        let client = PermissionClientFixture(location: .denied, motion: .granted)
        let telemetry = PermissionTelemetryFixture()
        let model = WalkPermissionsViewModel(client: client, telemetry: telemetry)
        await model.begin()
        await model.allow()
        await model.refreshAfterSettings()
        XCTAssertEqual(client.settingsOpens, 1)
        XCTAssertTrue(client.requests.isEmpty)
        XCTAssertNil(model.outcome)
        var events = await telemetry.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.payload["previously_denied"], "true")
        await model.notNow()
        events = await telemetry.events
        XCTAssertEqual(events.last?.payload["result"], "not_now")
        XCTAssertEqual(model.outcome, .locationUnavailable)
    }

    @MainActor
    func testApproximateResultIsPreservedAndUnavailableMotionCanBeSkipped() async {
        let client = PermissionClientFixture(location: .approximate, motion: .unavailable)
        let telemetry = PermissionTelemetryFixture()
        let model = WalkPermissionsViewModel(client: client, telemetry: telemetry)
        await model.begin()
        await model.continueWithApproximateLocation()
        XCTAssertEqual(model.current, .motion)
        await model.notNow()
        XCTAssertEqual(model.outcome, .ready)
        XCTAssertTrue(client.requests.isEmpty)
        let events = await telemetry.events
        XCTAssertEqual(events.filter { $0.type == "permission_result" }.map { $0.payload["result"] }, ["approximate", "not_now"])
    }

    @MainActor
    func testSettingsReturnUsesActualNewStatus() async {
        let client = PermissionClientFixture(location: .approximate, motion: .granted)
        let telemetry = PermissionTelemetryFixture()
        let model = WalkPermissionsViewModel(client: client, telemetry: telemetry)
        await model.begin()
        await model.allow()
        XCTAssertNil(model.outcome)
        client.statuses[.location] = .granted
        await model.refreshAfterSettings()
        XCTAssertEqual(model.outcome, .ready)
        let events = await telemetry.events
        XCTAssertEqual(events.last?.payload["result"], "granted")
    }

    @MainActor
    func testRouteOriginRequestsOnlyLocationAndNeverMotion() async {
        let client = PermissionClientFixture(location: .notDetermined, motion: .notDetermined)
        client.responses[.location] = .granted
        let telemetry = PermissionTelemetryFixture()
        let model = WalkPermissionsViewModel(client: client, telemetry: telemetry, purpose: .routeOrigin)
        await model.begin()
        await model.allow()
        XCTAssertEqual(model.outcome, .ready)
        XCTAssertEqual(client.requests, [.location])
        let events = await telemetry.events
        XCTAssertEqual(events.map { $0.payload["permission"] }, ["location", "location"])
        XCTAssertTrue(events.allSatisfy { $0.payload["purpose"] == "route_origin" })
    }
}

@MainActor
private final class PermissionClientFixture: WalkPermissionsClient {
    var statuses: [WalkPermission: WalkPermissionStatus]
    var responses: [WalkPermission: WalkPermissionStatus] = [:]
    private(set) var requests: [WalkPermission] = []
    private(set) var settingsOpens = 0
    init(location: WalkPermissionStatus, motion: WalkPermissionStatus) { statuses = [.location: location, .motion: motion] }
    func status(for permission: WalkPermission) -> WalkPermissionStatus { statuses[permission] ?? .unavailable }
    func request(_ permission: WalkPermission) async -> WalkPermissionStatus {
        requests.append(permission)
        let response = responses[permission] ?? status(for: permission)
        statuses[permission] = response
        return response
    }
    func openSettings() { settingsOpens += 1 }
}

private actor PermissionTelemetryFixture: ProductTelemetryRecording {
    struct Event: Sendable { let type: String; let payload: [String: String] }
    private(set) var events: [Event] = []
    func record(_ type: String, screen: String?, payload: [String: String]) async throws {
        events.append(.init(type: type, payload: payload))
    }
}
