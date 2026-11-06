import Combine
import Foundation
import WalkieCore

@MainActor
final class ProductViewModel: ObservableObject {
    @Published private(set) var profile = UserProfile()
    @Published private(set) var favoritePlaces: [RoutePOI] = []
    @Published private(set) var savedRoutes: [RoutePlan] = []
    @Published private(set) var isLoaded = false
    @Published private(set) var isStorageReady = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    private let store: ProductStore
    private var revision: UInt64 = 0
    private var operationCount = 0

    init(storageURL: URL) { store = ProductStore(storageURL: storageURL) }

    func load() async {
        begin()
        defer { end(); isLoaded = true }
        do { apply(try await store.load()) }
        catch {
            isStorageReady = false
            errorMessage = "Не удалось открыть профиль: \(userFacingError(error))"
        }
    }

    @discardableResult
    func saveProfile(_ profile: UserProfile) async -> Bool {
        begin()
        defer { end() }
        do {
            apply(try await store.saveProfile(profile))
            return true
        } catch {
            errorMessage = "Не удалось сохранить профиль: \(userFacingError(error))"
            return false
        }
    }

    func toggleFavorite(_ poi: RoutePOI) async {
        begin()
        defer { end() }
        do { apply(try await store.toggleFavorite(poi)) }
        catch { errorMessage = "Не удалось изменить избранное: \(userFacingError(error))" }
    }

    func toggleSavedRoute(_ route: RoutePlan) async {
        begin()
        defer { end() }
        do { apply(try await store.toggleSavedRoute(route)) }
        catch { errorMessage = "Не удалось сохранить маршрут: \(userFacingError(error))" }
    }

    func isFavorite(id: String) -> Bool { favoritePlaces.contains { $0.id == id } }
    func isRouteSaved(id: String) -> Bool { savedRoutes.contains { $0.id == id } }

    private func begin() { operationCount += 1; isBusy = true; errorMessage = nil }
    private func end() { operationCount -= 1; isBusy = operationCount > 0 }
    private func apply(_ snapshot: ProductSnapshot) {
        // Tasks returning from the storage actor can resume in another order.
        guard snapshot.revision >= revision else { return }
        revision = snapshot.revision
        isStorageReady = true
        profile = snapshot.profile
        favoritePlaces = snapshot.favoritePlaces
        savedRoutes = snapshot.savedRoutes
    }
}
