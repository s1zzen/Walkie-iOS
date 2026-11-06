import Foundation

/// Два причинных детектора схода. Не исправляют координаты и не выполняют PDR.
/// `alert` — однократное событие подтверждённого входа в offRoute.
final class DetectorEngine {
    private let route: TestRoute
    private let configuration: DetectorConfiguration
    private var geometric = ConfirmationState()
    private var guarded = ConfirmationState()
    private var lastUpdateElapsed: Double?
    private var lastObservedTime: Double?
    private var lastFreshElapsed: Double?
    private var lastGuardedElapsed: Double?
    private var acceptedLocation: LocationSample?
    private var quarantine: Quarantine?
    private var stepEvidence: StepEvidence?

    init(route: TestRoute, configuration: DetectorConfiguration) {
        self.route = route
        // Импортированный конфиг также является недоверенным входом.
        var safe = configuration
        safe.enterDistance = Self.positive(configuration.enterDistance, fallback: 25)
        safe.exitDistance = min(safe.enterDistance, Self.nonnegative(configuration.exitDistance, fallback: 15))
        safe.confirmationSeconds = Self.nonnegative(configuration.confirmationSeconds, fallback: 4)
        safe.maximumAccuracy = Self.positive(configuration.maximumAccuracy, fallback: 35)
        safe.staleAfterSeconds = Self.positive(configuration.staleAfterSeconds, fallback: 10)
        safe.resetAfterSeconds = max(safe.staleAfterSeconds, Self.positive(configuration.resetAfterSeconds, fallback: 15))
        safe.maximumWalkingSpeed = Self.positive(configuration.maximumWalkingSpeed, fallback: 4)
        safe.jumpSlackMeters = Self.nonnegative(configuration.jumpSlackMeters, fallback: 20)
        safe.reacquisitionSeconds = Self.nonnegative(configuration.reacquisitionSeconds, fallback: 20)
        self.configuration = safe
    }

    func update(elapsed: Double, location: LocationSample?, motion: MotionSnapshot) -> [AlgorithmResult] {
        guard elapsed.isFinite, elapsed >= 0, lastUpdateElapsed.map({ elapsed >= $0 }) ?? true else {
            return currentResults(at: lastUpdateElapsed ?? 0, reason: "Неверное или немонотонное время события")
        }
        lastUpdateElapsed = elapsed
        expireEvidence(at: elapsed)

        guard route.isValid else {
            geometric.abstain(reason: "Не задан корректный маршрут")
            guarded.abstain(reason: "Не задан корректный маршрут")
            return currentResults(at: elapsed)
        }
        guard let location else { return currentResults(at: elapsed) }

        let observedTime = location.observedAt.timeIntervalSinceReferenceDate
        let receivedTime = location.receivedAt.timeIntervalSinceReferenceDate
        guard observedTime.isFinite, receivedTime.isFinite, location.elapsed.isFinite,
              location.elapsed >= 0, location.elapsed <= elapsed + 0.1,
              location.point.isValid, location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0 else {
            geometric.abstain(reason: "Некорректный фикс")
            guarded.abstain(reason: "Некорректный фикс")
            return currentResults(at: elapsed)
        }
        // Повторная доставка одного фикса не считается новым свидетельством.
        guard lastObservedTime.map({ observedTime > $0 }) ?? true else {
            return currentResults(at: elapsed, reason: "Повторный или переставленный фикс пропущен")
        }
        let age = receivedTime - observedTime + elapsed - location.elapsed
        guard age >= -1, age <= configuration.staleAfterSeconds else {
            geometric.abstain(reason: "Старый фикс или неверная метка времени")
            guarded.abstain(reason: "Старый фикс или неверная метка времени")
            return currentResults(at: elapsed)
        }
        let distance = RouteGeometry.distance(from: location.point, to: route)
        guard distance.isFinite else {
            geometric.abstain(reason: "Не удалось вычислить расстояние")
            guarded.abstain(reason: "Не удалось вычислить расстояние")
            return currentResults(at: elapsed)
        }
        lastObservedTime = observedTime
        // Возраст измерения учитывается и на последующих heartbeat.
        lastFreshElapsed = elapsed - max(0, age)
        let geometricAlert = geometric.accept(distance: distance, time: observedTime, configuration: configuration)

        var guardedAlert = false
        if location.horizontalAccuracy > configuration.maximumAccuracy {
            guarded.abstain(reason: "Заявленная погрешность слишком велика", distance: distance)
            stepEvidence = nil
        } else if let issue = screen(location, motion: motion, elapsed: elapsed) {
            guarded.abstain(reason: issue, distance: distance, suspicious: true)
        } else {
            lastGuardedElapsed = elapsed - max(0, age)
            guardedAlert = guarded.accept(distance: distance, time: observedTime, configuration: configuration)
        }
        return [
            geometric.result(at: elapsed, name: "geometric_v1", alert: geometricAlert),
            guarded.result(at: elapsed, name: "guarded_v1", alert: guardedAlert)
        ]
    }

