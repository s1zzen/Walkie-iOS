import Foundation
import XCTest
@testable import WalkieCore

final class ResearchStudyTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private var route: RoutePlan {
        RoutePlan(id: "study-v1", routeID: "study", title: "Контрольный маршрут", pois: [
            RoutePOI(id: "p1", name: "Ориентир", coordinate: Coordinate(latitude: 0, longitude: 0.01))
        ], legs: [RouteLeg(id: "l1", coordinates: [Coordinate(latitude: 0, longitude: 0), Coordinate(latitude: 0, longitude: 0.01)])], isDemo: false)
    }

    func testNoStepsAndStaleStepsReproduceB1Exactly() {
        for stale in [false, true] {
            var detector = PairedResearchDetector(route: route)
            for second in 0...35 {
                let date = epoch.addingTimeInterval(Double(second))
                let motion: ResearchMotion? = stale ? ResearchMotion(steps: 0, measuredAt: date.addingTimeInterval(-30), receivedAt: date, monotonicTime: Double(second)) : nil
                let pair = detector.observe(coordinate: Coordinate(latitude: Double(second) * 0.000025, longitude: 0.005), accuracy: 2,
                    observedAt: date, receivedAt: date, elapsed: Double(second), motion: motion)
                XCTAssertEqual(pair.a, pair.b1, "Unavailable steps must not become evidence of immobility")
                XCTAssertFalse(pair.freshSteps)
            }
        }
    }

    func testOnlyFreshStepsVaryWhileCoordinateGateIsCommon() {
        var detector = PairedResearchDetector(route: route)
        var bAlerts = 0, aAlerts = 0
        for second in 0...25 {
            let date = epoch.addingTimeInterval(Double(second))
            let pair = detector.observe(coordinate: Coordinate(latitude: Double(second) * 0.000025, longitude: 0.005), accuracy: 2,
                observedAt: date, receivedAt: date, elapsed: Double(second),
                motion: ResearchMotion(steps: 0, measuredAt: date, receivedAt: date, monotonicTime: Double(second)))
            if pair.a.newAlert { aAlerts += 1 }; if pair.b1.newAlert { bAlerts += 1 }
        }
        XCTAssertEqual(bAlerts, 1)
        XCTAssertEqual(aAlerts, 0)
        let bad = detector.observe(coordinate: Coordinate(latitude: 0.01, longitude: 0.005), accuracy: 100,
            observedAt: epoch.addingTimeInterval(26), receivedAt: epoch.addingTimeInterval(26), elapsed: 26, motion: nil)
        XCTAssertEqual(bad.a.state, .uncertain)
        XCTAssertEqual(bad.a, bad.b1, "Accuracy rejection and restoration rules must be shared")
    }

    func testFrequentStepIncrementsAccumulateBeforeRollingV2Anchor() {
        var detector = PairedResearchDetector(route: route)
        XCTAssertEqual(detector.configuration.version, "paired_steps_pilot_v2")
        var aAlerts = 0, bAlerts = 0, sawDifferentState = false
        for second in 0...24 {
            let time = Double(second), date = epoch.addingTimeInterval(time)
            // A cluster starts on route, then drifts about 9 m each second.
            // Individual fixes pass the configured coordinate gate's slack,
            // but the accumulated displacement exceeds the fresh-step budget.
            let latitude = Double(max(0, second - 4)) * 0.000081
            let pair = detector.observe(coordinate: Coordinate(latitude: latitude, longitude: 0.005), accuracy: 2,
                observedAt: date, receivedAt: date, elapsed: time,
                motion: ResearchMotion(steps: second, measuredAt: date, receivedAt: date, monotonicTime: time))
            if pair.a.newAlert { aAlerts += 1 }; if pair.b1.newAlert { bAlerts += 1 }
            if pair.a.state != pair.b1.state { sawDifferentState = true }
        }
        XCTAssertTrue(sawDifferentState, "One-second step updates must not reset the movement window before it can be checked")
        XCTAssertEqual(bAlerts, 1)
        XCTAssertEqual(aAlerts, 0)
    }

    func testFrequentConsistentWalkingStepsDoNotChangeB1Decisions() {
        var detector = PairedResearchDetector(route: route)
        for second in 0...40 {
            let time = Double(second), date = epoch.addingTimeInterval(time)
            let pair = detector.observe(coordinate: Coordinate(latitude: 0, longitude: 0.001 + time * 0.0000162), accuracy: 2,
                observedAt: date, receivedAt: date, elapsed: time,
                motion: ResearchMotion(steps: second, measuredAt: date, receivedAt: date, monotonicTime: time))
            XCTAssertEqual(pair.a, pair.b1, "Consistent walking must not be vetoed by holding the step window")
            XCTAssertTrue(pair.freshSteps)
        }
    }

    func testV1LogsRetainLegacyWindowRuleDuringReplay() {
        var configuration = ResearchConfiguration()
        configuration.version = "paired_steps_pilot_v1"
        var detector = PairedResearchDetector(route: route, configuration: configuration)
        for second in 0...24 {
            let time = Double(second), date = epoch.addingTimeInterval(time)
            let pair = detector.observe(coordinate: Coordinate(latitude: Double(max(0, second - 4)) * 0.000081, longitude: 0.005), accuracy: 2,
                observedAt: date, receivedAt: date, elapsed: time,
                motion: ResearchMotion(steps: second, measuredAt: date, receivedAt: date, monotonicTime: time))
            XCTAssertEqual(pair.a, pair.b1, "The known v1 behavior must remain reproducible for old manifests")
        }
    }

    func testHeartbeatExpiresPositionAndDuplicateFixCannotEmitAnotherAlert() {
        var detector = PairedResearchDetector(route: route)
        let point = Coordinate(latitude: 0.001, longitude: 0.005)
        _ = detector.observe(coordinate: point, accuracy: 2, observedAt: epoch, receivedAt: epoch, elapsed: 0, motion: nil)
        let alert = detector.observe(coordinate: point, accuracy: 2, observedAt: epoch.addingTimeInterval(4), receivedAt: epoch.addingTimeInterval(4), elapsed: 4, motion: nil)
        XCTAssertTrue(alert.b1.newAlert)
        let duplicate = detector.observe(coordinate: point, accuracy: 2, observedAt: epoch.addingTimeInterval(4), receivedAt: epoch.addingTimeInterval(5), elapsed: 5, motion: nil)
        XCTAssertFalse(duplicate.b1.newAlert)
        XCTAssertEqual(detector.heartbeat(at: 15).a.state, .uncertain)
    }

    func testReplayUsesDeliveryOrderAndNeverAppliesLateMotionRetroactively() {
        var live = PairedResearchDetector(route: route)
        var journal: [ResearchEvent] = []
        var expected: [ResearchPair] = []
        for second in 0...20 {
            let time = Double(second), date = epoch.addingTimeInterval(time)
            let motion = ResearchMotion(steps: 0, measuredAt: date, receivedAt: date, monotonicTime: time)
            // Deliver location first; the current motion arrives afterwards.
            let prior = second == 0 ? nil : ResearchMotion(steps: 0, measuredAt: date.addingTimeInterval(-1), receivedAt: date.addingTimeInterval(-1), monotonicTime: time - 1)
            let point = Coordinate(latitude: time * 0.000025, longitude: 0.005)
            let pair = live.observe(coordinate: point, accuracy: 2, observedAt: date, receivedAt: date, elapsed: time, motion: prior)
            journal.append(ResearchEvent(sequence: journal.count + 1, elapsed: time, recordedAt: date, monotonicTime: time,
                kind: .location, coordinate: point, accuracy: 2, observedAt: date, pair: pair))
            expected.append(pair)
            journal.append(ResearchEvent(sequence: journal.count + 1, elapsed: time, recordedAt: date, monotonicTime: time, kind: .motion, motion: motion))
        }
        XCTAssertEqual(ResearchReplay.decisions(route: route, configuration: .init(), events: journal), expected)
    }

    func testMetricsUseIndependentGeometryTimelyNewEventsAndUnionPauses() {
        var events: [ResearchEvent] = []
        func append(_ t: Int, _ kind: ResearchEvent.Kind, pair: ResearchPair? = nil, geometry: ResearchGeometry? = nil, intent: ResearchIntent? = nil) {
            events.append(ResearchEvent(sequence: events.count + 1, elapsed: Double(t), recordedAt: epoch.addingTimeInterval(Double(t)),
                monotonicTime: Double(t), kind: kind, pair: pair, geometry: geometry, intent: intent))
        }
        append(0, .label, geometry: .onRoute)
        for second in 0...100 {
            if second == 5 { append(second, .pause) }
            if second == 15 { append(second, .resume) }
            if second == 40 { append(second, .label, geometry: .offRoute, intent: .deliberate) }
            if second == 80 { append(second, .label, geometry: .onRoute) }
            let base: ResearchState = second < 10 ? .uncertain : .onRoute
            append(second, .heartbeat, pair: ResearchPair(
                a: ResearchDecision(state: second == 45 ? .offRoute : base, newAlert: second == 45, reason: "test", distanceMeters: nil),
                b1: ResearchDecision(state: second == 39 ? .offRoute : base, newAlert: second == 39, reason: "test", distanceMeters: nil), freshSteps: true))
        }
        append(100, .finish)
        let result = ResearchMetrics.calculate(events)
        XCTAssertEqual(result.a.onRouteSeconds, 60)
        XCTAssertEqual(result.a.falseEvents, 0)
        XCTAssertEqual(result.b1.falseEvents, 1)
        XCTAssertEqual(result.b1.falseEventsPerHour, 60)
        XCTAssertEqual(result.a.r30, 1)
        XCTAssertEqual(result.b1.r30, 0, "An alert before deviation onset is not a timely hit")
        XCTAssertEqual(result.a.uncertainIncludingPauseSeconds, 15, "Uncertain 0...10 union pause 5...15 is 15 seconds")
        XCTAssertEqual(result.a.hitsByIntent["deliberate"], 1, "A true deliberate deviation is not a false alert")
    }

    func testEmptyDenominatorsRemainUndefinedAndExecutionSilenceIsUnknown() {
        let events = [ResearchEvent(sequence: 1, elapsed: 0, recordedAt: epoch, monotonicTime: 0, kind: .heartbeat),
                      ResearchEvent(sequence: 2, elapsed: 50, recordedAt: epoch.addingTimeInterval(50), monotonicTime: 50, kind: .finish)]
        let report = ResearchMetrics.calculate(events)
        XCTAssertNil(report.a.falseEventsPerHour); XCTAssertNil(report.a.r30); XCTAssertNil(report.falseEventRatio)
        XCTAssertEqual(report.a.uncertaintyFraction, 1)
        XCTAssertEqual(report.unlabelledSeconds, 50)
    }

    func testMotionAndLabelsCannotMaskGapBetweenDetectorDecisions() {
        let onRoute = ResearchDecision(state: .onRoute, newAlert: false, reason: "test", distanceMeters: 0)
        let pair = ResearchPair(a: onRoute, b1: onRoute, freshSteps: true)
        var events: [ResearchEvent] = []
        func append(_ time: Int, kind: ResearchEvent.Kind, pair: ResearchPair? = nil, geometry: ResearchGeometry? = nil) {
            events.append(ResearchEvent(sequence: events.count + 1, elapsed: Double(time),
                recordedAt: epoch.addingTimeInterval(Double(time)), monotonicTime: Double(time),
                kind: kind, pair: pair, geometry: geometry))
        }
        append(0, kind: .label, geometry: .onRoute)
        append(0, kind: .heartbeat, pair: pair)
        // Raw inputs and independent labels continue to arrive, but no detector
        // decision/heartbeat is executed between zero and twenty seconds.
        for time in 1...19 {
            append(time, kind: .motion)
            if time == 5 || time == 15 { append(time, kind: .label, geometry: .onRoute) }
            if time == 8 { append(time, kind: .pause) }
            if time == 12 { append(time, kind: .resume) }
        }
        append(20, kind: .heartbeat, pair: pair)
        append(21, kind: .heartbeat, pair: pair)
        append(22, kind: .finish)
        let report = ResearchMetrics.calculate(events)
        XCTAssertEqual(report.a.uncertainIncludingPauseSeconds, 20)
        XCTAssertEqual(report.b1.uncertainIncludingPauseSeconds, 20)
        XCTAssertEqual(report.a.uncertaintyFraction, 20.0 / 22)
        XCTAssertEqual(report.a.onRouteSeconds, 22, "Independent known geometry remains in the common F denominator")

        // The missing tail after the last decision is also unknown even when
        // motion/label events prevent silence in the general journal.
        let noReturnDecision = events.filter { $0.elapsed < 20 || $0.kind == .finish }
        let tail = ResearchMetrics.calculate(noReturnDecision)
        XCTAssertEqual(tail.a.uncertaintyFraction, 1)
        XCTAssertEqual(tail.b1.uncertaintyFraction, 1)
    }

    func testResearchExportIncludesRawDataConfigurationMetricsAndFeedback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: out) }
        let store = LocalSessionStore(root: root)
        let session = try await store.create(route: route, at: epoch)
        try await store.beginResearch(ResearchManifest(sessionID: session.id, configuration: .init(), startedAt: epoch, monotonicStart: 0))
        try await store.appendResearch(sessionID: session.id, event: ResearchEvent(sequence: 1, elapsed: 10, recordedAt: epoch.addingTimeInterval(10), monotonicTime: 10, kind: .finish))
        _ = try await store.markSkipped(sessionID: session.id, poiID: "p1", at: epoch.addingTimeInterval(9))
        _ = try await store.setState(sessionID: session.id, state: .finished, at: epoch.addingTimeInterval(10))
        try await store.saveFeedback(sessionID: session.id, feedback: WalkFeedback(rating: 4, comment: "Пилот"))
        let files = try await store.export(sessionID: session.id, to: out)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(["session.json", "events.jsonl", "locations.jsonl", "research.json", "research.jsonl", "research_metrics.json", "feedback.json"]))
        let recovered = try await LocalSessionStore(root: root).read(sessionID: session.id)
        XCTAssertEqual(recovered.manualSkippedPOIIDs, ["p1"])
        XCTAssertTrue(recovered.manualVisitedPOIIDs.isEmpty)
        XCTAssertEqual(recovered.completionLabel, "unknown")
    }
}
