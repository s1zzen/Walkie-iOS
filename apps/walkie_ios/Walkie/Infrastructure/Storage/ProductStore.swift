import Foundation
import WalkieCore

struct UserProfile: Codable, Equatable, Sendable {
    var name: String
    var interests: [String]
    var onboardingComplete: Bool

    init(name: String = "", interests: [String] = [], onboardingComplete: Bool = false) {
        self.name = name
        self.interests = interests
        self.onboardingComplete = onboardingComplete
    }
}

enum WalkInterest: String, Codable, CaseIterable, Identifiable, Sendable {
    case architectureHistory = "architecture_history"
    case museumsExhibitions = "museums_exhibitions"
    case contemporaryArt = "contemporary_art"
    case parksNature = "parks_nature"
    case water
    case viewpoints
    case coffeeDesserts = "coffee_desserts"
    case foodMarkets = "food_markets"
    case localShops = "local_shops"
    case quietCourtyards = "quiet_courtyards"
    case photogenicPlaces = "photogenic_places"
    case outdoorSports = "outdoor_sports"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .architectureHistory: return "Архитектура"
        case .museumsExhibitions: return "Музеи"
        case .contemporaryArt: return "Искусство"
        case .parksNature: return "Парки и природа"
        case .water: return "У воды"
        case .viewpoints: return "Красивые виды"
        case .coffeeDesserts: return "Кофе и десерты"
        case .foodMarkets: return "Еда и рынки"
        case .localShops: return "Локальные магазины"
        case .quietCourtyards: return "Тихие дворы"
        case .photogenicPlaces: return "Места для фото"
        case .outdoorSports: return "Активный отдых"
        }
    }
    var icon: String {
        switch self {
        case .architectureHistory: return "building.columns"
        case .museumsExhibitions: return "photo.artframe"
        case .contemporaryArt: return "paintpalette"
        case .parksNature: return "leaf"
        case .water: return "water.waves"
        case .viewpoints: return "binoculars"
        case .coffeeDesserts: return "cup.and.saucer"
        case .foodMarkets: return "fork.knife"
        case .localShops: return "storefront"
        case .quietCourtyards: return "house.and.flag"
        case .photogenicPlaces: return "camera"
        case .outdoorSports: return "figure.walk"
        }
    }
}

struct ProductSnapshot: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var revision: UInt64 = 0
    var profile = UserProfile()
    var favoritePlaces: [RoutePOI] = []
    var savedRoutes: [RoutePlan] = []
}

enum ProductStoreError: LocalizedError {
    case unsupportedVersion
    case invalidData
    case missingInterests
    case writeUnavailable
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "Формат локального профиля пока не поддерживается. Исходный файл сохранён."
        case .invalidData: return "Локальный профиль повреждён. Исходный файл сохранён и не будет перезаписан."
        case .missingInterests: return "Выберите хотя бы один интерес."
        case .writeUnavailable: return "Запись остановлена после ошибки хранилища. Перезапустите приложение, чтобы проверить файл перед новым сохранением."
        }
    }
}

/// One writer for profile and library. Every mutation reads/validates first, then
/// atomically replaces the file. A damaged file is never replaced by defaults.
actor ProductStore {
    private let storageURL: URL
    private var cached: ProductSnapshot?
    private var writeUnavailable = false

    init(storageURL: URL) { self.storageURL = storageURL }

    func load() throws -> ProductSnapshot {
        guard !writeUnavailable else { throw ProductStoreError.writeUnavailable }
        if let cached { return cached }
        let data: Data
        do { data = try Data(contentsOf: storageURL) }
        catch {
            let fileError = error as NSError
            // fileExists also returns false for some access errors. Only a real
            // "no such file" is a first launch; unreadable data must not reset it.
            guard fileError.domain == NSCocoaErrorDomain,
                  fileError.code == CocoaError.fileReadNoSuchFile.rawValue else { throw error }
            let empty = ProductSnapshot()
            cached = empty
            return empty
        }
        let snapshot: ProductSnapshot
        do { snapshot = try JSONDecoder().decode(ProductSnapshot.self, from: data) }
        catch { throw ProductStoreError.invalidData }
        guard snapshot.schemaVersion == 1 else { throw ProductStoreError.unsupportedVersion }
        try validate(snapshot)
        cached = snapshot
        return snapshot
    }

    func saveProfile(_ profile: UserProfile) throws -> ProductSnapshot {
        var candidate = try load()
        var clean = profile
        clean.name = String(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        clean.interests = WalkInterest.allCases.map(\.rawValue).filter { profile.interests.contains($0) }
        if clean.onboardingComplete && clean.interests.isEmpty { throw ProductStoreError.missingInterests }
        candidate.profile = clean
        return try commit(candidate)
    }

    func toggleFavorite(_ poi: RoutePOI) throws -> ProductSnapshot {
        var candidate = try load()
        if candidate.favoritePlaces.contains(where: { $0.id == poi.id }) {
            candidate.favoritePlaces.removeAll { $0.id == poi.id }
        } else {
            candidate.favoritePlaces.insert(poi, at: 0)
        }
        return try commit(candidate)
    }

    func toggleSavedRoute(_ route: RoutePlan) throws -> ProductSnapshot {
        var candidate = try load()
        if candidate.savedRoutes.contains(where: { $0.id == route.id }) {
            candidate.savedRoutes.removeAll { $0.id == route.id }
        } else {
            candidate.savedRoutes.insert(route, at: 0)
        }
        return try commit(candidate)
    }

    private func commit(_ candidate: ProductSnapshot) throws -> ProductSnapshot {
        guard !writeUnavailable else { throw ProductStoreError.writeUnavailable }
        var next = candidate
        try validate(next)
        next.revision += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            // An I/O failure can leave commit status ambiguous. Do not follow it
            // with another write based on a possibly stale in-memory snapshot.
            writeUnavailable = true
            throw error
        }
        cached = next
        return next
    }

    private func validate(_ snapshot: ProductSnapshot) throws {
        guard snapshot.revision < UInt64.max,
              Set(snapshot.profile.interests).count == snapshot.profile.interests.count,
              snapshot.profile.interests.allSatisfy({ WalkInterest(rawValue: $0) != nil }),
              !snapshot.profile.onboardingComplete || !snapshot.profile.interests.isEmpty,
              Set(snapshot.favoritePlaces.map(\.id)).count == snapshot.favoritePlaces.count,
              Set(snapshot.savedRoutes.map(\.id)).count == snapshot.savedRoutes.count,
              snapshot.favoritePlaces.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && $0.coordinate.isValid }) else {
            throw ProductStoreError.invalidData
        }
        do { try snapshot.savedRoutes.forEach { try $0.validate() } }
        catch { throw ProductStoreError.invalidData }
    }
}
