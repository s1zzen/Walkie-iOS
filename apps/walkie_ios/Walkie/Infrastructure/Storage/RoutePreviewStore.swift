import Foundation
import WalkieCore

/// Version replacements belong to the opened card, independently of the
/// planner's current draft or the original version retained in walk history.
actor RoutePreviewStore {
    private let url: URL?
    private var replacements: [String: RoutePlan] = [:]
    private var loaded = false
    private var corrupt = false

    init(url: URL? = nil) { self.url = url }

    func current(for original: RoutePlan) throws -> RoutePlan {
        try loadIfNeeded()
        var current = original
        var visited = Set<String>()
        while let next = replacements[current.id] {
            guard visited.insert(current.id).inserted, next.id != current.id,
                  next.routeID == original.routeID else { throw CocoaError(.fileReadCorruptFile) }
            current = next
        }
        return current
    }

    func save(_ candidate: RoutePlan, replacing source: RoutePlan) throws {
        try loadIfNeeded()
        try candidate.validate()
        guard candidate.routeID == source.routeID, candidate.id != source.id else { throw URLError(.badServerResponse) }
        var updated = replacements
        updated[source.id] = candidate
        try validate(updated)
        if let url {
            let data = try JSONEncoder().encode(updated)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        replacements = updated
    }

    private func loadIfNeeded() throws {
        guard !corrupt else { throw CocoaError(.fileReadCorruptFile) }
        guard !loaded else { return }
        do {
            if let url, FileManager.default.fileExists(atPath: url.path) {
                let restored = try JSONDecoder().decode([String: RoutePlan].self, from: Data(contentsOf: url))
                try validate(restored)
                replacements = restored
            }
            loaded = true
        } catch { corrupt = true; throw error }
    }

    private func validate(_ values: [String: RoutePlan]) throws {
        for (sourceID, plan) in values {
            guard !sourceID.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            try plan.validate()
            var seen: Set<String> = [sourceID]
            var current = plan
            while true {
                guard seen.insert(current.id).inserted, current.routeID == plan.routeID else { throw CocoaError(.fileReadCorruptFile) }
                guard let next = values[current.id] else { break }
                current = next
            }
        }
    }
}
