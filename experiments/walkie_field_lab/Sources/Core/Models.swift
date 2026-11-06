import Foundation

struct GeoPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

struct TestRoute: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var source: String
    /// Разные сегменты не соединяются через пропуски GPX.
    var segments: [[GeoPoint]]

    var points: [GeoPoint] { segments.flatMap { $0 } }
    var isValid: Bool {
        !segments.isEmpty && segments.allSatisfy { $0.count >= 2 && $0.allSatisfy(\.isValid) }
    }
}

struct LocationSample: Codable, Sendable {
    /// Время получения с начала сессии по монотонным часам.
    var elapsed: Double
    var observedAt: Date
    var receivedAt: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var altitude: Double?
    var verticalAccuracy: Double?
    var speed: Double?
    var speedAccuracy: Double?
    var course: Double?
    var courseAccuracy: Double?
    var simulatedBySoftware: Bool?
    var producedByAccessory: Bool?

    var point: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
}

struct MotionSnapshot: Codable, Sendable {
    var elapsed: Double
    var steps: Int?
    var distance: Double?
    var cadence: Double?
    var pedometerUpdatedAt: Double?
    var accelerationX: Double?
    var accelerationY: Double?
    var accelerationZ: Double?
    var rotationX: Double?
    var rotationY: Double?
    var rotationZ: Double?
    var roll: Double?
    var pitch: Double?
    var yaw: Double?
    var motionUpdatedAt: Double?

    static func empty(at elapsed: Double) -> MotionSnapshot {
        MotionSnapshot(elapsed: elapsed)
    }
}

enum RouteState: String, Codable, Sendable {
    case onRoute = "on_route"
    case offRoute = "off_route"
    case uncertain

    var title: String {
        switch self {
        case .onRoute: "На маршруте"
        case .offRoute: "Сход с маршрута"
        case .uncertain: "Недостаточно данных"
        }
    }
}

struct AlgorithmResult: Codable, Sendable, Identifiable {
    var id: String { algorithm }
    var elapsed: Double
    var algorithm: String
    var state: RouteState
    var alert: Bool
    var reason: String
    var distanceToRoute: Double?
    var suspiciousLocation: Bool
}

struct DetectorConfiguration: Codable, Sendable {
    var enterDistance = 25.0
    var exitDistance = 15.0
    var confirmationSeconds = 4.0
    var maximumAccuracy = 35.0
    var staleAfterSeconds = 10.0
    var resetAfterSeconds = 15.0
    var maximumWalkingSpeed = 4.0
    var jumpSlackMeters = 20.0
    var reacquisitionSeconds = 20.0
}

struct SessionInfo: Codable, Identifiable, Sendable {
    var id = UUID()
    var startedAt = Date()
    var endedAt: Date?
    var name: String
    var route: TestRoute
    var configuration: DetectorConfiguration
    var appVersion = "0.1.0"
    var schemaVersion = 1
    var device: String
    var systemVersion: String
    var notes: String
    var algorithms = ["geometric_v1", "guarded_v1"]
    var interrupted = false
}

struct SessionSummary: Codable, Sendable {
    var duration: Double
    var locationCount: Int
    var markerCount: Int
    var algorithms: [String: AlgorithmSummary]
}

struct AlgorithmSummary: Codable, Sendable {
    var alerts: Int
    var uncertainSeconds: Double
    var onRouteSeconds: Double
    var offRouteSeconds: Double
}

enum FieldLabError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
