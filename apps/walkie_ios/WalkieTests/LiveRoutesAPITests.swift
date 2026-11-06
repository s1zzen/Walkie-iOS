import Foundation
import XCTest
import WalkieCore
@testable import Walkie

@MainActor
final class LiveRoutesAPITests: XCTestCase {
    func testUnknownGenerationOutcomeRetriesSameIdAfterDraftRestore() async throws {
        let transport = RouteContractTransport(firstGenerationOutcome: .responseLost)
        let api = LiveRoutesAPI(client: transport)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheURL = directory.appendingPathComponent("route.json")
        let model = PlanningViewModel(api: api, cacheURL: cacheURL)
        model.startNewDraft()
        let routeID = model.request.requestID
        let generationID = model.request.generationID
        let firstResult = await model.generate()
        XCTAssertFalse(firstResult)
        XCTAssertEqual(model.request.generationID, generationID, "A lost response is not evidence of terminal server failure")

        let restored = PlanningViewModel(api: api, cacheURL: cacheURL)
        await restored.loadDraftIfNeeded()
        XCTAssertEqual(restored.request.requestID, routeID)
        XCTAssertEqual(restored.request.generationID, generationID, "Idempotency must survive process restart")
        let retryResult = await restored.generate()
        XCTAssertTrue(retryResult)
        let calls = await transport.calls
        let generationIDs = calls.filter { $0.path.hasSuffix("/generations") }.compactMap { $0.object["request_id"] as? String }
        XCTAssertEqual(generationIDs, [generationID, generationID])
        XCTAssertEqual(restored.request.generationID, generationID, "A succeeded request keeps its attribution key")
    }

    func testOnlyConfirmedFailedOrCancelledGenerationRenewsItsIdempotencyKey() async throws {
        for outcome in [RouteContractTransport.FirstGenerationOutcome.failed, .cancelled] {
            let transport = RouteContractTransport(firstGenerationOutcome: outcome)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let model = PlanningViewModel(api: LiveRoutesAPI(client: transport), cacheURL: directory.appendingPathComponent("route.json"))
            model.startNewDraft()
            let routeID = model.request.requestID
            let originalID = model.request.generationID
            let firstResult = await model.generate()
            XCTAssertFalse(firstResult)
            XCTAssertNotEqual(model.request.generationID, originalID)
            XCTAssertEqual(model.request.requestID, routeID, "A retry remains in the same route/k assignment")
            let renewedID = model.request.generationID
            let retryResult = await model.generate()
            XCTAssertTrue(retryResult)
            let calls = await transport.calls
            let generationIDs = calls.filter { $0.path.hasSuffix("/generations") }.compactMap { $0.object["request_id"] as? String }
            XCTAssertEqual(generationIDs, [originalID, renewedID])
        }
    }

    func testQueuedGenerationPollsUntilVersionIsReady() async throws {
        let transport = RouteContractTransport(queued: true)
        let api = LiveRoutesAPI(client: transport)
        let plan = try await api.generateRoute(request: RouteRequest())
        XCTAssertEqual(plan.id, "version-id")
        let calls = await transport.calls
        XCTAssertTrue(calls.contains { $0.method == "GET" && $0.path.contains("/generations/") })
    }

