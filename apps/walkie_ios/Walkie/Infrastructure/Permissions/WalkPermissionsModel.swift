import Combine
import Foundation

enum WalkPermission: String, CaseIterable, Identifiable, Sendable {
    case location, motion
    var id: String { rawValue }
}

enum WalkPermissionStatus: Equatable, Sendable {
    case notDetermined, granted, approximate, denied, restricted, unavailable
    var isPreviouslyDenied: Bool { self == .denied || self == .restricted }
    var permitsLocation: Bool { self == .granted || self == .approximate }
}

@MainActor
protocol WalkPermissionsClient: AnyObject {
    func status(for permission: WalkPermission) -> WalkPermissionStatus
    /// Calling this is an explicit user action; constructing/reading the client never prompts.
    func request(_ permission: WalkPermission) async -> WalkPermissionStatus
    func openSettings()
}

enum WalkPermissionsOutcome: Equatable {
    case ready
    case locationUnavailable
}

enum WalkPermissionPurpose: String, Sendable {
    case walkStart = "walk_start"
    case routeOrigin = "route_origin"
}

/// S-07 decision state is independent from sensors, Keychain, account state and network.
@MainActor
final class WalkPermissionsViewModel: ObservableObject {
    @Published private(set) var current: WalkPermission?
    @Published private(set) var status = WalkPermissionStatus.notDetermined
    @Published private(set) var isRequesting = false
    @Published private(set) var outcome: WalkPermissionsOutcome?
    @Published private(set) var errorMessage: String?
    private let client: any WalkPermissionsClient
    private let telemetry: any ProductTelemetryRecording
    private let purpose: WalkPermissionPurpose
    private var started = false
    private var openedSettings = false
    private var shown: Set<WalkPermission> = []
    private var resolved: Set<WalkPermission> = []

    init(client: any WalkPermissionsClient, telemetry: any ProductTelemetryRecording, purpose: WalkPermissionPurpose = .walkStart) {
        self.client = client
        self.telemetry = telemetry
        self.purpose = purpose
    }

    func begin() async {
        guard !started else { return }
        started = true
        await showOrAdvance(.location)
    }

    func allow() async {
        guard !isRequesting, let current, outcome == nil else { return }
        let latest = client.status(for: current)
        status = latest
        if latest == .notDetermined {
            isRequesting = true
            status = await client.request(current)
            isRequesting = false
            guard status != .notDetermined else {
                errorMessage = "iPhone пока не вернул ответ на запрос. Можно повторить или выбрать «Не сейчас»."
                return
            }
            errorMessage = nil
            await finishCurrent(result: telemetryResult(status))
        } else if latest == .granted {
            await finishCurrent(result: "granted")
        } else {
            // Denied/restricted and approximate authorization can only be changed by iOS Settings.
            openedSettings = true
            client.openSettings()
        }
    }

    func notNow() async {
        guard !isRequesting, current != nil, outcome == nil else { return }
        await finishCurrent(result: "not_now")
    }

    func continueWithApproximateLocation() async {
        guard current == .location, !isRequesting, outcome == nil else { return }
        status = client.status(for: .location)
        guard status == .approximate || status == .granted else { return }
        await finishCurrent(result: telemetryResult(status))
    }

    func refreshAfterSettings() async {
        guard openedSettings, let current, !isRequesting, outcome == nil else { return }
        openedSettings = false
        status = client.status(for: current)
        if status == .granted { await finishCurrent(result: "granted") }
        // Staying denied/approximate is displayed honestly; a result is recorded only
        // when the user chooses to continue or skip, rather than inventing a grant.
    }

    private func showOrAdvance(_ permission: WalkPermission) async {
        status = client.status(for: permission)
        if status == .granted {
            if permission == .location && purpose == .walkStart { await showOrAdvance(.motion) }
            else { current = nil; outcome = .ready }
            return
        }
        current = permission
        if shown.insert(permission).inserted {
            try? await telemetry.record("permission_prompt_shown", screen: "S-07", payload: [
                "permission": permission.rawValue,
                "previously_denied": status.isPreviouslyDenied ? "true" : "false",
                "purpose": purpose.rawValue
            ])
        }
    }

    private func finishCurrent(result: String) async {
        guard let permission = current, resolved.insert(permission).inserted else { return }
        try? await telemetry.record("permission_result", screen: "S-07", payload: [
            "permission": permission.rawValue, "result": result, "purpose": purpose.rawValue
        ])
        if permission == .location {
            // Not-now must not fall through into SensorService's system permission request.
            guard result != "not_now", status.permitsLocation else {
                current = nil
                outcome = .locationUnavailable
                return
            }
            if purpose == .walkStart { await showOrAdvance(.motion) }
            else { current = nil; outcome = .ready }
        } else {
            current = nil
            outcome = .ready // The walk works without motion; missing steps are not zero steps.
        }
    }

    private func telemetryResult(_ status: WalkPermissionStatus) -> String {
        switch status {
        case .granted: return "granted"
        case .approximate: return "approximate"
        case .notDetermined, .denied, .restricted, .unavailable: return "denied"
        }
    }
}
