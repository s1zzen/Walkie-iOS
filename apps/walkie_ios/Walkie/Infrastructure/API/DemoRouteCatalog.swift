import Foundation
import WalkieCore

/// Offline product fixtures, not a pedestrian router or live recommendation
/// service. Coordinates, lines and timing are illustrative. Keep isDemo=true;
/// callers must distinguish these routes from a validated backend response.
enum DemoRouteCatalog {
    struct PlacePresentation: Sendable {
        let category: String
        let symbol: String
        let reasons: [String]
    }

    private struct Place: Sendable {
        let poi: RoutePOI
        let interests: [String]
        let presentation: PlacePresentation
    }

    static func route(for request: RouteRequest) throws -> RoutePlan {
        try request.validate()
        let isPonds = request.startArea == RouteRequest.startAreas[0]
        let places = isPonds ? ponds : zamoskvorechye
        let start = isPonds
            ? Coordinate(latitude: 55.76519, longitude: 37.63809)
            : Coordinate(latitude: 55.74215, longitude: 37.61882)
        let requestedCount = request.durationMinutes <= 45 ? 3
            : (request.durationMinutes <= 75 ? 4 : 5)
        let count = min(places.count, requestedCount + (request.mood == "Больше движения" ? 1 : 0))

        // Keep a geographical order; interests choose stops within the fixture,
        // not an arbitrary nearest-neighbour path through a street network.
        let rankedIndices = places.indices.dropFirst().sorted { lhs, rhs in
            let leftScore = Set(places[lhs].interests).intersection(request.interests).count
            let rightScore = Set(places[rhs].interests).intersection(request.interests).count
            return leftScore == rightScore ? lhs < rhs : leftScore > rightScore
        }
        let selectedIndices = ([0] + rankedIndices.prefix(count - 1)).sorted()
        let selected = selectedIndices.map { places[$0].poi }
        let signature = [
            isPonds ? "ponds" : "zamoskvorechye",
            String(request.durationMinutes), String(RouteRequest.moods.firstIndex(of: request.mood) ?? 0),
            request.interests.sorted().joined(separator: "_"), request.finishAtStart ? "loop" : "open"
        ].joined(separator: "-")
        let id = "fixture-v2-\(signature)"
        var previous = start
        var legs = selected.enumerated().map { index, poi in
            defer { previous = poi.coordinate }
            return RouteLeg(id: "\(id)-leg-\(index)", coordinates: [previous, poi.coordinate])
        }
        if request.finishAtStart {
            legs.append(RouteLeg(id: "\(id)-return", coordinates: [previous, start]))
        }
        let plan = RoutePlan(
            id: id, routeID: "fixture-\(isPonds ? "ponds" : "zamoskvorechye")",
            title: isPonds ? "Вокруг Чистых прудов" : "Переулки Замоскворечья",
            pois: selected, legs: legs, isDemo: true,
            start: start, end: request.finishAtStart ? start : selected.last?.coordinate
        )
        try plan.validate()
        return plan
    }

    static func presentation(for poi: RoutePOI) -> PlacePresentation {
        (ponds + zamoskvorechye).first { $0.poi.id == poi.id }?.presentation
            ?? PlacePresentation(
                category: "Место прогулки", symbol: "mappin.and.ellipse",
                reasons: ["Остановка выбранного маршрута"]
            )
    }

    private static func place(
        _ id: String, _ name: String, _ latitude: Double, _ longitude: Double,
        _ description: String, _ category: String, _ symbol: String,
        _ interests: [String], _ reasons: [String]
    ) -> Place {
        Place(
            poi: RoutePOI(
                id: id, name: name,
                coordinate: Coordinate(latitude: latitude, longitude: longitude),
                description: description, visitRadiusMeters: 40, minimumDwellSeconds: 30
            ),
            interests: interests,
            presentation: PlacePresentation(category: category, symbol: symbol, reasons: reasons)
        )
    }

    private static let ponds: [Place] = [
        place("ponds-griboedov", "Памятник Грибоедову", 55.76452, 37.63849,
              "Начало прогулки у бульвара. В этом примере отсюда удобно рассмотреть общий план и выбрать темп перед следующими остановками.",
              "История", "building.columns", ["architecture_history", "photogenic_places"],
              ["Знакомство с районом", "Архитектурный акцент прогулки"]),
        place("ponds-menshikov", "Меншикова башня", 55.76411, 37.63992,
              "Архитектурная остановка в переулке рядом с бульваром. В демомаршруте предполагается осмотр снаружи; посещение здания не включено.",
              "Архитектура", "building.2", ["architecture_history", "quiet_courtyards", "photogenic_places"],
              ["Детали городской архитектуры", "Короткий заход в переулок"]),
        place("ponds-water", "Чистый пруд", 55.76140, 37.64400,
              "Пауза у воды между городскими остановками. Можно ненадолго замедлиться и продолжить прогулку вдоль бульвара.",
              "У воды", "water.waves", ["water", "parks_nature", "outdoor_sports"],
              ["Смена ритма у воды", "Зелёный участок прогулки"]),
        place("ponds-sovremennik", "Театр «Современник»", 55.76118, 37.64618,
              "Культурная остановка на Чистопрудном бульваре. Здесь маршрут знакомит с городской средой вокруг театра, без билетов и посещения спектакля.",
              "Культура", "theatermasks", ["contemporary_art", "museums_exhibitions", "architecture_history"],
              ["Культурный контекст района", "Остановка рядом с бульваром"]),
        place("ponds-pokrovka", "Покровка", 55.75855, 37.64572,
              "Городской участок с фасадами и небольшими заведениями. В демосценарии это место для самостоятельной паузы; конкретное кафе не забронировано и не проверено.",
              "Городская жизнь", "cup.and.saucer", ["coffee_desserts", "food_markets", "local_shops"],
              ["Возможность сделать паузу", "Живая городская среда"]),
        place("ponds-khokhlovka", "Хохловская площадь", 55.75731, 37.64495,
              "Открытое городское пространство в конце демонстрационной прогулки. Можно остановиться, посмотреть на район и решить, продолжать ли путь.",
              "Городское пространство", "square.3.layers.3d", ["contemporary_art", "quiet_courtyards", "viewpoints", "photogenic_places"],
              ["Открытое пространство для остановки", "Финальный акцент прогулки"])
    ]