    private func screen(_ location: LocationSample, motion: MotionSnapshot, elapsed: Double) -> String? {
        if var pending = quarantine {
            let returnDistance = RouteGeometry.distance(between: pending.origin.point, and: location.point)
            let returnLimit = configuration.jumpSlackMeters + accuracyAllowance(pending.origin, location)
            if returnDistance <= returnLimit {
                quarantine = nil
                acceptedLocation = location
                stepEvidence = nil
                _ = contradictsSteps(location, motion: motion, elapsed: elapsed)
                return nil
            }
            let interval = location.observedAt.timeIntervalSince(pending.last.observedAt)
            if interval <= configuration.resetAfterSeconds && isPlausible(from: pending.last, to: location) {
                pending.count += 1
                pending.last = location
            } else {
                pending.startedAt = location.observedAt
                pending.last = location
                pending.count = 1
            }
            if pending.count >= 3,
               location.observedAt.timeIntervalSince(pending.startedAt) >= configuration.reacquisitionSeconds {
                // Устойчивый новый кластер позволяет продолжить опыт, но не доказывает
                // истинность позиции: устойчивую подмену координат так не распознать.
                quarantine = nil
                acceptedLocation = location
                stepEvidence = nil
                guarded.reset(reason: "Новый кластер принят: требуется подтверждение состояния")
                _ = contradictsSteps(location, motion: motion, elapsed: elapsed)
                return nil
            }
            quarantine = pending
            return "Карантин скачка: проверяется устойчивость нового кластера"
        }

        if let previous = acceptedLocation {
            let interval = location.observedAt.timeIntervalSince(previous.observedAt)
            if interval > configuration.resetAfterSeconds {
                acceptedLocation = nil
                stepEvidence = nil
                guarded.reset(reason: "Новое начало после перерыва")
            } else {
                let jump = !isPlausible(from: previous, to: location)
                let stepConflict = contradictsSteps(location, motion: motion, elapsed: elapsed)
                if jump || stepConflict {
                    quarantine = Quarantine(origin: previous, last: location, startedAt: location.observedAt, count: 1)
                    stepEvidence = nil
                    return jump ? "Резкий скачок координат при пешеходном движении" : "Перемещение противоречит свежей истории шагов"
                }
            }
        }
        if acceptedLocation == nil { _ = contradictsSteps(location, motion: motion, elapsed: elapsed) }
        acceptedLocation = location
        return nil
    }

    private func isPlausible(from previous: LocationSample, to current: LocationSample) -> Bool {
        let interval = current.observedAt.timeIntervalSince(previous.observedAt)
        guard interval > 0 else { return false }
        let limit = configuration.maximumWalkingSpeed * interval + configuration.jumpSlackMeters + accuracyAllowance(previous, current)
        return RouteGeometry.distance(between: previous.point, and: current.point) <= limit
    }

