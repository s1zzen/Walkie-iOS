import Foundation

public enum RecordingState: String, Codable, Sendable {
    case recording
    case paused
    case finished
    case interrupted

    public var isClosed: Bool { self == .finished || self == .interrupted }
}

public enum WalkStartKind: String, Codable, Sendable {
    case regular
    case `repeat`
    case joint
}

/// Ending a recording does not imply that the pedestrian completed the route.
public struct SessionRecord: Codable, Sendable, Identifiable, Equatable {
    public let schemaVersion: Int
    public var id: UUID
    public var route: RoutePlan
    public var startedAt: Date
    public var endedAt: Date?
    public var state: RecordingState
    public var observationCount: Int
    public var manualVisitedPOIIDs: [String]
    /// Optional for decoding pre-study schema-1 sessions.
    public var manualSkippedPOIIDs: [String]?
    public var autoVisitedPOIIDs: [String]?
    public var completionLabel: String
    /// Product ending action; independent research completionLabel stays unknown.
    public var productFinishMethod: String?
    /// Optional for schema-1 manifests written before repeat attribution existed.
    public var startKind: WalkStartKind?

    public init(
        id: UUID = UUID(), route: RoutePlan, startedAt: Date,
        endedAt: Date? = nil, state: RecordingState = .recording,
        observationCount: Int = 0, manualVisitedPOIIDs: [String] = [],
        completionLabel: String = "unknown", kind: WalkStartKind = .regular
    ) {
        self.schemaVersion = 1
        self.id = id
        self.route = route
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.state = state
        self.observationCount = observationCount
        self.manualVisitedPOIIDs = manualVisitedPOIIDs
        self.manualSkippedPOIIDs = nil
        self.autoVisitedPOIIDs = nil
        self.completionLabel = completionLabel
        self.productFinishMethod = nil
        self.startKind = kind
    }

    public var visitedPOIIDs: [String] {
        var result = manualVisitedPOIIDs
        for id in autoVisitedPOIIDs ?? [] where !result.contains(id) { result.append(id) }
        return result
    }

    public var kind: WalkStartKind { startKind ?? .regular }
}

/// Sequence is shared by events and locations within a session. Monotonic time is
/// comparable only inside one segment; a new store instance starts a new segment.
public struct SessionLogMetadata: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: UUID
    public let sessionID: UUID
    public let segmentID: UUID
    public let sequence: Int
    public let recordedAt: Date
    public let monotonicTime: Double
}

public struct LocationObservation: Codable, Sendable, Equatable {
    public let metadata: SessionLogMetadata
    public let coordinate: Coordinate
    public let horizontalAccuracy: Double
    public let observedAt: Date
    public let receivedAt: Date
}

public struct SessionEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case created, stateChanged, manualVisit, automaticVisit, manualSkip, recovered
    }

    public let metadata: SessionLogMetadata
    public let kind: Kind
    public let state: RecordingState?
    public let endedAt: Date?
    public let poiID: String?
    public let reason: String?
    public var visitEvidence: AutomaticVisitEvidence? = nil
}

public enum SessionStorageError: Error, LocalizedError, Sendable {
    case unknownSession
    case notRecording
    case invalidTransition
    case invalidCoordinate
    case invalidAccuracy
    case invalidTime
    case unknownPOI
    case exportRequiresClosedSession
    case exportInsideStorage
    case corruptData(String)

    public var errorDescription: String? {
        switch self {
        case .unknownSession: "Прогулка не найдена в локальном хранилище."
        case .notRecording: "Запись координат возможна только во время активной прогулки."
        case .invalidTransition: "Недопустимое изменение состояния прогулки."
        case .invalidCoordinate: "Получены некорректные координаты."
        case .invalidAccuracy: "Получена некорректная точность геопозиции."
        case .invalidTime: "Получено некорректное время наблюдения."
        case .unknownPOI: "Эта точка не входит в маршрут прогулки."
        case .exportRequiresClosedSession: "Перед экспортом завершите запись прогулки."
        case .exportInsideStorage: "Папка экспорта должна находиться вне внутреннего хранилища."
        case .corruptData(let file): "Не удалось восстановить локальный журнал: \(file)."
        }
    }
}

public struct WalkFeedback: Codable, Sendable {
    public let rating: Int
    public let comment: String
    public let savedAt: Date
    public init(rating: Int, comment: String, savedAt: Date = Date()) {
        self.rating = rating; self.comment = comment; self.savedAt = savedAt
    }
}

/// A declined rating is an explicit local decision, not a zero-star rating.
public struct WalkFeedbackDecision: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case skip }
    public let kind: Kind
    public let sessionID: UUID
    public let at: Date
    public init(sessionID: UUID, at: Date) {
        kind = .skip; self.sessionID = sessionID; self.at = at
    }
}

public struct PausedSessionRecovery: Sendable {
    public let record: SessionRecord
    public let explicitPauseMetadata: SessionLogMetadata?
    public let hasResearchJournal: Bool
}