    private static let zamoskvorechye: [Place] = [
        place("zamosk-tretyakov", "Третьяковская галерея", 55.74166, 37.62085,
              "Начальная культурная точка прогулки по Замоскворечью. Демосценарий предполагает знакомство с фасадом и переулком; посещение музея в маршрут не включено.",
              "Искусство", "photo.artframe", ["museums_exhibitions", "contemporary_art", "architecture_history"],
              ["Культурный центр прогулки", "Начало знакомства с переулками"]),
        place("zamosk-lavrushinsky", "Лаврушинский переулок", 55.74070, 37.62045,
              "Небольшая прогулочная остановка в окружении городской архитектуры. Подходит для неспешного осмотра деталей и короткой паузы.",
              "Переулки", "building.2", ["architecture_history", "quiet_courtyards", "photogenic_places"],
              ["Детали исторической застройки", "Более спокойный участок"]),
        place("zamosk-kadashevskaya", "Кадашёвская набережная", 55.74439, 37.62202,
              "Остановка у Водоотводного канала. В пример добавлен открытый вид на воду, чтобы чередовать переулки и более широкие пространства.",
              "Набережная", "water.waves", ["water", "viewpoints", "photogenic_places"],
              ["Открытый вид на воду", "Смена городского пейзажа"]),
        place("zamosk-garden", "Михайловский сад", 55.74013, 37.62440,
              "Зелёная остановка в районе. Перед реальной прогулкой нужно проверить вход и доступность территории: демогеометрия этого не учитывает.",
              "Зелёные места", "leaf", ["parks_nature", "quiet_courtyards", "outdoor_sports"],
              ["Пауза среди зелени", "Спокойный участок маршрута"]),
        place("zamosk-pyatnitskaya", "Пятницкая улица", 55.73890, 37.62700,
              "Городской отрезок с возможностью самостоятельно выбрать место для отдыха. Пример не содержит актуальных часов работы и рекомендаций конкретных заведений.",
              "Городская жизнь", "cup.and.saucer", ["coffee_desserts", "food_markets", "local_shops"],
              ["Возможность сделать паузу", "Контраст с тихими переулками"]),
        place("zamosk-ordynka", "Большая Ордынка", 55.73800, 37.62400,
              "Архитектурная остановка для завершения знакомства с районом. Линия до неё в этой версии условная и не заменяет проверку переходов на местности.",
              "Архитектура", "building.columns", ["architecture_history", "photogenic_places", "viewpoints"],
              ["Историческая городская среда", "Завершение прогулки по району"])
    ]
}

extension RoutePOI {
    var displayCategory: String { DemoRouteCatalog.presentation(for: self).category }
    var symbolName: String { DemoRouteCatalog.presentation(for: self).symbol }
    var recommendationReasons: [String] { DemoRouteCatalog.presentation(for: self).reasons }
}

extension RoutePlan {
    var displayTitle: String {
        id == RoutePlan.demo.id ? "Прогулка по центру Москвы" : title
    }

    /// Length of the stored polyline, not a verified pedestrian distance.
    var approximateDistanceMeters: Double {
        legs.reduce(0) { total, leg in
            total + zip(leg.coordinates, leg.coordinates.dropFirst()).reduce(0) { subtotal, pair in
                subtotal + Self.distance(from: pair.0, to: pair.1)
            }
        }
    }

    /// UI estimate: 4.5 km/h plus five minutes per stop. The UI uses an ≈ sign;
    /// this is not an SLA, a route budget check, or an algorithm performance metric.
    var estimatedMinutes: Int {
        max(1, Int((approximateDistanceMeters / 75).rounded(.up)) + pois.count * 5)
    }

    private static func distance(from a: Coordinate, to b: Coordinate) -> Double {
        let radians = Double.pi / 180
        let latitudeDelta = (b.latitude - a.latitude) * radians
        let longitudeDelta = (b.longitude - a.longitude) * radians
        let haversine = pow(sin(latitudeDelta / 2), 2)
            + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(longitudeDelta / 2), 2)
        return 6_371_000 * 2 * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
    }
}