    func testLiveAdapterUsesServerIDsPolylineAndVisitThresholdsWithoutUploadingTrack() async throws {
        let transport = RouteContractTransport()
        let api = LiveRoutesAPI(client: transport)
        var request = RouteRequest()
        request.origin = Coordinate(latitude: 55.75, longitude: 37.62)
        request.context.answers["K1"] = ["server_alone"]
        let plan = try await api.generateRoute(request: request)
        XCTAssertEqual(plan.id, "version-id")
        XCTAssertEqual(plan.routeID, "route-id")
        XCTAssertFalse(plan.isDemo)
        XCTAssertEqual(plan.pois.first?.visitRadiusMeters, 35)
        XCTAssertEqual(plan.pois.first?.minimumDwellSeconds, 40)
        XCTAssertEqual(plan.legs.first?.coordinates.count, 2)
        let details = await api.routeDetails(planID: plan.id)
        let adapter: any CoreAPI = api
        let protocolDetails = await adapter.routeDetails(planID: plan.id)
        XCTAssertNotNil(details, "Concrete async API must not select the protocol fallback")
        XCTAssertEqual(protocolDetails?.versionID, plan.id, "Existential dispatch must use the live metadata implementation")
        XCTAssertEqual(details?.durationSeconds, 1800)
        XCTAssertEqual(details?.distanceMeters, 1200)
        XCTAssertEqual(details?.stops.first?.reasons, ["Парки и природа"])
        let calls = await transport.calls
        XCTAssertFalse(calls.contains { $0.path.contains("track") || $0.path.contains("return-path") })
        let params = try XCTUnwrap(calls.first { $0.method == "PATCH" })
        let body = try XCTUnwrap(params.object["start"] as? [String: Any])
        let point = try XCTUnwrap(body["location"] as? [String: Double])
        XCTAssertEqual(point["lat"], 55.75)
        let answer = try XCTUnwrap(calls.first { $0.path.hasSuffix("/context/answers/K1") })
        XCTAssertEqual(answer.object["option_ids"] as? [String], ["server_alone"])
        XCTAssertFalse(calls.contains { $0.object["k"] != nil })
    }

    func testPhraseUsesServerFlowAndOneHundredFortyCharacterInputNotLocalParser() async throws {
        let transport = RouteContractTransport(flow: "phrase")
        let api = LiveRoutesAPI(client: transport)
        var request = RouteRequest()
        request.context.answers["K1"] = ["server_alone"]
        request.context.phrase = "спокойно погулять и выпить кофе"
        _ = try await api.generateRoute(request: request)
        let calls = await transport.calls
        let phrase = try XCTUnwrap(calls.first { $0.path.hasSuffix("/context/phrase") })
        XCTAssertEqual(phrase.object["text"] as? String, request.context.phrase)
        XCTAssertEqual(phrase.object["kind"] as? String, "text")
        XCTAssertFalse(calls.contains { $0.path.hasSuffix("/context/answers/K2") })
    }

    func testCorrectionRequiresServerConfirmationAndKeepsExistingRouteID() async throws {
        let transport = RouteContractTransport()
        let api = LiveRoutesAPI(client: transport)
        let plan = try await api.generateRoute(request: RouteRequest())
        let correction = try await api.parseCorrection(text: "покороче", plan: plan)
        XCTAssertTrue(correction.understood)
        XCTAssertEqual(correction.constraints, ["Более короткие переходы"])
        _ = try await api.applyCorrection(correction, plan: plan)
        let calls = await transport.calls
        let request = try XCTUnwrap(calls.last { $0.path.hasSuffix("/generations") })
        XCTAssertEqual(request.object["kind"] as? String, "correction")
        XCTAssertEqual(request.object["correction_id"] as? String, "correction-id")
        XCTAssertTrue(request.path.contains("route-id"))
        XCTAssertNil(request.object["places_count"])
    }

