import Foundation

/// Protocol version is exported with every session. These are pilot settings,
/// not parameters approved for a confirmatory sample.
public struct ResearchConfiguration: Codable, Equatable, Sendable {
    public var version = "paired_steps_pilot_v2"
    public var enterMeters = 25.0
    public var exitMeters = 15.0
    public var confirmationSeconds = 4.0
    public var maximumAccuracyMeters = 35.0
    public var staleSeconds = 10.0
    public var resetSeconds = 15.0
    public var maximumWalkingSpeed = 4.0
    public var slackMeters = 20.0
    public var reacquisitionSeconds = 20.0
    public var stepFreshnessSeconds = 3.0
    public var maximumMetersPerStep = 1.8
    public init() {}
}

public enum ResearchGeometry: String, Codable, CaseIterable, Sendable {
    case onRoute = "on_route", offRoute = "off_route", unknown
}

public enum ResearchIntent: String, Codable, CaseIterable, Sendable {
    case deliberate, scriptedUnintended = "scripted_unintended"
    case naturalUnintended = "natural_unintended", unknown
}

public struct ResearchMotion: Codable, Equatable, Sendable {
    public let steps: Int
    public let measuredAt: Date
    public let receivedAt: Date
    public let monotonicTime: Double
    public init(steps: Int, measuredAt: Date, receivedAt: Date, monotonicTime: Double) {
        self.steps = steps; self.measuredAt = measuredAt
        self.receivedAt = receivedAt; self.monotonicTime = monotonicTime
    }
}

public enum ResearchState: String, Codable, Sendable { case onRoute = "on_route", offRoute = "off_route", uncertain }

public struct ResearchDecision: Codable, Equatable, Sendable {
    public var state: ResearchState
    public var newAlert: Bool
    public var reason: String
    public var distanceMeters: Double?
}

/// A and B1 see exactly the same delivered event. Ground truth is never an input.
public struct ResearchPair: Codable, Equatable, Sendable {
    public let a: ResearchDecision
    public let b1: ResearchDecision
    public let freshSteps: Bool
}

public struct ResearchEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case location, motion, heartbeat, pause, resume, label, finish }
    public let sequence: Int
    public let elapsed: Double
    public let recordedAt: Date
    public let monotonicTime: Double
    public let kind: Kind
    public let coordinate: Coordinate?
    public let accuracy: Double?
    public let observedAt: Date?
    public let motion: ResearchMotion?
    public let pair: ResearchPair?
    public let geometry: ResearchGeometry?
    public let intent: ResearchIntent?
    public let note: String?

    public init(sequence: Int, elapsed: Double, recordedAt: Date, monotonicTime: Double, kind: Kind,
                coordinate: Coordinate? = nil, accuracy: Double? = nil, observedAt: Date? = nil,
                motion: ResearchMotion? = nil, pair: ResearchPair? = nil,
                geometry: ResearchGeometry? = nil, intent: ResearchIntent? = nil, note: String? = nil) {
        self.sequence = sequence; self.elapsed = elapsed; self.recordedAt = recordedAt
        self.monotonicTime = monotonicTime; self.kind = kind; self.coordinate = coordinate
        self.accuracy = accuracy; self.observedAt = observedAt; self.motion = motion
        self.pair = pair; self.geometry = geometry; self.intent = intent; self.note = note
    }
}

public struct ResearchManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let configuration: ResearchConfiguration
    public let startedAt: Date
    public let monotonicStart: Double
    public let blinded: Bool
    public let evidenceStatus: String
    public let systemVersion: String
    public let appVersion: String
    public let device: String
    public init(sessionID: UUID, configuration: ResearchConfiguration, startedAt: Date, monotonicStart: Double,
                systemVersion: String = "unknown", appVersion: String = "unknown", device: String = "unknown") {
        schemaVersion = 1; self.sessionID = sessionID; self.configuration = configuration
        self.startedAt = startedAt; self.monotonicStart = monotonicStart; blinded = true
        evidenceStatus = "pilot_only; independent_observer_labels_required; no_confirmation_claim"
        self.systemVersion = systemVersion; self.appVersion = appVersion; self.device = device
    }
}

