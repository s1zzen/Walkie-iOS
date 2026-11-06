import Foundation

public struct AutomaticVisitEvidence: Codable, Equatable, Sendable {
    public let radiusMeters: Double
    public let requiredDwellSeconds: Double
    public let observedDwellSeconds: Double
    public let accuracyMeters: Double
    public let detectedAt: Date
    public init(radiusMeters: Double, requiredDwellSeconds: Double, observedDwellSeconds: Double,
                accuracyMeters: Double, detectedAt: Date) {
        self.radiusMeters = radiusMeters; self.requiredDwellSeconds = requiredDwellSeconds
        self.observedDwellSeconds = observedDwellSeconds; self.accuracyMeters = accuracyMeters; self.detectedAt = detectedAt
    }
}

/// Product checkpoint candidate, not independent ground truth. The radius and
/// dwell are supplied by the route contract; absent values disable auto-visits.
public struct AutomaticVisitDetector: Sendable {
    private struct Candidate: Sendable {
        let poiID: String
        let measuredStart: Date
        let deliveredStart: Double
        var lastMeasured: Date
        var lastDelivered: Double
    }
    private var candidate: Candidate?
    public let maximumObservationGapSeconds: Double
    public init(maximumObservationGapSeconds: Double = 10) {
        self.maximumObservationGapSeconds = maximumObservationGapSeconds
    }
    public mutating func reset() { candidate = nil }

    public mutating func observe(poi: RoutePOI, coordinate: Coordinate, accuracy: Double,
        observedAt: Date, receivedAt: Date, monotonicTime: Double, qualityAccepted: Bool) -> AutomaticVisitEvidence? {
        guard qualityAccepted, coordinate.isValid, accuracy.isFinite, accuracy >= 0,
              let radius = poi.visitRadiusMeters, radius.isFinite, radius > 0,
              let dwell = poi.minimumDwellSeconds, dwell.isFinite, dwell >= 0,
              observedAt.timeIntervalSince1970.isFinite, receivedAt.timeIntervalSince1970.isFinite,
              monotonicTime.isFinite,
              receivedAt.timeIntervalSince(observedAt) >= -1,
              receivedAt.timeIntervalSince(observedAt) <= maximumObservationGapSeconds,
              ResearchDistance.between(coordinate, poi.coordinate) + accuracy <= radius else {
            reset(); return nil
        }
        if let previous = candidate, previous.poiID == poi.id {
            // A duplicate cannot accumulate dwell. Delivered batches cannot
            // retrospectively prove time spent inside the area.
            guard observedAt > previous.lastMeasured, monotonicTime > previous.lastDelivered else { return nil }
            if observedAt.timeIntervalSince(previous.lastMeasured) <= maximumObservationGapSeconds,
               monotonicTime - previous.lastDelivered <= maximumObservationGapSeconds {
                let observedDwell = min(observedAt.timeIntervalSince(previous.measuredStart), monotonicTime - previous.deliveredStart)
                candidate?.lastMeasured = observedAt; candidate?.lastDelivered = monotonicTime
                if observedDwell >= dwell {
                    reset()
                    return AutomaticVisitEvidence(radiusMeters: radius, requiredDwellSeconds: dwell,
                        observedDwellSeconds: observedDwell, accuracyMeters: accuracy, detectedAt: receivedAt)
                }
                return nil
            }
        }
        candidate = Candidate(poiID: poi.id, measuredStart: observedAt, deliveredStart: monotonicTime,
                              lastMeasured: observedAt, lastDelivered: monotonicTime)
        if dwell == 0 {
            reset()
            return AutomaticVisitEvidence(radiusMeters: radius, requiredDwellSeconds: 0,
                observedDwellSeconds: 0, accuracyMeters: accuracy, detectedAt: receivedAt)
        }
        return nil
    }
}