    func testDraftRestoresQuestionCoordinateAndAnswersAcrossViewModelLifetimes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cache = RoutePlanCache(url: directory.appendingPathComponent("plan.json"))
        let url = directory.appendingPathComponent("draft.json")
        let model = PlanningViewModel(api: MockCoreAPI(), cache: cache, draftURL: url)
        model.configureContextBranch(.c1)
        model.startNewDraft()
        let requestID = model.request.requestID
        model.request.origin = Coordinate(latitude: 55.73, longitude: 37.65)
        model.request.context.answers["K1"] = ["pair"]
        model.builderStep = .energy
        let flushed = await model.flushDraft()
        XCTAssertTrue(flushed)
        let restored = PlanningViewModel(api: MockCoreAPI(), cache: cache, draftURL: url)
        await restored.loadDraftIfNeeded()
        XCTAssertEqual(restored.request.requestID, requestID)
        XCTAssertEqual(restored.builderStep, .energy)
        XCTAssertEqual(restored.contextBranch, .c1)
        XCTAssertEqual(restored.request.context.answers["K1"], ["pair"])
        XCTAssertEqual(restored.request.origin, Coordinate(latitude: 55.73, longitude: 37.65))
        restored.startNewDraft()
        XCTAssertNotEqual(restored.request.requestID, requestID)
        XCTAssertTrue(restored.request.context.answers.isEmpty)
    }

    func testAlternativeAndCorrectionUnknownOutcomesResumePersistedOperationsAfterRestart() async throws {
        for kind in ["alternative", "correction"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let url = directory.appendingPathComponent("operations.json")
            let transport = RouteContractTransport()
            let api = LiveRoutesAPI(client: transport, operationsURL: url)
            let plan = try await api.generateRoute(request: RouteRequest())
            await transport.loseNextGenerationResponse()
            let correction = RouteCorrection(id: "correction-id", understood: true, constraints: ["Покороче"])
            do {
                if kind == "alternative" { _ = try await api.rebuildRoute(request: RouteRequest(), previousPlan: plan) }
                else { _ = try await api.applyCorrection(correction, plan: plan) }
                XCTFail("Lost reply must remain unknown")
            } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
            let before = await transport.calls
            let operationID = try XCTUnwrap(before.last { $0.path.hasSuffix("/generations") }?.object["request_id"] as? String)
            let restored = LiveRoutesAPI(client: transport, operationsURL: url)
            if kind == "alternative" { _ = try await restored.rebuildRoute(request: RouteRequest(), previousPlan: plan) }
            else { _ = try await restored.applyCorrection(correction, plan: plan) }
            let after = await transport.calls
            XCTAssertEqual(after.filter { $0.path.hasSuffix("/generations") }.count, before.filter { $0.path.hasSuffix("/generations") }.count, "Retry polls the accepted intent, not another POST")
            XCTAssertTrue(after.contains { $0.method == "GET" && $0.path.hasSuffix("/generations/\(operationID)") })
        }
    }

    func testCorrectionParseRetriesSameIDAfterLostResponseAndAdapterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("operations.json")
        let transport = RouteContractTransport()
        let api = LiveRoutesAPI(client: transport, operationsURL: url)
        let plan = try await api.generateRoute(request: RouteRequest())
        await transport.loseNextCorrectionResponse()
        do { _ = try await api.parseCorrection(text: "покороче", plan: plan); XCTFail("Expected response loss") } catch {}
        _ = try await LiveRoutesAPI(client: transport, operationsURL: url).parseCorrection(text: "покороче", plan: plan)
        let calls = await transport.calls
        let ids = calls.filter { $0.path.hasSuffix("/corrections") }.compactMap { $0.object["id"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last)
    }

    func testAlternativePollLossResumesSamePersistedGeneration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("operations.json")
        let transport = RouteContractTransport()
        let api = LiveRoutesAPI(client: transport, operationsURL: url)
        let plan = try await api.generateRoute(request: RouteRequest())
        await transport.queueNextGenerationAndLosePoll()
        do { _ = try await api.rebuildRoute(request: RouteRequest(), previousPlan: plan); XCTFail("Expected poll loss") } catch {}
        let before = await transport.calls
        let id = try XCTUnwrap(before.last { $0.path.hasSuffix("/generations") }?.object["request_id"] as? String)
        _ = try await LiveRoutesAPI(client: transport, operationsURL: url).rebuildRoute(request: RouteRequest(), previousPlan: plan)
        let after = await transport.calls
        XCTAssertEqual(after.filter { $0.path.hasSuffix("/generations") }.count, before.filter { $0.path.hasSuffix("/generations") }.count)
        XCTAssertEqual(after.filter { $0.path.hasSuffix("/generations/\(id)") }.count, 2)
    }

    func testAlternativeTerminalOutcomeAllowsNewIDButUnknownOutcomeDoesNot() async throws {
        for terminal in ["failed", "cancelled"] {
            let transport = RouteContractTransport()
            let api = LiveRoutesAPI(client: transport)
            let plan = try await api.generateRoute(request: RouteRequest())
            await transport.returnNextGenerationTerminal(terminal)
            do { _ = try await api.rebuildRoute(request: RouteRequest(), previousPlan: plan); XCTFail("Expected terminal outcome") }
            catch { XCTAssertTrue(error is RouteGenerationTerminalError) }
            _ = try await api.rebuildRoute(request: RouteRequest(), previousPlan: plan)
            let calls = await transport.calls
            let ids = calls.filter { $0.object["kind"] as? String == "alternative" }.compactMap { $0.object["request_id"] as? String }
            XCTAssertEqual(ids.count, 2)
            XCTAssertNotEqual(ids.first, ids.last)
        }
    }

    func testExplicitNewIntentAfterPresentedResultGetsNewOperationID() async throws {
        let transport = RouteContractTransport()
        let api = LiveRoutesAPI(client: transport)
        let source = try await api.generateRoute(request: RouteRequest())
        let result = try await api.rebuildRoute(request: RouteRequest(), previousPlan: source)
        await api.acknowledgeVersionResult(result, replacing: source, correctionID: nil)
        _ = try await api.rebuildRoute(request: RouteRequest(), previousPlan: source)
        let calls = await transport.calls
        let ids = calls.filter { $0.object["kind"] as? String == "alternative" }.compactMap { $0.object["request_id"] as? String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids.first, ids.last)
    }

    func testCreateOriginPreservesRestartAndParameterChangeAttribution() async throws {
        for origin in [RouteCreationOrigin.restart, .paramsChange] {
            let transport = RouteContractTransport()
            var request = RouteRequest()
            request.creationOrigin = origin; request.previousRouteID = "previous-route"
            _ = try await LiveRoutesAPI(client: transport).prepareContext(request: request)
            let calls = await transport.calls
            let creation = try XCTUnwrap(calls.first { $0.path == "/v1/routes" })
            XCTAssertEqual(creation.object["origin"] as? String, origin.rawValue)
            XCTAssertEqual(creation.object["previous_route_id"] as? String, "previous-route")
        }
    }

    func testParameterChangeUsesCompletedCopiedServerContextWithoutReaskingOrRewritingAnswers() async throws {
        let transport = RouteContractTransport(flow: "questions", contextComplete: true)
        let api = LiveRoutesAPI(client: transport)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = PlanningViewModel(api: api, cacheURL: directory.appendingPathComponent("route.json"))
        model.startParametersChange(from: .demo)
        let prepared = await model.prepareContext()
        XCTAssertTrue(prepared)
        XCTAssertEqual(model.builderStep, .generation)
        XCTAssertEqual(model.request.context.answers["K1"], ["server_alone"])
        let generated = await model.generate()
        XCTAssertTrue(generated)
        let calls = await transport.calls
        XCTAssertFalse(calls.contains { $0.path.contains("/context/answers/") }, "Server already copied the completed context")
    }

    func testOfflineFixtureRejectsAnUnrelatedPinInsteadOfReturningAnUnrelatedRoute() async throws {
        var request = RouteRequest()
        request.origin = Coordinate(latitude: 59.93, longitude: 30.31)
        do { _ = try await MockCoreAPI().generateRoute(request: request); XCTFail("An arbitrary point must not resolve to a fixed Moscow fixture") }
        catch { XCTAssertEqual((error as? RouteRequestError)?.localizedDescription, RouteRequestError.localDemoUnsupported.localizedDescription) }
    }

    func testDemoServerSwitchSelectsLiveTransport() async throws {
        let transport = RouteSwitchProbe()
        let local = SwitchingCoreAPI(client: transport, localDemo: true, serverRoutesEnabled: { false })
        _ = try await local.prepareContext(request: RouteRequest())
        let localCalls = await transport.paths
        XCTAssertTrue(localCalls.isEmpty)
        let server = SwitchingCoreAPI(client: transport, localDemo: true, serverRoutesEnabled: { true })
        do { _ = try await server.prepareContext(request: RouteRequest()); XCTFail("Probe must stop the request") }
        catch { XCTAssertEqual((error as? URLError)?.code, .userAuthenticationRequired) }
        let serverCalls = await transport.paths
        XCTAssertEqual(serverCalls, ["/v1/routes"])
    }
}

