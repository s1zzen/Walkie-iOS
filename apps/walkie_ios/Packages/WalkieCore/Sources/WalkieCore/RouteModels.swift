import Foundation

/// Координаты WGS84. Проверяются до передачи в системную карту.
public struct Coordinate: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

public struct RoutePOI: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let coordinate: Coordinate
    public let description: String?
    public let visitRadiusMeters: Double?
    public let minimumDwellSeconds: Double?

    public init(
        id: String, name: String, coordinate: Coordinate, description: String? = nil,
        visitRadiusMeters: Double? = nil, minimumDwellSeconds: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.description = description
        self.visitRadiusMeters = visitRadiusMeters
        self.minimumDwellSeconds = minimumDwellSeconds
    }
}

public struct RouteLeg: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let coordinates: [Coordinate]

    public init(id: String, coordinates: [Coordinate]) {
        self.id = id
        self.coordinates = coordinates
    }
}

public struct RoutePlan: Codable, Equatable, Sendable, Identifiable {
    /// Идентификатор версии, а не родительского маршрута.
    public let id: String
    public let routeID: String
    public let title: String
    public let pois: [RoutePOI]
    public let legs: [RouteLeg]
    public let isDemo: Bool
    public let start: Coordinate?
    public let end: Coordinate?
    public let completionWindowSeconds: Int?

    public init(
        id: String, routeID: String, title: String, pois: [RoutePOI], legs: [RouteLeg],
        isDemo: Bool, start: Coordinate? = nil, end: Coordinate? = nil,
        completionWindowSeconds: Int? = nil
    ) {
        self.id = id
        self.routeID = routeID
        self.title = title
        self.pois = pois
        self.legs = legs
        self.isDemo = isDemo
        self.start = start
        self.end = end
        self.completionWindowSeconds = completionWindowSeconds
    }

    /// Сохраняем и показываем только пригодную для карты геометрию.
    /// Это не проверка реальной проходимости улиц или доступности POI.
    public func validate() throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !routeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RouteValidationError.emptyIdentifier
        }
        guard !pois.isEmpty, !legs.isEmpty else { throw RouteValidationError.emptyRoute }
        guard Set(pois.map(\.id)).count == pois.count,
              Set(legs.map(\.id)).count == legs.count else {
            throw RouteValidationError.duplicateIdentifier
        }
        for poi in pois {
            guard !poi.id.isEmpty, !poi.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RouteValidationError.invalidPOI
            }
            guard poi.coordinate.isValid else { throw RouteValidationError.invalidCoordinate }
            if let radius = poi.visitRadiusMeters, !radius.isFinite || radius <= 0 {
                throw RouteValidationError.invalidVisitRule
            }
            if let dwell = poi.minimumDwellSeconds, !dwell.isFinite || dwell < 0 {
                throw RouteValidationError.invalidVisitRule
            }
        }
        for leg in legs {
            guard !leg.id.isEmpty else { throw RouteValidationError.emptyIdentifier }
            guard leg.coordinates.count >= 2 else { throw RouteValidationError.insufficientGeometry }
            guard leg.coordinates.allSatisfy(\.isValid) else { throw RouteValidationError.invalidCoordinate }
        }
        if let start, !start.isValid { throw RouteValidationError.invalidCoordinate }
        if let end, !end.isValid { throw RouteValidationError.invalidCoordinate }
        if let completionWindowSeconds, completionWindowSeconds <= 0 {
            throw RouteValidationError.invalidCompletionWindow
        }
    }

    /// Только иллюстрация интерфейса. Ломаные не получены из пешеходного роутера
    /// и не проверены на проходимость. Для реальной прогулки нужен проверенный маршрут.
    public static let demo: RoutePlan = {
        let start = Coordinate(latitude: 55.7678, longitude: 37.6089)
        let garden = Coordinate(latitude: 55.7705, longitude: 37.6093)
        let square = Coordinate(latitude: 55.7650, longitude: 37.6053)
        let theater = Coordinate(latitude: 55.7601, longitude: 37.6186)
        return RoutePlan(
            id: "demo-version-1", routeID: "demo-route-1",
            title: "Москва · демонстрация, не навигация",
            pois: [
                RoutePOI(id: "demo-hermitage", name: "Сад Эрмитаж", coordinate: garden,
                         description: "Демонстрационная точка. Доступность и координаты входа не проверены."),
                RoutePOI(id: "demo-pushkin", name: "Пушкинская площадь", coordinate: square,
                         description: "Демонстрационная точка, а не рекомендация маршрута."),
                RoutePOI(id: "demo-bolshoi", name: "Большой театр", coordinate: theater,
                         description: "Демонстрационная точка. Линия между точками условная.")
            ],
            legs: [
                RouteLeg(id: "demo-leg-1", coordinates: [start, garden]),
                RouteLeg(id: "demo-leg-2", coordinates: [garden, square]),
                RouteLeg(id: "demo-leg-3", coordinates: [square, theater])
            ],
            isDemo: true, start: start, end: theater
        )
    }()
}