/// The common coordinate gate owns age/accuracy/speed/quarantine. The only
/// difference between A and B1 is a fresh-step veto after this gate.
public struct PairedResearchDetector: Sendable {
    public let configuration: ResearchConfiguration
    private let route: RoutePlan
    private var a = Confirmation()
    private var b1 = Confirmation()
    private var anchor: Fix?
    private var quarantine: Quarantine?
    private var lastObservedAt: Date?
    private var lastFreshTime: Double?
    private var stepAnchor: StepAnchor?
    private var lastPair: ResearchPair?

    public init(route: RoutePlan, configuration: ResearchConfiguration = .init()) {
        self.route = route; self.configuration = configuration
    }

    public mutating func resetAfterPause() {
        a = Confirmation(); b1 = Confirmation(); anchor = nil; quarantine = nil
        lastObservedAt = nil; lastFreshTime = nil; stepAnchor = nil; lastPair = nil
    }

    public mutating func heartbeat(at time: Double) -> ResearchPair {
        if let fresh = lastFreshTime, time - fresh <= configuration.staleSeconds {
            return pair(freshSteps: false)
        }
        if let fresh = lastFreshTime, time - fresh > configuration.resetSeconds {
            a = Confirmation(); b1 = Confirmation(); anchor = nil; quarantine = nil
        }
        stepAnchor = nil
        a.abstain("Нет свежих принятых координат"); b1.abstain("Нет свежих принятых координат")
        return pair(freshSteps: false)
    }

    public mutating func observe(coordinate: Coordinate, accuracy: Double, observedAt: Date,
                                 receivedAt: Date, elapsed: Double, motion: ResearchMotion?) -> ResearchPair {
        let age = receivedAt.timeIntervalSince(observedAt)
        guard coordinate.isValid, accuracy.isFinite, accuracy >= 0,
              age >= -1, age <= configuration.staleSeconds else {
            return reject("Старые или некорректные координаты")
        }
        guard lastObservedAt.map({ observedAt > $0 }) ?? true else {
            // Duplicate or reordered observations cannot renew evidence or emit alerts.
            return pair(freshSteps: false)
        }
        lastObservedAt = observedAt
        guard accuracy <= configuration.maximumAccuracyMeters else {
            return reject("Недостаточная заявленная точность")
        }
        let fix = Fix(coordinate: coordinate, accuracy: accuracy, observedAt: observedAt, elapsed: elapsed)
        if let anchor, observedAt.timeIntervalSince(anchor.observedAt) > configuration.resetSeconds {
            self.anchor = nil; quarantine = nil; stepAnchor = nil
            a = Confirmation(); b1 = Confirmation()
        }
        if var pending = quarantine {
            if ResearchDistance.between(pending.origin.coordinate, coordinate) <= allowance(pending.origin, fix) {
                quarantine = nil
            } else {
                if plausible(pending.last, fix) { pending.count += 1 }
                else { pending.startedAt = observedAt; pending.count = 1 }
                pending.last = fix
                if pending.count >= 3, observedAt.timeIntervalSince(pending.startedAt) >= configuration.reacquisitionSeconds {
                    quarantine = nil; a = Confirmation(); b1 = Confirmation(); stepAnchor = nil
                } else { quarantine = pending; return reject("Карантин скачка координат") }
            }
        } else if let anchor, !plausible(anchor, fix) {
            quarantine = Quarantine(origin: anchor, last: fix, startedAt: observedAt, count: 1)
            return reject("Физически несогласованный скачок координат")
        }
        anchor = fix
        lastFreshTime = elapsed - max(0, age)
        let distance = ResearchDistance.toRoute(coordinate, route: route)
        guard distance.isFinite else { return reject("Нет геометрии маршрута") }
        let fresh = motion.map { m in
            m.steps >= 0 && m.monotonicTime.isFinite
                && receivedAt.timeIntervalSince(m.measuredAt) >= -1
                && receivedAt.timeIntervalSince(m.measuredAt) <= configuration.stepFreshnessSeconds
                && m.receivedAt <= receivedAt
        } ?? false
        let conflict = fresh && stepConflict(fix, motion: motion!)
        let bAlert = b1.accept(distance, at: elapsed, config: configuration)
        let aAlert: Bool
        if conflict { a.abstain("Перемещение противоречит свежей истории шагов"); aAlert = false }
        else { aAlert = a.accept(distance, at: elapsed, config: configuration) }
        if !fresh { stepAnchor = nil }
        return pair(freshSteps: fresh, aAlert: aAlert, bAlert: bAlert)
    }

