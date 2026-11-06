import Foundation
import WalkieCore

/// Product-facing request for the local UI fixture adapter. This is deliberately
/// not the HTTP draft DTO: a real backend uses a coordinate and questionnaire
/// answers. Choosing one of these areas never reads the device's GPS position.
struct RouteRequest: Codable, Equatable, Sendable {
    var requestID: String = UUID().uuidString
    var generationID: String = UUID().uuidString
    // Optional for backwards-compatible decoding of pre-review drafts.
    var creationOrigin: RouteCreationOrigin? = nil
    var previousRouteID: String? = nil
    var startArea: String
    var durationMinutes: Int
    var mood: String
    var interests: [String]
    var finishAtStart: Bool
    var origin: Coordinate?
    var originSource = "map_pin"
    var originTitle: String?
    var destination: Coordinate?
    var destinationTitle: String? = nil
    var context = RouteContext()
    var correctionText: String?

    static let startAreas = ["Чистые пруды", "Замоскворечье"]
    static let moods = ["Спокойная прогулка", "Новые впечатления", "Больше движения"]
    static let supportedInterests = [
        "architecture_history", "museums_exhibitions", "contemporary_art", "parks_nature",
        "water", "viewpoints", "coffee_desserts", "food_markets", "local_shops",
        "quiet_courtyards", "photogenic_places", "outdoor_sports"
    ]

    init(
        startArea: String = "Чистые пруды", durationMinutes: Int = 90,
        mood: String = "Спокойная прогулка",
        interests: [String] = ["architecture_history", "parks_nature", "coffee_desserts"],
        finishAtStart: Bool = false
    ) {
        self.startArea = startArea
        self.durationMinutes = durationMinutes
        self.mood = mood
        self.interests = interests
        self.finishAtStart = finishAtStart
    }

    func validate() throws {
        if let creationOrigin, creationOrigin != .newWalk, previousRouteID == nil { throw RouteRequestError.invalidOrigin }
        guard origin?.isValid != false, destination?.isValid != false else { throw RouteRequestError.invalidCoordinate }
        guard ["map_pin", "address_search", "current_location"].contains(originSource) else { throw RouteRequestError.invalidCoordinate }
        guard context.phrase.count <= 140, (correctionText?.count ?? 0) <= 140 else { throw RouteRequestError.textTooLong }
        guard Self.startAreas.contains(startArea) else { throw RouteRequestError.unsupportedArea }
        guard (30...240).contains(durationMinutes) else { throw RouteRequestError.invalidDuration }
        guard Self.moods.contains(mood) else { throw RouteRequestError.unsupportedMood }
        guard !interests.isEmpty, Set(interests).count == interests.count,
              interests.allSatisfy(Self.supportedInterests.contains) else {
            throw RouteRequestError.invalidInterests
        }
    }
}

enum RouteCreationOrigin: String, Codable, Sendable { case newWalk = "new_walk", restart, paramsChange = "params_change" }

enum RouteRequestError: Error, LocalizedError {
    case unsupportedArea, invalidDuration, unsupportedMood, invalidInterests, invalidCoordinate, textTooLong, backendUnavailable, localDemoUnsupported, invalidOrigin

    var errorDescription: String? {
        switch self {
        case .invalidOrigin: return "Для изменения или перезапуска нужен исходный маршрут. Начни новую прогулку с главного экрана."
        case .unsupportedArea: return "Выберите один из доступных районов."
        case .invalidDuration: return "Продолжительность прогулки должна быть от 30 минут до 4 часов."
        case .unsupportedMood: return "Выберите настроение прогулки из списка."
        case .invalidInterests: return "Выберите хотя бы один интерес из списка без повторений."
        case .invalidCoordinate: return "Выберите корректную точку на карте."
        case .textTooLong: return "Можно написать не больше 140 символов."
        case .backendUnavailable: return "Не удалось выполнить эту операцию. Ответы сохранены; попробуй повторить."
        case .localDemoUnsupported: return "Сейчас включён локальный деморежим: доступны только готовые примеры Чистых прудов и Замоскворечья без заданного финиша. Для маршрута между своими точками открой «Профиль → Учётная запись → Выйти» и войди по почте или Apple. Если запуск задан через Xcode, отключи WALKIE_OFFLINE_DEMO. Ответы сохранены."
        }
    }
}

