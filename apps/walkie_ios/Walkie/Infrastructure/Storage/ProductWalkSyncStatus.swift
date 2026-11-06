import Foundation

/// Local persistence, waiting for the server and acknowledgement are different.
struct ProductWalkSyncStatus: Sendable, Equatable {
    enum Phase: String, Codable, Sendable { case localOnly, queued, requiresDistance, acknowledged }
    let phase: Phase
    let pendingOperations: Int
    let showProOffer: Bool
    let problem: String?
}

struct ProductWalkFinishAcknowledgement: Codable, Sendable, Equatable {
    let walkID: UUID
    let status: String
    let finishMethod: String?
    let showProOffer: Bool
    let acknowledgedAt: Date
    var proOfferShown: Bool
}

enum ProductWalkSyncError: Error, LocalizedError {
    case invalidFinishResponse
    var errorDescription: String? {
        "Сервер вернул некорректное подтверждение итога. Локальная прогулка и запрос сохранены; отправку можно повторить."
    }
}