    private mutating func stepConflict(_ fix: Fix, motion: ResearchMotion) -> Bool {
        // Existing v1 logs retain their original rule when replayed. No
        // previously saved configuration is silently reinterpreted as v2.
        if configuration.version == "paired_steps_pilot_v1" {
            return stepConflictLegacyV1(fix, motion: motion)
        }
        let current = StepAnchor(fix: fix, motion: motion)
        guard let previous = stepAnchor else { stepAnchor = current; return false }
        guard motion.measuredAt > previous.latestMeasuredAt else { return false }
        guard motion.steps >= previous.latestSteps,
              motion.measuredAt.timeIntervalSince(previous.latestMeasuredAt) <= configuration.staleSeconds else {
            stepAnchor = current; return false
        }
        // The movement/step origin stays fixed for a full confirmation window.
        // Freshness and counter-order checks use the latest delivered sensor
        // sample, independently of that fixed origin.
        let delta = motion.steps - previous.motion.steps
        let permitted = Double(delta) * configuration.maximumMetersPerStep + allowance(previous.fix, fix)
        let windowComplete = fix.elapsed - previous.fix.elapsed >= configuration.confirmationSeconds
        let conflict = windowComplete && ResearchDistance.between(previous.fix.coordinate, fix.coordinate) > permitted
        if windowComplete && delta > 0 {
            // Evaluate the accumulated displacement first, then roll the
            // window. Zero-step windows preserve their fixed position origin
            // so slow drift during a stop can still accumulate above slack.
            stepAnchor = current
        } else {
            stepAnchor?.latestMeasuredAt = motion.measuredAt
            stepAnchor?.latestSteps = motion.steps
        }
        return conflict
    }

    private mutating func stepConflictLegacyV1(_ fix: Fix, motion: ResearchMotion) -> Bool {
        let current = StepAnchor(fix: fix, motion: motion)
        guard let previous = stepAnchor else { stepAnchor = current; return false }
        guard motion.measuredAt > previous.motion.measuredAt else { return false }
        guard motion.steps >= previous.motion.steps,
              motion.measuredAt.timeIntervalSince(previous.motion.measuredAt) <= configuration.staleSeconds else {
            stepAnchor = current; return false
        }
        let delta = motion.steps - previous.motion.steps
        let permitted = Double(delta) * configuration.maximumMetersPerStep + allowance(previous.fix, fix)
        let conflict = fix.elapsed - previous.fix.elapsed >= configuration.confirmationSeconds
            && ResearchDistance.between(previous.fix.coordinate, fix.coordinate) > permitted
        if delta > 0 { stepAnchor = current }
        else { stepAnchor?.motion = motion }
        return conflict
    }