    private func accuracyAllowance(_ lhs: LocationSample, _ rhs: LocationSample) -> Double {
        // Эвристический запас, а не статистически откалиброванная вероятность.
        hypot(lhs.horizontalAccuracy, rhs.horizontalAccuracy)
    }

    private func contradictsSteps(_ location: LocationSample, motion: MotionSnapshot, elapsed: Double) -> Bool {
        let freshness = min(3, configuration.staleAfterSeconds)
        guard motion.elapsed.isFinite, motion.elapsed <= elapsed + 0.1,
              let steps = motion.steps, steps >= 0,
              let stamp = motion.pedometerUpdatedAt, stamp.isFinite,
              stamp <= elapsed + 0.1, elapsed - stamp <= freshness else {
            stepEvidence = nil
            return false
        }
        let current = StepEvidence(location: location, steps: steps, latestSensorElapsed: stamp)
        guard var previous = stepEvidence else {
            stepEvidence = current
            return false
        }
        guard stamp > previous.latestSensorElapsed else { return false }
        guard stamp - previous.latestSensorElapsed <= freshness, steps >= previous.steps else {
            stepEvidence = current
            return false
        }
        let interval = location.observedAt.timeIntervalSince(previous.location.observedAt)
        let stepDelta = steps - previous.steps
        let distance = RouteGeometry.distance(between: previous.location.point, and: location.point)
        // Щедрая верхняя оценка 1,8 м/шаг + запас. Это лишь проверка согласованности:
        // неполные шаги, транспорт и задержки датчика способны дать ложное подозрение.
        let allowance = Double(stepDelta) * 1.8 + configuration.jumpSlackMeters + accuracyAllowance(previous.location, location)
        let conflict = interval >= configuration.confirmationSeconds && distance > allowance
        if stepDelta > 0 {
            stepEvidence = current
        } else {
            previous.latestSensorElapsed = stamp
            stepEvidence = previous
        }
        return conflict
    }

    private func expireEvidence(at elapsed: Double) {
        if let stamp = lastFreshElapsed {
            if elapsed - stamp > configuration.resetAfterSeconds {
                geometric.reset(reason: "Длительный перерыв геолокации")
                guarded.reset(reason: "Длительный перерыв геолокации")
                acceptedLocation = nil
                quarantine = nil
                stepEvidence = nil
            } else if elapsed - stamp > configuration.staleAfterSeconds {
                geometric.abstain(reason: "Нет свежих координат")
                guarded.abstain(reason: "Нет свежих координат")
                stepEvidence = nil
            }
        }
        if let stamp = lastGuardedElapsed, elapsed - stamp > configuration.staleAfterSeconds {
            // При продолжающемся карантине origin нужен для проверки возврата.
            guarded.abstain(reason: quarantine == nil ? "Нет свежих принятых координат" : "Карантин скачка", suspicious: quarantine != nil)
        }
    }

    private func currentResults(at elapsed: Double, reason: String? = nil) -> [AlgorithmResult] {
        [geometric.result(at: elapsed, name: "geometric_v1", reason: reason),
         guarded.result(at: elapsed, name: "guarded_v1", reason: reason)]
    }

    private static func positive(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value > 0 ? value : fallback
    }
    private static func nonnegative(_ value: Double, fallback: Double) -> Double {
        value.isFinite && value >= 0 ? value : fallback
    }

    private struct Quarantine {
        var origin: LocationSample
        var last: LocationSample
        var startedAt: Date
        var count: Int
    }
    private struct StepEvidence {
        var location: LocationSample
        var steps: Int
        var latestSensorElapsed: Double
    }
}

private struct ConfirmationState {
    var stable: RouteState?
    var visible: RouteState = .uncertain
    var pending: RouteState?
    var pendingSince: Double?
    var reason = "Ожидание координат"
    var distance: Double?
    var suspicious = false

