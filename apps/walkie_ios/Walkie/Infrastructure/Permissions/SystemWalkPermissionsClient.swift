import CoreLocation
import CoreMotion
import UIKit

/// Requests permissions without starting route recording or background sensor updates.
@MainActor
final class SystemWalkPermissionsClient: NSObject, WalkPermissionsClient, @preconcurrency CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private let motion = CMPedometer()
    private var locationContinuation: CheckedContinuation<WalkPermissionStatus, Never>?

    override init() {
        super.init()
        location.delegate = self
    }

    func status(for permission: WalkPermission) -> WalkPermissionStatus {
        switch permission {
        case .location:
            switch location.authorizationStatus {
            case .notDetermined: return .notDetermined
            case .authorizedWhenInUse, .authorizedAlways:
                return location.accuracyAuthorization == .reducedAccuracy ? .approximate : .granted
            case .denied: return .denied
            case .restricted: return .restricted
            @unknown default: return .unavailable
            }
        case .motion:
            guard CMPedometer.isStepCountingAvailable() else { return .unavailable }
            switch CMPedometer.authorizationStatus() {
            case .notDetermined: return .notDetermined
            case .authorized: return .granted
            case .denied: return .denied
            case .restricted: return .restricted
            @unknown default: return .unavailable
            }
        }
    }

    func request(_ permission: WalkPermission) async -> WalkPermissionStatus {
        let existing = status(for: permission)
        guard existing == .notDetermined else { return existing }
        switch permission {
        case .location:
            guard locationContinuation == nil else { return status(for: .location) }
            return await withCheckedContinuation { continuation in
                locationContinuation = continuation
                location.requestWhenInUseAuthorization()
            }
        case .motion:
            // A one-shot query invokes iOS's permission dialog. There is no active
            // pedometer stream until the user starts the walk after S-07.
            return await withCheckedContinuation { continuation in
                let end = Date()
                motion.queryPedometerData(from: end.addingTimeInterval(-1), to: end) { [weak self] _, _ in
                    Task { @MainActor in
                        continuation.resume(returning: self?.status(for: .motion) ?? .unavailable)
                    }
                }
            }
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let result = status(for: .location)
        guard result != .notDetermined, let continuation = locationContinuation else { return }
        locationContinuation = nil
        continuation.resume(returning: result)
    }
}
