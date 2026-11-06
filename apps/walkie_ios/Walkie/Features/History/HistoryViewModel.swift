import Combine
import Foundation
import WalkieCore

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var sessions: [SessionRecord] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var exportFiles: [URL] = []
    @Published var showsShare = false
    private let store: LocalSessionStore
    private let exportDirectory: URL

    init(store: LocalSessionStore, exportDirectory: URL) {
        self.store = store
        self.exportDirectory = exportDirectory
    }

    func refresh() async {
        do { sessions = try await store.list() }
        catch { errorMessage = "Не удалось прочитать историю: \(userFacingError(error))" }
    }

    func export(_ session: SessionRecord) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            exportFiles = try await store.export(sessionID: session.id, to: exportDirectory)
            showsShare = true
        } catch { errorMessage = "Не удалось выгрузить сессию: \(userFacingError(error))" }
    }
}