    mutating func accept(distance: Double, time: Double, configuration: DetectorConfiguration) -> Bool {
        self.distance = distance
        suspicious = false
        let target: RouteState
        if stable == .offRoute {
            target = distance < configuration.exitDistance ? .onRoute : .offRoute
        } else if stable == .onRoute {
            target = distance > configuration.enterDistance ? .offRoute : .onRoute
        } else if distance > configuration.enterDistance {
            target = .offRoute
        } else if distance < configuration.exitDistance {
            target = .onRoute
        } else {
            abstain(reason: "Позиция между порогами гистерезиса", distance: distance)
            return false
        }
        if target == stable {
            visible = target
            pending = nil
            pendingSince = nil
            reason = "Состояние подтверждается новым фиксом"
            return false
        }
        if pending != target {
            pending = target
            pendingSince = time
        }
        guard let start = pendingSince, time - start >= configuration.confirmationSeconds else {
            visible = stable ?? .uncertain
            reason = "Ожидание подтверждения последовательностью новых фиксов"
            return false
        }
        let alert = target == .offRoute && stable != .offRoute
        stable = target
        visible = target
        pending = nil
        pendingSince = nil
        reason = target == .offRoute ? "Подтверждён сход по расстоянию до маршрута" : "Подтверждено положение на маршруте"
        return alert
    }

    mutating func abstain(reason: String, distance: Double? = nil, suspicious: Bool = false) {
        visible = .uncertain
        pending = nil
        pendingSince = nil
        self.reason = reason
        self.distance = distance
        self.suspicious = suspicious
    }

    mutating func reset(reason: String) {
        stable = nil
        abstain(reason: reason)
    }

    func result(at elapsed: Double, name: String, alert: Bool = false, reason: String? = nil) -> AlgorithmResult {
        AlgorithmResult(elapsed: elapsed, algorithm: name, state: visible, alert: alert,
                        reason: reason ?? self.reason, distanceToRoute: distance, suspiciousLocation: suspicious)
    }
}

/// Расстояния на сфере; отдельные GPX-сегменты никогда не соединяются.
enum RouteGeometry {
    private static let earthRadius = 6_371_008.8

    static func distance(from point: GeoPoint, to route: TestRoute) -> Double {
        guard point.isValid else { return .infinity }
        var nearest = Double.infinity
        for segment in route.segments {
            for pair in zip(segment, segment.dropFirst()) where pair.0.isValid && pair.1.isValid {
                nearest = min(nearest, segmentDistance(point, pair.0, pair.1))
            }
        }
        return nearest
    }

    static func distance(between a: GeoPoint, and b: GeoPoint) -> Double {
        guard a.isValid && b.isValid else { return .infinity }
        return earthRadius * angle(a, b)
    }

    private static func segmentDistance(_ point: GeoPoint, _ start: GeoPoint, _ end: GeoPoint) -> Double {
        let length = angle(start, end)
        guard length > 1e-12, length < .pi - 1e-6 else {
            return min(distance(between: point, and: start), distance(between: point, and: end))
        }
        let pointAngle = angle(start, point)
        let bearingDifference = bearing(start, point) - bearing(start, end)
        let cross = asin(max(-1, min(1, sin(pointAngle) * sin(bearingDifference))))
        let along = atan2(sin(pointAngle) * cos(bearingDifference), cos(pointAngle))
        guard along >= 0 && along <= length else {
            return min(distance(between: point, and: start), distance(between: point, and: end))
        }
        return abs(cross) * earthRadius
    }

    private static func angle(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let latA = a.latitude * .pi / 180
        let latB = b.latitude * .pi / 180
        let deltaLat = latB - latA
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(deltaLat / 2), 2) + cos(latA) * cos(latB) * pow(sin(deltaLon / 2), 2)
        return 2 * atan2(sqrt(max(0, min(1, h))), sqrt(max(0, min(1, 1 - h))))
    }

    private static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let latA = a.latitude * .pi / 180
        let latB = b.latitude * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        return atan2(sin(deltaLon) * cos(latB), cos(latA) * sin(latB) - sin(latA) * cos(latB) * cos(deltaLon))
    }
}