    private func allowance(_ first: Fix, _ next: Fix) -> Double {
        configuration.slackMeters + hypot(first.accuracy, next.accuracy)
    }
    private func plausible(_ first: Fix, _ next: Fix) -> Bool {
        let dt = next.observedAt.timeIntervalSince(first.observedAt)
        return dt > 0 && ResearchDistance.between(first.coordinate, next.coordinate)
            <= configuration.maximumWalkingSpeed * dt + allowance(first, next)
    }
    private mutating func reject(_ reason: String) -> ResearchPair {
        a.abstain(reason); b1.abstain(reason); stepAnchor = nil
        return pair(freshSteps: false)
    }
    private mutating func pair(freshSteps: Bool, aAlert: Bool = false, bAlert: Bool = false) -> ResearchPair {
        let result = ResearchPair(a: a.decision(alert: aAlert), b1: b1.decision(alert: bAlert), freshSteps: freshSteps)
        lastPair = result; return result
    }
    private struct Fix: Sendable { let coordinate: Coordinate; let accuracy: Double; let observedAt: Date; let elapsed: Double }
    private struct Quarantine: Sendable { let origin: Fix; var last: Fix; var startedAt: Date; var count: Int }
    private struct StepAnchor: Sendable {
        let fix: Fix
        var motion: ResearchMotion
        var latestMeasuredAt: Date
        var latestSteps: Int
        init(fix: Fix, motion: ResearchMotion) {
            self.fix = fix; self.motion = motion
            latestMeasuredAt = motion.measuredAt; latestSteps = motion.steps
        }
    }
}

private struct Confirmation: Sendable {
    var stable: ResearchState?
    var visible = ResearchState.uncertain
    var pending: ResearchState?
    var since: Double?
    var reason = "Ожидание координат"
    var distance: Double?

    mutating func abstain(_ reason: String) {
        visible = .uncertain; pending = nil; since = nil; self.reason = reason; distance = nil
    }
    mutating func accept(_ distance: Double, at time: Double, config: ResearchConfiguration) -> Bool {
        self.distance = distance
        let target: ResearchState
        if stable == .offRoute { target = distance < config.exitMeters ? .onRoute : .offRoute }
        else if stable == .onRoute { target = distance > config.enterMeters ? .offRoute : .onRoute }
        else if distance > config.enterMeters { target = .offRoute }
        else if distance < config.exitMeters { target = .onRoute }
        else { abstain("Между порогами гистерезиса"); return false }
        if target == stable { visible = target; pending = nil; since = nil; reason = "Состояние подтверждено"; return false }
        if pending != target { pending = target; since = time }
        guard let since, time - since >= config.confirmationSeconds else {
            visible = stable ?? .uncertain; reason = "Ожидание временного подтверждения"; return false
        }
        let alert = target == .offRoute && stable != .offRoute
        stable = target; visible = target; pending = nil; self.since = nil
        reason = "Геометрическое состояние подтверждено"; return alert
    }
    func decision(alert: Bool) -> ResearchDecision {
        ResearchDecision(state: visible, newAlert: alert, reason: reason, distanceMeters: distance)
    }
}

public enum ResearchDistance {
    public static func between(_ a: Coordinate, _ b: Coordinate) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dlat = lat2 - lat1, dlon = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dlat / 2), 2) + cos(lat1) * cos(lat2) * pow(sin(dlon / 2), 2)
        return 6_371_008.8 * 2 * atan2(sqrt(max(0, min(1, h))), sqrt(max(0, 1 - min(1, h))))
    }
    public static func toRoute(_ point: Coordinate, route: RoutePlan) -> Double {
        // Local tangent plane is appropriate to these short Moscow walking legs.
        // Each leg is independent; missing geometry is never bridged.
        let scale = .pi * 6_371_008.8 / 180
        let cosLat = cos(point.latitude * .pi / 180)
        var nearest = Double.infinity
        for leg in route.legs {
            for (a, b) in zip(leg.coordinates, leg.coordinates.dropFirst()) {
                let ax = (a.longitude - point.longitude) * scale * cosLat
                let ay = (a.latitude - point.latitude) * scale
                let bx = (b.longitude - point.longitude) * scale * cosLat
                let by = (b.latitude - point.latitude) * scale
                let dx = bx - ax, dy = by - ay, length = dx * dx + dy * dy
                let t = length > 0 ? max(0, min(1, -(ax * dx + ay * dy) / length)) : 0
                nearest = min(nearest, hypot(ax + t * dx, ay + t * dy))
            }
        }
        return nearest
    }
}
