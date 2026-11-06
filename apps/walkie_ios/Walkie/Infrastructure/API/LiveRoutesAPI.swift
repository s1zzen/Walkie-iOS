import Foundation
import CryptoKit
import WalkieCore

protocol RouteBackendTransport: Sendable {
    func request(path: String, method: String, body: Data?, authenticated: Bool) async throws -> Data
}
extension BackendClient: RouteBackendTransport {}

struct LiveRouteDetails: Codable, Sendable {
    struct Stop: Codable, Sendable {
        var placeID: String
        var category: String
        var address: String?
        var hours: String?
        var openNow: Bool?
        var rating: Double?
        var photoURL: URL?
        var walkSeconds: Int
        var reasons: [String]
        var fallback: String?
    }
    var routeID: String
    var versionID: String
    var distanceMeters: Int
    var durationSeconds: Int
    var issuedAt: String
    var externalMapsURL: URL?
    var stops: [Stop]
}

/// Contract v0.2.0. Sends only an explicitly selected start/finish. This adapter
/// cannot access sensors, checkpoints, the track or the local research files.
actor LiveRoutesAPI: CoreAPI {
    private let client: any RouteBackendTransport
    private let detailsURL: URL?
    private var details: [String: LiveRouteDetails] = [:]
    private var progress: RouteGenerationProgress?
    private let operations: RouteOperationStore

    init(client: any RouteBackendTransport = BackendClient.shared, detailsURL: URL? = nil, operationsURL: URL? = nil) {
        self.client = client
        self.detailsURL = detailsURL
        operations = RouteOperationStore(url: operationsURL ?? detailsURL?.deletingLastPathComponent().appendingPathComponent("route_operations.json"))
        if let detailsURL, let data = try? Data(contentsOf: detailsURL),
           let saved = try? JSONDecoder().decode([String: LiveRouteDetails].self, from: data) { details = saved }
    }

    // Match the async protocol requirement explicitly. Otherwise Swift may
    // select the protocol-extension fallback from an async call site.
    func routeDetails(planID: String) async -> LiveRouteDetails? { details[planID] }
    func generationProgress() async -> RouteGenerationProgress? { progress }
    func generateDemoRoute() async throws -> RoutePlan { throw RouteRequestError.backendUnavailable }
    func createShareText(plan: RoutePlan) async throws -> String {
        struct Share: Decodable { let url: URL; let share_text: String }
        let data = try await client.request(path: "/v1/routes/\(plan.routeID)/share-links", method: "POST", body: nil, authenticated: true)
        let share = try JSONDecoder().decode(Share.self, from: data)
        return share.share_text + "\n" + share.url.absoluteString
    }

    func prepareContext(request: RouteRequest) async throws -> RouteContextDefinition {
        var create: [String: Any] = ["id": request.requestID, "origin": (request.creationOrigin ?? .newWalk).rawValue]
        create["previous_route_id"] = request.previousRouteID
        _ = try await send("/v1/routes", method: "POST", object: create)
        let origin = request.origin ?? RouteBuilderLocation.demoOrigin(for: request.startArea)
        let finish = request.finishAtStart ? origin : request.destination
        var finishObject: [String: Any] = ["mode": finish == nil ? "none" : "point"]
        if let finish { finishObject["location"] = point(finish) }
        _ = try await send("/v1/routes/\(request.requestID)", method: "PATCH", object: [
            "start": ["location": point(origin), "source": request.originSource, "title": request.originTitle ?? request.startArea],
            "finish": finishObject, "budget_s": request.durationMinutes * 60
        ])
        let context: ContextDTO = try await decode("/v1/routes/\(request.requestID)/context")
        return context.definitionValue
    }

    func saveContextAnswer(requestID: String, questionID: String, choices: [String]?) async throws {
        let value: [String: Any] = choices.map { ["kind": "choice", "option_ids": $0] } ?? ["kind": "skip"]
        _ = try await send("/v1/routes/\(requestID)/context/answers/\(questionID)", method: "PUT", object: value)
    }

    func generateRoute(request: RouteRequest) async throws -> RoutePlan {
        try request.validate()
        do {
            let existing: RouteDTO = try await decode("/v1/routes/\(request.requestID)")
            if let version = existing.latest_version { return try remember(version) }
        } catch let problem as BackendProblem where problem.status == 404 {
            // First build; prepareContext below creates the route idempotently.
        }
        let definition = try await prepareContext(request: request)
        for question in definition.questions where !definition.isComplete {
            if let choices = request.context.answers[question.id] {
                try await saveContextAnswer(requestID: request.requestID, questionID: question.id, choices: choices)
            } else if request.context.skipped.contains(question.id) {
                try await saveContextAnswer(requestID: request.requestID, questionID: question.id, choices: nil)
            }
        }
        if definition.branch == .c2 && !definition.isComplete && !definition.phraseSubmitted {
            let value: [String: Any] = request.context.phraseSkipped
                ? ["kind": "skip"]
                : ["kind": "text", "text": request.context.phrase, "from_chip": request.context.phraseFromChip]
            _ = try await send("/v1/routes/\(request.requestID)/context/phrase", method: "PUT", object: value)
        }
        do { return try await generate(routeID: request.requestID, kind: "initial", requestID: request.generationID) }
        catch let problem as BackendProblem where problem.code == "route_already_built" {
            // A network retry after a committed generation must recover that
            // same version, not silently ask for an alternative.
            let route: RouteDTO = try await decode("/v1/routes/\(request.requestID)")
            guard let version = route.latest_version else { throw problem }
            return try remember(version)
        }
    }

    func rebuildRoute(request: RouteRequest, previousPlan: RoutePlan) async throws -> RoutePlan {
        try await performVersionOperation(plan: previousPlan, kind: "alternative")
    }

    func parseCorrection(text: String, plan: RoutePlan) async throws -> RouteCorrection {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 140 else { throw RouteRequestError.textTooLong }
        let textID = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = "\(plan.routeID)|\(plan.id)|\(textID)"
        let operation = try await operations.correction(for: key)
        if let result = operation.result { return result }
        let data = try await send("/v1/routes/\(plan.routeID)/corrections", method: "POST", object: [
            "id": operation.requestID, "version_id": plan.id, "text": text, "from_chip": false
        ])
        let result = try JSONDecoder().decode(CorrectionDTO.self, from: data)
        let correction = RouteCorrection(id: result.id, understood: result.status == "understood", constraints: result.constraints.map(\.text))
        try await operations.finishCorrection(key: key, result: correction)
        return correction
    }

    func applyCorrection(_ correction: RouteCorrection, plan: RoutePlan) async throws -> RoutePlan {
        guard correction.understood else { throw RouteRequestError.backendUnavailable }
        return try await performVersionOperation(plan: plan, kind: "correction", correctionID: correction.id)
    }

    func acknowledgeVersionResult(_ result: RoutePlan, replacing source: RoutePlan, correctionID: String?) async {
        let kind = correctionID == nil ? "alternative" : "correction"
        let key = "\(source.routeID)|\(source.id)|\(kind)|\(correctionID ?? "")"
        // A result has actually reached its owning card. A later explicit
        // action on the old source version is then a new user intent.
        try? await operations.acknowledgeGeneration(key: key, versionID: result.id)
    }

    private func performVersionOperation(plan: RoutePlan, kind: String, correctionID: String? = nil) async throws -> RoutePlan {
        let key = "\(plan.routeID)|\(plan.id)|\(kind)|\(correctionID ?? "")"
        let (operation, isNew) = try await operations.generation(for: key)
        if let versionID = operation.versionID {
            let version: VersionDTO = try await decode("/v1/routes/\(plan.routeID)/versions/\(versionID)")
            return try remember(version)
        }
        do {
            let result = try await generate(routeID: plan.routeID, kind: kind, correctionID: correctionID,
                requestID: operation.requestID, resume: !isNew)
            try await operations.finishGeneration(key: key, versionID: result.id)
            return result
        } catch let error as RouteGenerationTerminalError {
            // Only an explicit server terminal state permits a new operation.
            try await operations.terminateGeneration(key: key)
            throw error
        }
    }

    private func generate(routeID: String, kind: String, correctionID: String? = nil, requestID: String, resume: Bool = false) async throws -> RoutePlan {
        let path = "/v1/routes/\(routeID)/generations"
        var object = ["request_id": requestID, "kind": kind]
        object["correction_id"] = correctionID
        do {
            var generation: GenerationDTO
            if resume {
                do { generation = try await decode("\(path)/\(requestID)") }
                catch let problem as BackendProblem where problem.status == 404 {
                    // The server can prove that the earlier POST was not committed.
                    generation = try JSONDecoder().decode(GenerationDTO.self, from: await send(path, method: "POST", object: object))
                }
            } else {
                generation = try JSONDecoder().decode(GenerationDTO.self, from: await send(path, method: "POST", object: object))
            }
            progress = .init(stage: generation.stage, candidatesFound: generation.candidates_found)
            let deadline = Date().addingTimeInterval(120)
            while generation.status == "queued" || generation.status == "running" {
                try Task.checkCancellation()
                guard Date() < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .seconds(1.5))
                generation = try await decode("\(path)/\(requestID)")
                progress = .init(stage: generation.stage, candidatesFound: generation.candidates_found)
            }
            try Task.checkCancellation()
            if generation.status == "cancelled" { throw RouteGenerationTerminalError.cancelled }
            if generation.status == "failed" {
                throw RouteGenerationTerminalError.failed(generation.problem ?? BackendProblem(code: "generation_failed", detail: "Не получилось собрать маршрут. Ответы сохранены."))
            }
            guard generation.status == "succeeded", let versionID = generation.version_id else { throw URLError(.cannotParseResponse) }
            let version: VersionDTO = try await decode("/v1/routes/\(routeID)/versions/\(versionID)")
            return try remember(version)
        } catch {
            if Task.isCancelled || error is CancellationError {
                let client = client
                Task { _ = try? await client.request(path: "\(path)/\(requestID)/cancel", method: "POST", body: nil, authenticated: true) }
            }
            throw error
        }
    }

    private func remember(_ version: VersionDTO) throws -> RoutePlan {
        let plan = RoutePlan(id: version.id, routeID: version.route_id, title: version.title,
            pois: version.stops.sorted { $0.order < $1.order }.map {
                RoutePOI(id: $0.place.id, name: $0.place.name, coordinate: $0.place.location.coordinate,
                    description: $0.place.description, visitRadiusMeters: Double($0.visit_radius_m), minimumDwellSeconds: Double($0.min_dwell_s))
            }, legs: version.legs.enumerated().map { index, leg in RouteLeg(id: "\(version.id)-\(index)", coordinates: leg.points.map(\.coordinate)) },
            isDemo: false, start: version.start.coordinate, end: version.end.coordinate)
        try plan.validate()
        details[plan.id] = LiveRouteDetails(routeID: plan.routeID, versionID: plan.id,
            distanceMeters: version.summary.distance_m, durationSeconds: version.summary.duration_s,
            issuedAt: version.created_at, externalMapsURL: version.yandex_maps_url,
            stops: version.stops.sorted { $0.order < $1.order }.map {
                .init(placeID: $0.place.id, category: $0.place.categories.first ?? "Место прогулки", address: $0.place.address,
                    hours: $0.place.hours_text, openNow: $0.place.open_now, rating: $0.place.rating, photoURL: $0.place.photo_url,
                    walkSeconds: $0.walk_from_previous_s, reasons: $0.reasons.map(\.text), fallback: $0.reason_fallback)
            })
        if let detailsURL {
            try FileManager.default.createDirectory(at: detailsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(details).write(to: detailsURL, options: .atomic)
        }
        return plan
    }

    private func point(_ coordinate: Coordinate) -> [String: Double] { ["lat": coordinate.latitude, "lon": coordinate.longitude] }
    private func send(_ path: String, method: String, object: [String: Any]) async throws -> Data {
        try await client.request(path: path, method: method, body: JSONSerialization.data(withJSONObject: object), authenticated: true)
    }
    private func decode<T: Decodable>(_ path: String) async throws -> T {
        try JSONDecoder().decode(T.self, from: await client.request(path: path, method: "GET", body: nil, authenticated: true))
    }

    private struct PointDTO: Decodable { let lat: Double; let lon: Double; var coordinate: Coordinate { .init(latitude: lat, longitude: lon) } }
    private struct ContextDTO: Decodable {
        struct Definition: Decodable { let questions: [RouteContextQuestion] }
        struct Answer: Decodable { let question_id: String; let kind: String; let option_ids: [String]? }
        let flow: String
        let definition: Definition
        let answers: [Answer]?
        let complete: Bool?
        let next_question_id: String?
        let phrase_submitted: Bool?
        var definitionValue: RouteContextDefinition {
            var value = RouteContextDefinition(branch: flow == "questions" ? .c1 : (flow == "phrase" ? .c2 : .c0), questions: definition.questions)
            for answer in answers ?? [] {
                if answer.kind == "choice" { value.storedAnswers[answer.question_id] = answer.option_ids ?? [] }
                if answer.kind == "skip" { value.skippedQuestions.insert(answer.question_id) }
            }
            value.isComplete = complete ?? false
            value.nextQuestionID = next_question_id
            value.phraseSubmitted = phrase_submitted ?? false
            return value
        }
    }
    private struct GenerationDTO: Decodable { let status: String; let version_id: String?; let problem: BackendProblem?; let stage: String?; let candidates_found: Int? }
    private struct SummaryDTO: Decodable { let distance_m: Int; let duration_s: Int }
    private struct PlaceDTO: Decodable {
        let id: String; let name: String; let location: PointDTO; let categories: [String]
        let description: String?; let address: String?; let hours_text: String?; let open_now: Bool?; let rating: Double?; let photo_url: URL?
    }
    private struct ReasonDTO: Decodable { let text: String }
    private struct StopDTO: Decodable {
        let order: Int; let place: PlaceDTO; let walk_from_previous_s: Int; let visit_radius_m: Int; let min_dwell_s: Int
        let reasons: [ReasonDTO]; let reason_fallback: String?
    }
    private struct LegDTO: Decodable { let points: [PointDTO] }
    private struct VersionDTO: Decodable {
        let id: String; let route_id: String; let title: String; let created_at: String; let summary: SummaryDTO
        let start: PointDTO; let end: PointDTO; let stops: [StopDTO]; let legs: [LegDTO]; let yandex_maps_url: URL?
    }
    private struct RouteDTO: Decodable { let latest_version: VersionDTO? }
    private struct CorrectionDTO: Decodable { let id: String; let status: String; let constraints: [ReasonDTO] }
}
