import CoreLocation
import Foundation
import WalkieCore

struct SensorObservation {
    let coordinate: Coordinate
    let accuracy: Double
    let observedAt: Date
    let receivedAt: Date
    let monotonicTime: Double
}

@MainActor
protocol SensorSource: AnyObject {
    var onObservation: ((SensorObservation) -> Void)? { get set }
    var onStatus: ((String) -> Void)? { get set }
    func start()
    func stop()
}

/// У сервиса нет сетевых зависимостей. Разрешение запрашивается только при старте записи.
@MainActor
final class SensorService: NSObject, SensorSource, @preconcurrency CLLocationManagerDelegate {
    var onObservation: ((SensorObservation) -> Void)?
    var onStatus: ((String) -> Void)?
    private let manager = CLLocationManager()
    private var requested = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func start() {
        requested = true
        switch manager.authorizationStatus {
        case .notDetermined:
            onStatus?("Геолокация не разрешена. Доступ запрашивается только по кнопке на экране пояснения.")
        case .authorizedAlways, .authorizedWhenInUse:
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
            updateAccuracyStatus()
        case .denied, .restricted:
            onStatus?("Геолокация недоступна. Запись без координат; разрешение можно изменить в настройках iOS.")
        @unknown default:
            onStatus?("Неизвестное состояние геолокации")
        }
    }

    func stop() {
        requested = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard requested else { return }
        start()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard requested else { return }
        let receivedAt = Date()
        let monotonic = ProcessInfo.processInfo.systemUptime
        for location in locations {
            guard CLLocationCoordinate2DIsValid(location.coordinate),
                  location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0 else {
                onStatus?("Получено непригодное измерение; позиция неизвестна")
                continue
            }
            onObservation?(SensorObservation(
                coordinate: Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude),
                accuracy: location.horizontalAccuracy, observedAt: location.timestamp,
                receivedAt: receivedAt, monotonicTime: monotonic
            ))
        }
        updateAccuracyStatus()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard requested else { return }
        onStatus?("Позиция временно недоступна. Пропуски не означают движение или посещение места.")
    }

    private func updateAccuracyStatus() {
        onStatus?(manager.accuracyAuthorization == .fullAccuracy
            ? "Системные координаты могут быть ошибочными; это не проверенное положение."
            : "iOS передаёт приблизительное положение. Автоматические выводы недоступны.")
    }
}