/// Only a terminal state received from the generation endpoint proves that its
/// idempotency key can be replaced. Transport errors leave the outcome unknown.
enum RouteGenerationTerminalError: Error, LocalizedError, Sendable {
    case failed(BackendProblem)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .failed(let problem): return problem.localizedDescription
        case .cancelled: return "Построение отменено сервером. Ответы сохранены; можно повторить."
        }
    }
}

/// This boundary intentionally has no access to sensors, visits, or walk logs.
protocol CoreAPI: Sendable {
    func generateDemoRoute() async throws -> RoutePlan
    func generateRoute(request: RouteRequest) async throws -> RoutePlan
    func rebuildRoute(request: RouteRequest, previousPlan: RoutePlan) async throws -> RoutePlan
    func prepareContext(request: RouteRequest) async throws -> RouteContextDefinition
    func saveContextAnswer(requestID: String, questionID: String, choices: [String]?) async throws
    func parseCorrection(text: String, plan: RoutePlan) async throws -> RouteCorrection
    func applyCorrection(_ correction: RouteCorrection, plan: RoutePlan) async throws -> RoutePlan
    func acknowledgeVersionResult(_ result: RoutePlan, replacing source: RoutePlan, correctionID: String?) async
    func routeDetails(planID: String) async -> LiveRouteDetails?
    func createShareText(plan: RoutePlan) async throws -> String
    func generationProgress() async -> RouteGenerationProgress?
}

extension CoreAPI {
    func acknowledgeVersionResult(_ result: RoutePlan, replacing source: RoutePlan, correctionID: String?) async {}
    func generationProgress() async -> RouteGenerationProgress? { nil }
    func createShareText(plan: RoutePlan) async throws -> String {
        plan.displayTitle + "\n" + plan.pois.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "\n") + "\nДемонстрационный пример Walkie"
    }
    func routeDetails(planID: String) async -> LiveRouteDetails? { nil }
    func prepareContext(request: RouteRequest) async throws -> RouteContextDefinition { .demo }
    func saveContextAnswer(requestID: String, questionID: String, choices: [String]?) async throws {}
    func parseCorrection(text: String, plan: RoutePlan) async throws -> RouteCorrection { throw RouteRequestError.backendUnavailable }
    func applyCorrection(_ correction: RouteCorrection, plan: RoutePlan) async throws -> RoutePlan { throw RouteRequestError.backendUnavailable }
    func rebuildRoute(request: RouteRequest, previousPlan: RoutePlan) async throws -> RoutePlan {
        throw RouteRequestError.backendUnavailable
    }
    /// Keeps small injected adapters and the original recorder tests compatible.
    func generateRoute(request: RouteRequest) async throws -> RoutePlan {
        try request.validate()
        return try await generateDemoRoute()
    }
}

actor MockCoreAPI: CoreAPI {
    func generateDemoRoute() async throws -> RoutePlan {
        try await Task.sleep(for: .milliseconds(350))
        try Task.checkCancellation()
        return .demo
    }

    func generateRoute(request: RouteRequest) async throws -> RoutePlan {
        try request.validate()
        let center = RouteBuilderLocation.demoOrigin(for: request.startArea)
        if let origin = request.origin,
           abs(origin.latitude - center.latitude) > 0.001 || abs(origin.longitude - center.longitude) > 0.001 {
            throw RouteRequestError.localDemoUnsupported
        }
        guard request.destination == nil, request.correctionText == nil else { throw RouteRequestError.localDemoUnsupported }
        try await Task.sleep(for: .milliseconds(450))
        try Task.checkCancellation()
        return try DemoRouteCatalog.route(for: request)
    }
}

protocol RoutePlanCaching: Sendable {
    func load() async throws -> RoutePlan?
    func save(_ plan: RoutePlan) async throws
}

/// A single writer for the last validated plan. Storage stays outside the VM.
/// When HTTP is introduced this small repository can move to Storage unchanged.
actor RoutePlanCache: RoutePlanCaching {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() throws -> RoutePlan? {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let plan = try JSONDecoder().decode(RoutePlan.self, from: Data(contentsOf: url))
        try plan.validate()
        try Task.checkCancellation()
        return plan
    }

    func save(_ plan: RoutePlan) throws {
        try Task.checkCancellation()
        try plan.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plan)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Validation/encoding/write failure cannot truncate the previous plan.
        // Atomic replacement is the durable commit point for this operation.
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
