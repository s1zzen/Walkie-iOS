import Foundation

/// One durable idempotency identity per displayed source version and user
/// intent. Unknown network outcomes are deliberately not terminal outcomes.
actor RouteOperationStore {
    struct Generation: Codable, Sendable {
        let requestID: String
        var versionID: String?
        var presented: Bool? = nil
    }
    struct Correction: Codable, Sendable {
        let requestID: String
        var result: RouteCorrection?
    }
    private struct State: Codable {
        var generations: [String: Generation] = [:]
        var corrections: [String: Correction] = [:]
    }
    private let url: URL?
    private var loaded = false
    private var state = State()
    init(url: URL?) { self.url = url }

    func generation(for key: String) throws -> (Generation, isNew: Bool) {
        try load()
        if let existing = state.generations[key], existing.presented != true { return (existing, false) }
        let value = Generation(requestID: UUID().uuidString)
        var next = state; next.generations[key] = value
        try commit(next)
        return (value, true)
    }
    func finishGeneration(key: String, versionID: String) throws {
        try load()
        var next = state; next.generations[key]?.versionID = versionID
        try commit(next)
    }
    func terminateGeneration(key: String) throws {
        try load()
        var next = state; next.generations.removeValue(forKey: key)
        try commit(next)
    }
    func acknowledgeGeneration(key: String, versionID: String) throws {
        try load()
        guard state.generations[key]?.versionID == versionID else { return }
        var next = state; next.generations[key]?.presented = true
        try commit(next)
    }
    func correction(for key: String) throws -> Correction {
        try load()
        if let existing = state.corrections[key] { return existing }
        let value = Correction(requestID: UUID().uuidString)
        var next = state; next.corrections[key] = value
        try commit(next)
        return value
    }
    func finishCorrection(key: String, result: RouteCorrection) throws {
        try load()
        var next = state; next.corrections[key]?.result = result
        try commit(next)
    }
    private func load() throws {
        guard !loaded else { return }
        if let url, FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
        }
        loaded = true
    }
    private func commit(_ next: State) throws {
        if let url {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
        }
        state = next
    }
}
