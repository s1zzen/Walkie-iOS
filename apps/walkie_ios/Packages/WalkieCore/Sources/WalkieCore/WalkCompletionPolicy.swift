import Foundation

public struct WalkCompletion: Equatable, Sendable {
    public let state: RecordingState
    public let method: String
}

/// Product completion is determined from explicit visit/skip actions, never from
/// independent research labels. Skipping every stop is not a completed walk.
public enum WalkCompletionPolicy {
    public static func requiredPOIIDs(in record: SessionRecord) -> [String] {
        let skipped = Set(record.manualSkippedPOIIDs ?? [])
        return record.route.pois.map(\.id).filter { !skipped.contains($0) }
    }

    public static func allRequiredVisited(in record: SessionRecord) -> Bool {
        let required = requiredPOIIDs(in: record)
        return !required.isEmpty && Set(required).isSubset(of: Set(record.visitedPOIIDs))
    }

    public static func canFinishAtLastPoint(in record: SessionRecord) -> Bool {
        guard let last = requiredPOIIDs(in: record).last else { return false }
        return record.visitedPOIIDs.contains(last)
    }

    public static func completion(for record: SessionRecord, atLastPoint: Bool = false) -> WalkCompletion? {
        if allRequiredVisited(in: record) { return WalkCompletion(state: .finished, method: "all_points") }
        if atLastPoint && canFinishAtLastPoint(in: record) {
            return WalkCompletion(state: .finished, method: "finish_last_point")
        }
        return nil
    }

    public static var interruption: WalkCompletion { WalkCompletion(state: .interrupted, method: "interrupted") }
}
