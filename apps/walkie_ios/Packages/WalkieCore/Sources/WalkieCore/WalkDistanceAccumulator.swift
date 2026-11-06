import Foundation

/// Descriptive GPS distance, not ground truth or a completion classifier. A
/// value exists only after at least one accepted pair (which may measure zero).
public struct WalkDistanceAccumulator: Sendable {
    private struct Anchor: Sendable {
        let coordinate: Coordinate
        let accuracy: Double
        let observedAt: Date
        let segmentID: UUID
    }
    public private(set) var meters: Double?
    private var anchor: Anchor?

    public init(initialMeters: Double? = nil) {
        meters = initialMeters.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    public mutating func resetContinuity() { anchor = nil }

    public mutating func observe(coordinate: Coordinate, accuracy: Double, observedAt: Date,
                                 receivedAt: Date, segmentID: UUID) {
        let age = receivedAt.timeIntervalSince(observedAt)
        guard coordinate.isValid, accuracy.isFinite, accuracy >= 0, accuracy <= 35,
              age.isFinite, age >= -1, age <= 10 else { anchor = nil; return }
        let next = Anchor(coordinate: coordinate, accuracy: accuracy, observedAt: observedAt, segmentID: segmentID)
        defer { anchor = next }
        guard let previous = anchor, previous.segmentID == segmentID else { return }
        let dt = observedAt.timeIntervalSince(previous.observedAt)
        guard dt > 0, dt <= 15 else { return }
        let distance = ResearchDistance.between(previous.coordinate, coordinate)
        guard distance.isFinite, distance <= 4 * dt + 20 + hypot(previous.accuracy, accuracy) else { return }
        meters = (meters ?? 0) + distance
    }
}