public enum RouteValidationError: Error, Equatable, LocalizedError {
    case emptyIdentifier
    case emptyRoute
    case duplicateIdentifier
    case invalidCoordinate
    case invalidPOI
    case insufficientGeometry
    case invalidVisitRule
    case invalidCompletionWindow
    case invalidServerVersion

    public var errorDescription: String? {
        switch self {
        case .emptyIdentifier: return "У маршрута отсутствует идентификатор."
        case .emptyRoute: return "В маршруте отсутствуют точки или геометрия."
        case .duplicateIdentifier: return "Идентификаторы точек или отрезков повторяются."
        case .invalidCoordinate: return "В маршруте есть недопустимые координаты."
        case .invalidPOI: return "В маршруте есть точка без названия или идентификатора."
        case .insufficientGeometry: return "Для отрезка маршрута нужны как минимум две координаты."
        case .invalidVisitRule: return "Недопустимые параметры фиксации посещения."
        case .invalidCompletionWindow: return "Окно прохождения должно быть больше нуля."
        case .invalidServerVersion: return "Версия маршрута не соответствует контракту сервера."
        }
    }
}

/// Транспортная модель контракта walkie-core от 26.09.2026.
/// Не связана с URLSession. Необязательные поля Place допускают отсутствие и null.
public struct RouteVersionDTO: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public let lat: Double
        public let lon: Double
        public var coordinate: Coordinate { Coordinate(latitude: lat, longitude: lon) }
    }

    public struct Summary: Codable, Equatable, Sendable {
        public let distance_m: Int
        public let duration_s: Int
        public let walking_s: Int
        public let stops_count: Int
    }

    public struct Place: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let interest: String
        public let categories: [String]
        public let location: Point
        public let address: String?
        public let hours_text: String?
        public let rating: Double?
        public let photo_url: String?
        public let description: String?
    }

    public struct Stop: Codable, Equatable, Sendable {
        public let order: Int
        public let place: Place
        public let arrival_offset_s: Int
        public let visit_s: Int
        public let walk_from_previous_s: Int
        public let distance_from_start_m: Int
        public let visit_radius_m: Int
        public let min_dwell_s: Int
        public let reasons: [String]
    }

    public struct Leg: Codable, Equatable, Sendable {
        public let from_order: Int
        public let to_order: Int
        public let distance_m: Int
        public let duration_s: Int
        public let points: [Point]
    }

    public let id: String
    public let route_id: String
    public let number: Int
    public let kind: String
    public let created_at: String
    public let summary: Summary
    public let start: Point
    public let end: Point
    public let stops: [Stop]
    public let legs: [Leg]
    public let completion_window_s: Int
    public let rebuilds_left: Int

    public func routePlan(title: String = "Маршрут Walkie") throws -> RoutePlan {
        let orderedStops = stops.sorted { $0.order < $1.order }
        guard number >= 1, ["initial", "rebuild"].contains(kind), rebuilds_left >= 0,
              (3...7).contains(stops.count), (3...8).contains(legs.count),
              summary.stops_count == stops.count,
              summary.distance_m >= 0, summary.duration_s >= 0, summary.walking_s >= 0,
              orderedStops.map(\.order) == Array(1...stops.count),
              stops.allSatisfy({
                  $0.arrival_offset_s >= 0 && $0.visit_s >= 0 && $0.walk_from_previous_s >= 0
                      && $0.distance_from_start_m >= 0 && (1...3).contains($0.reasons.count)
              }),
              legs.allSatisfy({
                  $0.from_order >= 0 && $0.from_order <= stops.count
                      && $0.to_order >= 1 && $0.to_order <= stops.count + 1
                      && $0.distance_m >= 0 && $0.duration_s >= 0
              }) else { throw RouteValidationError.invalidServerVersion }

        let plan = RoutePlan(
            id: id, routeID: route_id, title: title,
            pois: orderedStops.map {
                RoutePOI(id: $0.place.id, name: $0.place.name, coordinate: $0.place.location.coordinate,
                         description: $0.place.description,
                         visitRadiusMeters: Double($0.visit_radius_m),
                         minimumDwellSeconds: Double($0.min_dwell_s))
            },
            legs: legs.map {
                RouteLeg(id: "\(id):\($0.from_order)-\($0.to_order)", coordinates: $0.points.map(\.coordinate))
            },
            isDemo: false, start: start.coordinate, end: end.coordinate,
            completionWindowSeconds: completion_window_s
        )
        try plan.validate()
        return plan
    }
}

public enum RouteVersionDecoder {
    /// JSON тела RouteVersion, не оболочки Route.latest_version и не GeoJSON.
    public static func decode(_ data: Data, title: String = "Маршрут Walkie") throws -> RoutePlan {
        try JSONDecoder().decode(RouteVersionDTO.self, from: data).routePlan(title: title)
    }
}
