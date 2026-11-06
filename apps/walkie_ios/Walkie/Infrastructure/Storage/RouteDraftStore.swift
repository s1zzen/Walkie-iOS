import Foundation

/// Sequential disk effects, outside MainActor. Revisions reject delayed older
/// writes; the VM debounces typing and explicitly flushes before transitions.
actor RouteDraftStore {
    private let url: URL
    private var revision: UInt64 = 0
    private var corrupt = false
    private var loaded = false
    init(url: URL) { self.url = url }

    /// Only an explicit New/Restart action may recover from corruption. Keep
    /// the original bytes in a uniquely named sibling before accepting writes.
    @discardableResult
    func beginNewDraft(revision nextRevision: UInt64) throws -> URL? {
        if !loaded { _ = try? load() }
        var archive: URL?
        if corrupt, FileManager.default.fileExists(atPath: url.path) {
            let name = url.deletingPathExtension().lastPathComponent + ".corrupt-" + UUID().uuidString
            let destination = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(url.pathExtension)
            try FileManager.default.moveItem(at: url, to: destination)
            archive = destination
        }
        corrupt = false; loaded = true
        revision = max(revision, nextRevision)
        return archive
    }
    func load() throws -> RouteBuilderDraft? {
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let draft = try JSONDecoder().decode(RouteBuilderDraft.self, from: Data(contentsOf: url))
            try draft.request.validate()
            return draft
        } catch { corrupt = true; throw error }
    }
    func save(_ draft: RouteBuilderDraft, revision nextRevision: UInt64) throws {
        if !loaded { _ = try load() }
        guard nextRevision >= revision else { return }
        guard !corrupt else { throw CocoaError(.fileReadCorruptFile) }
        let data = try JSONEncoder().encode(draft)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        revision = nextRevision
    }
}
