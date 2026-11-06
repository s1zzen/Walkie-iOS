import Foundation
import Combine
import CoreLocation
import CoreMotion
import UIKit

@MainActor
// CLLocationManager создаётся на главном потоке и вызывает delegate в его run loop.
final class FieldRecorder: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var isRecording = false
    @Published private(set) var latestLocation: LocationSample?
    @Published private(set) var results: [AlgorithmResult] = []
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var motion = MotionSnapshot.empty(at: 0)
    @Published private(set) var status = "Готов к записи"
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentFolder: URL?
    @Published private(set) var sessions: [URL] = []
    @Published private(set) var authorizationDescription = "Разрешение не запрошено"
    @Published private(set) var recordingWarning: String?

    private var locationManager: CLLocationManager!
    private let motionManager = CMMotionManager()
    private let pedometer = CMPedometer()
    private var timer: Timer?
    private var sessionToken: UUID?
    private let continuousClock = ContinuousClock()
    private var startedInstant: ContinuousClock.Instant?
    private var sensorEpochUptime: Double = 0
    private var lastMotionReceiptUptime: Double = 0
    private var lastMotionReceiptElapsed: Double = 0
    private var lastHeartbeat: Double = 0
    private var lastLocationReceived: Double?
    private var referenceFrameName = "unavailable"
    private var store: SessionStore?
    private var info: SessionInfo?
    private var engine: DetectorEngine?
    private var locationCount = 0
    private var markerCount = 0
    private var algorithmSummary: [String: AlgorithmSummary] = [:]
    private var previousResults: [AlgorithmResult] = []
    private var warnings: [String: String] = [:]

    override init() {
        super.init()
        replaceLocationManager()
        refreshSessions()
        updateAuthorization()
    }

    func requestPermissions() {
        locationManager.requestWhenInUseAuthorization()
        if CMPedometer.isStepCountingAvailable() {
            let now = Date()
            pedometer.queryPedometerData(from: now.addingTimeInterval(-1), to: now) { [weak self] _, _ in
                Task { @MainActor in self?.updateAuthorization() }
            }
        }
        updateAuthorization()
    }

    func start(route: TestRoute, name: String, notes: String) throws {
        guard !isRecording else { throw FieldLabError.message("Запись уже идёт.") }
        guard route.isValid else { throw FieldLabError.message("Для записи нужен маршрут как минимум из двух допустимых точек.") }
        guard CLLocationManager.locationServicesEnabled() else {
            throw FieldLabError.message("Включите службы геолокации в настройках iPhone.")
        }
        let authorization = locationManager.authorizationStatus
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            throw FieldLabError.message("Сначала разрешите доступ к геолокации при использовании приложения.")
        }
        let token = UUID()
        let configuration = DetectorConfiguration()
        var newInfo = SessionInfo(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? route.name : name,
                                  route: route, configuration: configuration,
                                  device: UIDevice.current.model, systemVersion: UIDevice.current.systemVersion,
                                  notes: notes)
        newInfo.interrupted = true
        let newStore = try SessionStore(info: newInfo) { [weak self] message in
            Task { @MainActor in self?.handleDiskError(message, token: token) }
        }
        sessionToken = token
        info = newInfo
        store = newStore
        currentFolder = newStore.folder
        engine = DetectorEngine(route: route, configuration: configuration)
        startedInstant = continuousClock.now
        sensorEpochUptime = ProcessInfo.processInfo.systemUptime
        lastMotionReceiptUptime = sensorEpochUptime
        lastMotionReceiptElapsed = 0
        lastHeartbeat = 0
        referenceFrameName = "unavailable"
        lastLocationReceived = nil
        elapsed = 0
        motion = .empty(at: 0)
        latestLocation = nil
        results = []
        previousResults = []
        algorithmSummary = [:]
        locationCount = 0
        markerCount = 0
        warnings = [:]
        recordingWarning = nil
        errorMessage = nil
        status = "Запись идёт"
        isRecording = true
        replaceLocationManager()
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .fitness
        locationManager.distanceFilter = kCLDistanceFilterNone
        locationManager.pausesLocationUpdatesAutomatically = false
        locationManager.allowsBackgroundLocationUpdates = true
        locationManager.showsBackgroundLocationIndicator = true
        updateAuthorization()
        event("session_started", details: [
            "clock": "ContinuousClock; seconds since session start, including device sleep",
            "motion_clock": "raw CM timestamp uses uptime; observation elapsed = continuous receipt elapsed - uptime age; detected clock discontinuity resets epoch and rejects earlier timestamps",
            "pedometer_clock": "endDate wall-clock age subtracted from continuous elapsed; invalid/future/pre-session observations have no freshness timestamp",
            "location_source": "Core Location fused location, not raw satellite measurements",
            "manual_markers": "observations only; never supplied to detector",
            "background": "foreground-started standard location updates; scheduling is controlled by iOS"
        ])
        event("capabilities", details: [
            "device_motion": String(motionManager.isDeviceMotionAvailable),
            "steps": String(CMPedometer.isStepCountingAvailable()),
            "distance": String(CMPedometer.isDistanceAvailable()),
            "cadence": String(CMPedometer.isCadenceAvailable()),
            "pace": String(CMPedometer.isPaceAvailable()),
            "floors": String(CMPedometer.isFloorCountingAvailable()),
            "authorization": authorizationDescription,
            "requested_motion_hz": "20",
            "motion_units": "acceleration/gravity: g; rotation rate: rad/s; Euler angles: rad; timestamp: seconds since boot"
        ])
        process(location: nil, trigger: "session_started")
        locationManager.startUpdatingLocation()
        startMotion(token: token, date: newInfo.startedAt)
        let newTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.sessionToken == token, self.isRecording else { return }
                self.heartbeat()
            }
        }
        timer = newTimer
        RunLoop.main.add(newTimer, forMode: .common)
        refreshSessions()
    }

    func stop() {
        guard isRecording else { return }
        elapsed = nowElapsed()
        event("session_stopped")
        accrueDurations(until: elapsed)
        stopSensors()
        info?.endedAt = Date()
        if let store, let info {
            do {
                try store.finish(info: info, summary: SessionSummary(duration: elapsed, locationCount: locationCount,
                                                                     markerCount: markerCount, algorithms: algorithmSummary))
                status = "Сессия сохранена"
            } catch {
                errorMessage = "Не удалось завершить сохранение: \(error.localizedDescription)"
                status = "Запись остановлена. Сессия помечена незавершённой"
            }
        }
        store = nil
        engine = nil
        refreshSessions()
    }

    func mark(_ kind: String, note: String = "") {
        guard isRecording else { return }
        markerCount += 1
        event("manual_marker", note: note, details: ["kind": kind, "origin": "user"])
    }

    func refreshSessions() { sessions = SessionStore.sessions() }

    func recordLifecycle(_ value: String) {
        guard isRecording else { return }
        event("lifecycle", details: ["state": value])
        if value == "background" {
            event("storage_flush_requested", details: ["reason": "entering_background"])
            do {
                // Дожидаемся ранее поставленных записей до возврата из lifecycle callback.
                try store?.flushIfNeeded(force: true)
            } catch {
                if let token = sessionToken {
                    handleDiskError("Не удалось сохранить данные при уходе в фон: \(error.localizedDescription)", token: token)
                }
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === locationManager else { return }
        updateAuthorization()
        guard isRecording else { return }
        event("location_authorization", details: ["value": authorizationDescription])
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            errorMessage = "Доступ к геолокации отозван. Сессия завершена."
            stop()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === locationManager, isRecording else { return }
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let received = Date()
            let at = nowElapsed()
            let point = GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            let validDate = location.timestamp.timeIntervalSince1970.isFinite
            let finiteAccuracy = location.horizontalAccuracy.isFinite
            let sample = point.isValid && validDate && finiteAccuracy ? LocationSample(
                elapsed: at, observedAt: location.timestamp, receivedAt: received,
                latitude: point.latitude, longitude: point.longitude,
                horizontalAccuracy: location.horizontalAccuracy,
                altitude: finite(location.altitude), verticalAccuracy: finite(location.verticalAccuracy),
                speed: finite(location.speed), speedAccuracy: finite(location.speedAccuracy),
                course: finite(location.course), courseAccuracy: finite(location.courseAccuracy),
                simulatedBySoftware: location.sourceInformation?.isSimulatedBySoftware,
                producedByAccessory: location.sourceInformation?.isProducedByAccessory
            ) : nil
            let raw = RawLocationRecord(elapsed: at, receivedAt: received,
                observedAt: validDate ? location.timestamp : nil,
                latitude: finite(point.latitude), longitude: finite(point.longitude),
                horizontalAccuracy: finite(location.horizontalAccuracy),
                altitude: finite(location.altitude), verticalAccuracy: finite(location.verticalAccuracy),
                speed: finite(location.speed), speedAccuracy: finite(location.speedAccuracy),
                course: finite(location.course), courseAccuracy: finite(location.courseAccuracy),
                simulatedBySoftware: location.sourceInformation?.isSimulatedBySoftware,
                producedByAccessory: location.sourceInformation?.isProducedByAccessory,
                coordinateValid: point.isValid,
                ageAtReceipt: validDate ? finite(received.timeIntervalSince(location.timestamp)) : nil)
            locationCount += 1
            lastLocationReceived = at
            store?.appendLocation(raw, gpxSample: location.horizontalAccuracy >= 0 ? sample : nil)
            if let sample {
                if latestLocation == nil || sample.observedAt >= latestLocation!.observedAt {
                    latestLocation = sample
                }
                process(location: sample, trigger: "location")
            } else {
                event(point.isValid ? "invalid_location" : "invalid_coordinate", details: ["coordinate_valid": String(point.isValid),
                      "timestamp_finite": String(validDate), "accuracy_finite": String(finiteAccuracy)])
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === locationManager, isRecording else { return }
        event("location_error", note: error.localizedDescription,
              details: ["code": String((error as NSError).code), "domain": (error as NSError).domain])
        setWarning("location", "Геолокация временно недоступна; запись и проверка пропусков продолжаются.")
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        guard manager === locationManager, isRecording else { return }
        event("location_updates_paused")
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        guard manager === locationManager, isRecording else { return }
        event("location_updates_resumed")
    }

    private func startMotion(token: UUID, date: Date) {
        if motionManager.isDeviceMotionAvailable {
            let available = CMMotionManager.availableAttitudeReferenceFrames()
            let choices: [(CMAttitudeReferenceFrame, String)] = [
                (.xArbitraryZVertical, "xArbitraryZVertical"),
                (.xArbitraryCorrectedZVertical, "xArbitraryCorrectedZVertical"),
                (.xMagneticNorthZVertical, "xMagneticNorthZVertical"),
                (.xTrueNorthZVertical, "xTrueNorthZVertical")
            ]
            if let choice = choices.first(where: { available.contains($0.0) }) {
                referenceFrameName = choice.1
                motionManager.deviceMotionUpdateInterval = 1.0 / 20.0
                motionManager.startDeviceMotionUpdates(using: choice.0, to: .main) { [weak self] data, error in
                    Task { @MainActor in
                        guard let self, self.isRecording, self.sessionToken == token else { return }
                        if let error {
                            self.event("motion_error", note: error.localizedDescription)
                            self.setWarning("motion", "Данные движения недоступны.")
                        }
                        if let data { self.receiveMotion(data) }
                    }
                }
            } else {
                setWarning("motion", "Система отсчёта Core Motion недоступна.")
            }
        } else {
            setWarning("motion", "Core Motion недоступен на этом устройстве.")
        }
        if CMPedometer.isStepCountingAvailable() {
            pedometer.startUpdates(from: date) { [weak self] data, error in
                Task { @MainActor in
                    guard let self, self.isRecording, self.sessionToken == token else { return }
                    if let error {
                        self.event("pedometer_error", note: error.localizedDescription)
                        self.setWarning("pedometer", "Данные шагомера недоступны.")
                    }
                    if let data { self.receivePedometer(data) }
                    self.updateAuthorization()
                }
            }
        } else {
            setWarning("pedometer", "Шагомер недоступен на этом устройстве.")
        }
        event("motion_reference_frame", details: ["frame": referenceFrameName,
              "meaning": "device orientation; not pedestrian heading"])
    }

    private func receiveMotion(_ data: CMDeviceMotion) {
        let received = Date()
        let at = nowElapsed()
        let receivedUptime = ProcessInfo.processInfo.systemUptime
        let continuousAdvance = at - lastMotionReceiptElapsed
        let uptimeAdvance = receivedUptime - lastMotionReceiptUptime
        if continuousAdvance - uptimeAdvance > 0.25 || uptimeAdvance < 0 {
            // После сна uptime не определяет возраст кадра из предыдущей эпохи.
            // Первый кадр после разрыва также консервативно остаётся только сырым наблюдением.
            sensorEpochUptime = receivedUptime
            event("motion_clock_epoch", details: [
                "continuous_advance": String(continuousAdvance), "uptime_advance": String(uptimeAdvance),
                "earliest_sensor_uptime": String(sensorEpochUptime)
            ])
        }
        lastMotionReceiptElapsed = at
        lastMotionReceiptUptime = receivedUptime
        let sensorAge = receivedUptime - data.timestamp
        motion.elapsed = at
        motion.accelerationX = finite(data.userAcceleration.x)
        motion.accelerationY = finite(data.userAcceleration.y)
        motion.accelerationZ = finite(data.userAcceleration.z)
        motion.rotationX = finite(data.rotationRate.x)
        motion.rotationY = finite(data.rotationRate.y)
        motion.rotationZ = finite(data.rotationRate.z)
        motion.roll = finite(data.attitude.roll)
        motion.pitch = finite(data.attitude.pitch)
        motion.yaw = finite(data.attitude.yaw)
        motion.motionUpdatedAt = data.timestamp >= sensorEpochUptime && sensorAge.isFinite && sensorAge >= 0
            ? boundedObservationElapsed(at - sensorAge, receivedElapsed: at) : nil
        store?.append(DeviceMotionRecord(kind: "device_motion", elapsed: at, receivedAt: received,
            sensorTimestamp: finite(data.timestamp), receivedUptime: finite(receivedUptime),
            sensorAgeAtReceipt: finite(sensorAge), clockEpochUptime: finite(sensorEpochUptime),
            referenceFrame: referenceFrameName,
            snapshot: motion, gravity: VectorRecord(x: finite(data.gravity.x), y: finite(data.gravity.y), z: finite(data.gravity.z)),
            quaternion: QuaternionRecord(x: finite(data.attitude.quaternion.x), y: finite(data.attitude.quaternion.y),
                                         z: finite(data.attitude.quaternion.z), w: finite(data.attitude.quaternion.w))),
            to: "motion.jsonl")
    }

    private func receivePedometer(_ data: CMPedometerData) {
        let received = Date()
        let at = nowElapsed()
        motion.elapsed = at
        motion.steps = data.numberOfSteps.doubleValue.isFinite ? data.numberOfSteps.intValue : nil
        motion.distance = data.distance.flatMap { finite($0.doubleValue) }
        motion.cadence = data.currentCadence.flatMap { finite($0.doubleValue) }
        // endDate относится к измерению; доставка после suspension не обновляет его возраст.
        let observationElapsed = at - received.timeIntervalSince(data.endDate)
        motion.pedometerUpdatedAt = boundedObservationElapsed(observationElapsed, receivedElapsed: at)
        store?.append(PedometerRecord(kind: "pedometer", elapsed: at, receivedAt: received,
            startDate: data.startDate.timeIntervalSince1970.isFinite ? data.startDate : nil,
            endDate: data.endDate.timeIntervalSince1970.isFinite ? data.endDate : nil,
            observationElapsed: motion.pedometerUpdatedAt, steps: motion.steps,
            distance: motion.distance, cadence: motion.cadence,
            currentPace: data.currentPace.flatMap { finite($0.doubleValue) },
            averageActivePace: data.averageActivePace.flatMap { finite($0.doubleValue) },
            floorsAscended: data.floorsAscended.flatMap { $0.doubleValue.isFinite ? $0.intValue : nil },
            floorsDescended: data.floorsDescended.flatMap { $0.doubleValue.isFinite ? $0.intValue : nil }), to: "motion.jsonl")
    }

    private func heartbeat() {
        let at = nowElapsed()
        if at - lastHeartbeat > 3 {
            event("callback_gap", details: ["seconds": String(at - lastHeartbeat),
                  "interpretation": "possible suspension or scheduling delay; exact cause unknown"])
            setWarning("scheduling", "Обнаружен перерыв выполнения: во время паузы предупреждения могли задерживаться.")
        }
        lastHeartbeat = at
        let sinceLocation = lastLocationReceived.map { at - $0 }
        event("heartbeat", details: [
            "seconds_since_location_callback": sinceLocation.map { String($0) } ?? "none",
            "application_state": applicationStateName,
            "device_motion_active": String(motionManager.isDeviceMotionActive)
        ])
        if sinceLocation.map({ $0 > 10 }) ?? (at > 10) {
            setWarning("location", "Более 10 секунд нет новых GPS-фиксаций; ожидается состояние неопределённости.")
        } else {
            setWarning("location", nil)
        }
        process(location: nil, trigger: "heartbeat")
    }

    private func process(location: LocationSample?, trigger: String) {
        guard let engine else { return }
        let at = nowElapsed()
        elapsed = at
        motion.elapsed = at
        let updates = engine.update(elapsed: at, location: location, motion: motion)
        accrueDurations(until: at)
        for result in updates {
            var totals = algorithmSummary[result.algorithm] ?? Self.emptyAlgorithmSummary
            if result.alert { totals.alerts += 1 }
            algorithmSummary[result.algorithm] = totals
        }
        previousResults = updates
        results = updates
        store?.append(PredictionRecord(elapsed: at, recordedAt: Date(), trigger: trigger,
                                      suppliedNewLocation: location != nil, results: updates), to: "predictions.jsonl")
    }

    private func accrueDurations(until at: Double) {
        for index in previousResults.indices {
            let prior = previousResults[index]
            let duration = max(0, at - prior.elapsed)
            var totals = algorithmSummary[prior.algorithm] ?? Self.emptyAlgorithmSummary
            // Промежуток без выполнения нельзя объявлять наблюдённым on/off-route.
            switch duration > 3 ? RouteState.uncertain : prior.state {
            case .onRoute: totals.onRouteSeconds += duration
            case .offRoute: totals.offRouteSeconds += duration
            case .uncertain: totals.uncertainSeconds += duration
            }
            algorithmSummary[prior.algorithm] = totals
            previousResults[index].elapsed = at
        }
    }

    private func event(_ kind: String, note: String = "", details: [String: String] = [:]) {
        store?.append(EventRecord(elapsed: nowElapsed(), recordedAt: Date(), kind: kind, note: note, details: details),
                      to: "events.jsonl")
    }

    private func stopSensors() {
        isRecording = false
        sessionToken = nil
        timer?.invalidate()
        timer = nil
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
        motionManager.stopDeviceMotionUpdates()
        pedometer.stopUpdates()
    }

    private func handleDiskError(_ message: String, token: UUID) {
        guard isRecording, sessionToken == token else { return }
        elapsed = nowElapsed()
        stopSensors()
        store?.abandon()
        store = nil
        engine = nil
        errorMessage = message
        status = "Запись остановлена. Частичные файлы сохранены"
        refreshSessions()
    }

    private func replaceLocationManager() {
        locationManager?.delegate = nil
        locationManager = CLLocationManager()
        locationManager.delegate = self
    }

    private func updateAuthorization() {
        let location: String
        switch locationManager.authorizationStatus {
        case .notDetermined: location = "Геолокация: не запрошена"
        case .restricted: location = "Геолокация: ограничена"
        case .denied: location = "Геолокация: запрещена"
        case .authorizedAlways: location = "Геолокация: всегда"
        case .authorizedWhenInUse: location = "Геолокация: при использовании"
        @unknown default: location = "Геолокация: неизвестно"
        }
        let activity: String
        switch CMPedometer.authorizationStatus() {
        case .notDetermined: activity = "движение: не запрошено"
        case .restricted: activity = "движение: ограничено"
        case .denied: activity = "движение: запрещено"
        case .authorized: activity = "движение: разрешено"
        @unknown default: activity = "движение: неизвестно"
        }
        authorizationDescription = location + "; " + activity
        if isRecording {
            setWarning("accuracy", locationManager.accuracyAuthorization == .reducedAccuracy
                       ? "Разрешена только приблизительная геопозиция; включите точную в настройках для полевого теста." : nil)
        }
    }

    private func setWarning(_ key: String, _ value: String?) {
        warnings[key] = value
        recordingWarning = warnings.isEmpty ? nil : warnings.keys.sorted().compactMap { warnings[$0] }.joined(separator: " ")
    }

    private var applicationStateName: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private func nowElapsed() -> Double {
        guard let startedInstant else { return 0 }
        let duration = startedInstant.duration(to: continuousClock.now).components
        return max(0, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }
    private func boundedObservationElapsed(_ value: Double, receivedElapsed: Double) -> Double? {
        // До начала сессии и в будущем — неизвестное время, без округления к «сейчас» или нулю.
        guard value.isFinite, receivedElapsed.isFinite, value >= 0, value <= receivedElapsed else { return nil }
        return value
    }
    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
    private static var emptyAlgorithmSummary: AlgorithmSummary {
        AlgorithmSummary(alerts: 0, uncertainSeconds: 0, onRouteSeconds: 0, offRouteSeconds: 0)
    }
}

private struct RawLocationRecord: Encodable {
    var elapsed: Double
    var receivedAt: Date
    var observedAt: Date?
    var latitude: Double?
    var longitude: Double?
    var horizontalAccuracy: Double?
    var altitude: Double?
    var verticalAccuracy: Double?
    var speed: Double?
    var speedAccuracy: Double?
    var course: Double?
    var courseAccuracy: Double?
    var simulatedBySoftware: Bool?
    var producedByAccessory: Bool?
    var coordinateValid: Bool
    var ageAtReceipt: Double?
}

private struct VectorRecord: Encodable { var x: Double?; var y: Double?; var z: Double? }
private struct QuaternionRecord: Encodable { var x: Double?; var y: Double?; var z: Double?; var w: Double? }
private struct DeviceMotionRecord: Encodable {
    var kind: String
    var elapsed: Double
    var receivedAt: Date
    var sensorTimestamp: Double?
    var receivedUptime: Double?
    var sensorAgeAtReceipt: Double?
    var clockEpochUptime: Double?
    var referenceFrame: String
    var snapshot: MotionSnapshot
    var gravity: VectorRecord
    var quaternion: QuaternionRecord
}
private struct PedometerRecord: Encodable {
    var kind: String
    var elapsed: Double
    var receivedAt: Date
    var startDate: Date?
    var endDate: Date?
    var observationElapsed: Double?
    var steps: Int?
    var distance: Double?
    var cadence: Double?
    var currentPace: Double?
    var averageActivePace: Double?
    var floorsAscended: Int?
    var floorsDescended: Int?
}
private struct EventRecord: Encodable {
    var elapsed: Double
    var recordedAt: Date
    var kind: String
    var note: String
    var details: [String: String]
}
private struct PredictionRecord: Encodable {
    var elapsed: Double
    var recordedAt: Date
    var trigger: String
    var suppliedNewLocation: Bool
    var results: [AlgorithmResult]
}