private actor RouteSwitchProbe: RouteBackendTransport {
    var paths: [String] = []
    func request(path: String, method: String, body: Data?, authenticated: Bool) async throws -> Data {
        paths.append(path)
        throw URLError(.userAuthenticationRequired)
    }
}

private actor RouteContractTransport: RouteBackendTransport {
    enum FirstGenerationOutcome { case responseLost, failed, cancelled }
    struct Call: Sendable {
        var path: String
        var method: String
        var data: Data?
        var object: [String: Any] { (try? data.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:] }
    }
    private(set) var calls: [Call] = []
    private let flow: String
    private let contextComplete: Bool
    private let queued: Bool
    private let firstGenerationOutcome: FirstGenerationOutcome?
    private var generationCount = 0
    private var loseGeneration = false
    private var loseCorrection = false
    private var queueNext = false
    private var losePoll = false
    private var nextTerminal: String?
    func loseNextGenerationResponse() { loseGeneration = true }
    func loseNextCorrectionResponse() { loseCorrection = true }
    func queueNextGenerationAndLosePoll() { queueNext = true }
    func returnNextGenerationTerminal(_ status: String) { nextTerminal = status }
    init(flow: String = "none", contextComplete: Bool = false, queued: Bool = false, firstGenerationOutcome: FirstGenerationOutcome? = nil) {
        self.flow = flow; self.contextComplete = contextComplete; self.queued = queued; self.firstGenerationOutcome = firstGenerationOutcome
    }
    func request(path: String, method: String, body: Data?, authenticated: Bool) async throws -> Data {
        calls.append(.init(path: path, method: method, data: body))
        XCTAssertTrue(authenticated)
        if path.hasSuffix("/context") {
            let answers = contextComplete ? "[{\"question_id\":\"K1\",\"kind\":\"choice\",\"option_ids\":[\"server_alone\"]}]" : "[]"
            return Data("{\"flow\":\"\(flow)\",\"complete\":\(contextComplete),\"answers\":\(answers),\"definition\":{\"questions\":[{\"id\":\"K1\",\"type\":\"single\",\"title\":\"Server K1\",\"required\":true,\"options\":[{\"id\":\"server_alone\",\"title\":\"Один\"}]}]}}".utf8)
        }
        if path.hasSuffix("/generations") {
            if loseGeneration { loseGeneration = false; throw URLError(.networkConnectionLost) }
            if let terminal = nextTerminal { nextTerminal = nil; return Data("{\"status\":\"\(terminal)\"}".utf8) }
            if queueNext { queueNext = false; losePoll = true; return Data("{\"status\":\"queued\"}".utf8) }
            generationCount += 1
            if generationCount == 1, let firstGenerationOutcome {
                switch firstGenerationOutcome {
                case .responseLost: throw URLError(.networkConnectionLost)
                case .failed: return Data("{\"status\":\"failed\",\"problem\":{\"code\":\"not_enough_places\",\"detail\":\"Рядом мало подходящих мест\"}}".utf8)
                case .cancelled: return Data("{\"status\":\"cancelled\"}".utf8)
                }
            }
            return Data((queued ? "{\"status\":\"queued\",\"stage\":\"collecting_places\"}" : "{\"status\":\"succeeded\",\"version_id\":\"version-id\"}").utf8)
        }
        if path.contains("/generations/") {
            if losePoll { losePoll = false; throw URLError(.networkConnectionLost) }
            return Data("{\"status\":\"succeeded\",\"version_id\":\"version-id\"}".utf8)
        }
        if path.contains("/versions/") { return Data(Self.version.utf8) }
        if path.hasSuffix("/corrections") {
            if loseCorrection { loseCorrection = false; throw URLError(.networkConnectionLost) }
            return Data("{\"id\":\"correction-id\",\"status\":\"understood\",\"constraints\":[{\"text\":\"Более короткие переходы\"}]}".utf8)
        }
        return Data("{}".utf8)
    }
    private static let version = """
    {"id":"version-id","route_id":"route-id","title":"Server route","created_at":"2026-10-23T10:00:00Z", "summary":{"distance_m":1200,"duration_s":1800},
    "start":{"lat":55.75,"lon":37.62},"end":{"lat":55.751,"lon":37.621},
    "stops":[{"order":1,"place":{"id":"server-place","name":"Сад","location":{"lat":55.751,"lon":37.621},"categories":["Парк"]},"walk_from_previous_s":300,"visit_radius_m":35,"min_dwell_s":40,"reasons":[{"text":"Парки и природа"}]}],
    "legs":[{"points":[{"lat":55.75,"lon":37.62},{"lat":55.751,"lon":37.621}]}]}
    """
}
