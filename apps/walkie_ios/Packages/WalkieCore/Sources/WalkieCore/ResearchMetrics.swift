import Foundation

public struct ResearchAlgorithmMetrics: Codable, Sendable {
    public let falseEvents: Int
    public let onRouteSeconds: Double
    public let falseEventsPerHour: Double?
    public let eligibleDeviations: Int
    public let detectionsWithin30Seconds: Int
    public let r30: Double?
    public let uncertainIncludingPauseSeconds: Double
    public let uncertaintyFraction: Double?
    public let hitDelaysSeconds: [Double]
    public let hitsByIntent: [String: Int]
    public let deviationsByIntent: [String: Int]
}

public struct ResearchMetricsReport: Codable, Sendable {
    public let schemaVersion: Int
    public let totalSeconds: Double
    public let unlabelledSeconds: Double
    public let shortOrCensoredDeviations: Int
    public let a: ResearchAlgorithmMetrics
    public let b1: ResearchAlgorithmMetrics
    public let falseEventRatio: Double?
    public let r30Difference: Double?
    public let interpretation: String
}

/// Point estimates only. Labels are observer annotations, never inferred from GPS.
/// Pauses are unioned with uncertain intervals rather than double-counted.
public enum ResearchMetrics {
    public static func calculate(_ events: [ResearchEvent]) -> ResearchMetricsReport {
        let sorted = events.sorted { $0.sequence < $1.sequence }
        let total = max(0, sorted.last?.elapsed ?? 0)
        var normalizedTimes: [Double] = []
        var previousTime = 0.0
        for event in sorted {
            previousTime = max(previousTime, min(total, event.elapsed))
            normalizedTimes.append(previousTime)
        }
        // Inputs and labels are not proof that the detector was executing.
        // Compute decision gaps independently, before integrating durations, so
        // a stream of motion events cannot retrospectively fill a missing
        // heartbeat interval with the last known on-route state.
        var executionGaps: [(start: Double, end: Double)] = []
        var lastDecision = 0.0
        for (event, time) in zip(sorted, normalizedTimes) where event.pair != nil {
            if time - lastDecision > 3 { executionGaps.append((lastDecision, time)) }
            lastDecision = time
        }
        if total - lastDecision > 3 { executionGaps.append((lastDecision, total)) }
        var gapIndex = 0
        var geometry = ResearchGeometry.unknown
        var intent = ResearchIntent.unknown
        var currentA = ResearchState.uncertain, currentB = ResearchState.uncertain
        var paused = false, lastTime = 0.0, ton = 0.0, unlabelled = 0.0
        var uncertainA = 0.0, uncertainB = 0.0
        var falseA = 0, falseB = 0
        var alertsA: [Double] = [], alertsB: [Double] = []
        var episodes: [(start: Double, end: Double, intent: ResearchIntent)] = []
        var deviationStart: Double?
        var deviationIntent = ResearchIntent.unknown
        for (event, time) in zip(sorted, normalizedTimes) {
            let dt = time - lastTime
            if geometry == .onRoute { ton += dt }
            if geometry == .unknown { unlabelled += dt }
            // Conservatively count the whole gap between detector decisions
            // when it exceeds three seconds. Union with pause/uncertain rather
            // than double-counting their overlap.
            while gapIndex < executionGaps.count, executionGaps[gapIndex].end <= lastTime { gapIndex += 1 }
            var cursor = gapIndex, executionUnknownSeconds = 0.0
            while cursor < executionGaps.count, executionGaps[cursor].start < time {
                executionUnknownSeconds += max(0, min(time, executionGaps[cursor].end) - max(lastTime, executionGaps[cursor].start))
                cursor += 1
            }
            uncertainA += paused || currentA == .uncertain ? dt : executionUnknownSeconds
            uncertainB += paused || currentB == .uncertain ? dt : executionUnknownSeconds
            if event.kind == .pause { paused = true }
            if event.kind == .resume { paused = false; currentA = .uncertain; currentB = .uncertain }
            if let pair = event.pair {
                currentA = pair.a.state; currentB = pair.b1.state
                if pair.a.newAlert {
                    alertsA.append(time)
                    if geometry == .onRoute { falseA += 1 }
                }
                if pair.b1.newAlert {
                    alertsB.append(time)
                    if geometry == .onRoute { falseB += 1 }
                }
            }
            if let labelled = event.geometry {
                if labelled != geometry {
                    if let start = deviationStart {
                        episodes.append((start, time, deviationIntent)); deviationStart = nil
                    }
                    if labelled == .offRoute { deviationStart = time; deviationIntent = event.intent ?? .unknown }
                    geometry = labelled
                }
                intent = event.intent ?? intent
            }
            lastTime = time
        }
        if let start = deviationStart { episodes.append((start, total, deviationIntent)) }
        // A short/cropped episode cannot support the full 30-second endpoint.
        let eligible = episodes.filter { $0.end - $0.start >= 30 }
        func metrics(falseEvents: Int, alerts: [Double], uncertain: Double) -> ResearchAlgorithmMetrics {
            var delays: [Double] = [], hits: [String: Int] = [:], counts: [String: Int] = [:]
            for episode in eligible {
                counts[episode.intent.rawValue, default: 0] += 1
                if let alert = alerts.first(where: { $0 >= episode.start && $0 <= episode.start + 30 }) {
                    delays.append(alert - episode.start); hits[episode.intent.rawValue, default: 0] += 1
                }
            }
            return ResearchAlgorithmMetrics(falseEvents: falseEvents, onRouteSeconds: ton,
                falseEventsPerHour: ton > 0 ? 3600 * Double(falseEvents) / ton : nil,
                eligibleDeviations: eligible.count, detectionsWithin30Seconds: delays.count,
                r30: eligible.isEmpty ? nil : Double(delays.count) / Double(eligible.count),
                uncertainIncludingPauseSeconds: uncertain, uncertaintyFraction: total > 0 ? uncertain / total : nil,
                hitDelaysSeconds: delays, hitsByIntent: hits, deviationsByIntent: counts)
        }
        let ma = metrics(falseEvents: falseA, alerts: alertsA, uncertain: uncertainA)
        let mb = metrics(falseEvents: falseB, alerts: alertsB, uncertain: uncertainB)
        return ResearchMetricsReport(schemaVersion: 1, totalSeconds: total, unlabelledSeconds: unlabelled,
            shortOrCensoredDeviations: episodes.count - eligible.count, a: ma, b1: mb,
            falseEventRatio: mb.falseEventsPerHour.flatMap { b in b > 0 ? ma.falseEventsPerHour.map { $0 / b } : nil },
            r30Difference: ma.r30.flatMap { a in mb.r30.map { a - $0 } },
            interpretation: "Описательные оценки пилота. Нулевой знаменатель = null. Разрыв между вычислениями детектора более 3 секунд целиком учитывается как неопределённость исполнения; сырые входы и метки не заполняют разрыв. Доверительные границы и кластерный анализ не рассчитаны; подтверждение гипотезы не установлено. Независимость разметки проверяется исследователем.")
    }
}

/// Replays in delivery order. Late motion never changes a past decision.
public enum ResearchReplay {
    public static func decisions(route: RoutePlan, configuration: ResearchConfiguration, events: [ResearchEvent]) -> [ResearchPair] {
        var detector = PairedResearchDetector(route: route, configuration: configuration)
        var motion: ResearchMotion?
        var results: [ResearchPair] = []
        for event in events.sorted(by: { $0.sequence < $1.sequence }) {
            switch event.kind {
            case .motion: motion = event.motion
            case .resume: detector.resetAfterPause(); motion = nil
            case .location:
                if let point = event.coordinate, let accuracy = event.accuracy, let observedAt = event.observedAt {
                    results.append(detector.observe(coordinate: point, accuracy: accuracy, observedAt: observedAt,
                        receivedAt: event.recordedAt, elapsed: event.elapsed, motion: motion))
                }
            case .heartbeat: results.append(detector.heartbeat(at: event.elapsed))
            default: break
            }
        }
        return results
    }
}
