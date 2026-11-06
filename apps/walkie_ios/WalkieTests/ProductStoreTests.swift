import Foundation
import XCTest
import WalkieCore
@testable import Walkie

final class ProductStoreTests: XCTestCase {
    func testProfileAndLibrarySurviveFreshStore() async throws {
        let url = try temporaryURL()
        let original = ProductStore(storageURL: url)
        let profile = UserProfile(name: "Сергей", interests: ["parks_nature", "coffee_desserts"], onboardingComplete: true)
        _ = try await original.saveProfile(profile)
        _ = try await original.toggleFavorite(RoutePlan.demo.pois[0])
        _ = try await original.toggleSavedRoute(.demo)

        let restored = try await ProductStore(storageURL: url).load()
        XCTAssertEqual(restored.profile, profile)
        XCTAssertEqual(restored.favoritePlaces, [RoutePlan.demo.pois[0]])
        XCTAssertEqual(restored.savedRoutes, [.demo])
        XCTAssertEqual(restored.revision, 3)
    }

    func testRepeatedTogglesRemoveWithoutDuplicates() async throws {
        let store = ProductStore(storageURL: try temporaryURL())
        _ = try await store.toggleFavorite(RoutePlan.demo.pois[0])
        _ = try await store.toggleFavorite(RoutePlan.demo.pois[0])
        _ = try await store.toggleFavorite(RoutePlan.demo.pois[0])
        _ = try await store.toggleSavedRoute(.demo)
        _ = try await store.toggleSavedRoute(.demo)
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.favoritePlaces.count, 1)
        XCTAssertTrue(snapshot.savedRoutes.isEmpty)
    }

    func testConcurrentDifferentMutationsDoNotLoseData() async throws {
        let store = ProductStore(storageURL: try temporaryURL())
        async let favorite = store.toggleFavorite(RoutePlan.demo.pois[0])
        async let route = store.toggleSavedRoute(.demo)
        async let profile = store.saveProfile(UserProfile(name: "Test", interests: ["water"], onboardingComplete: true))
        _ = try await (favorite, route, profile)
        let snapshot = try await store.load()
        XCTAssertEqual(snapshot.favoritePlaces.count, 1)
        XCTAssertEqual(snapshot.savedRoutes.count, 1)
        XCTAssertEqual(snapshot.profile.name, "Test")
        XCTAssertEqual(snapshot.revision, 3)
    }

    func testCorruptFileIsPreservedAndCannotBeOverwrittenByMutation() async throws {
        let url = try temporaryURL()
        let corrupt = Data("preserve this damaged file".utf8)
        try corrupt.write(to: url)
        let store = ProductStore(storageURL: url)
        do { _ = try await store.load(); XCTFail("Expected decode failure") } catch {}
        do { _ = try await store.toggleSavedRoute(.demo); XCTFail("Expected mutation failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }

    func testUnsupportedSchemaIsPreserved() async throws {
        let url = try temporaryURL()
        var future = ProductSnapshot()
        future.schemaVersion = 999
        let data = try JSONEncoder().encode(future)
        try data.write(to: url)
        let store = ProductStore(storageURL: url)
        do {
            _ = try await store.saveProfile(UserProfile(interests: ["water"], onboardingComplete: true))
            XCTFail("Expected unsupported schema")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testCompletedProfileRequiresKnownInterestsAndNormalizesInput() async throws {
        let store = ProductStore(storageURL: try temporaryURL())
        do {
            _ = try await store.saveProfile(UserProfile(interests: ["unknown"], onboardingComplete: true))
            XCTFail("Expected missing interests")
        } catch {}
        let snapshot = try await store.saveProfile(UserProfile(name: "  Сергей\n", interests: ["water", "water", "unknown"], onboardingComplete: true))
        XCTAssertEqual(snapshot.profile.name, "Сергей")
        XCTAssertEqual(snapshot.profile.interests, ["water"])
    }

    @MainActor
    func testViewModelDoesNotPublishFailedWrite() async throws {
        let url = try temporaryURL()
        let blockedParent = url.deletingLastPathComponent().appendingPathComponent("not-a-directory")
        try Data("blocking file".utf8).write(to: blockedParent)
        let model = ProductViewModel(storageURL: blockedParent.appendingPathComponent("profile.json"))
        let saved = await model.saveProfile(UserProfile(name: "Not persisted", interests: ["water"], onboardingComplete: true))
        XCTAssertFalse(saved)
        XCTAssertFalse(model.profile.onboardingComplete)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
    }

    func testTemporaryReadFailureDoesNotCacheAnEmptyProfile() async throws {
        let url = try temporaryURL()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let store = ProductStore(storageURL: url)
        do { _ = try await store.load(); XCTFail("Expected an unreadable-file error") } catch {}

        try FileManager.default.removeItem(at: url)
        var original = ProductSnapshot()
        original.revision = 4
        original.profile = UserProfile(name: "Restored", interests: ["water"], onboardingComplete: true)
        try JSONEncoder().encode(original).write(to: url)

        let restored = try await store.load()
        XCTAssertEqual(restored, original)
    }

    @MainActor
    func testFailedEditAndReloadRetainPreviouslyConfirmedProfile() async throws {
        let url = try temporaryURL()
        let model = ProductViewModel(storageURL: url)
        let original = UserProfile(name: "Original", interests: ["water"], onboardingComplete: true)
        let initiallySaved = await model.saveProfile(original)
        XCTAssertTrue(initiallySaved)

        // Replace only this test-owned file with a directory, making the next
        // atomic write fail without relying on simulator permission behavior.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let edited = UserProfile(name: "Unsaved edit", interests: ["parks_nature"], onboardingComplete: true)
        let saved = await model.saveProfile(edited)
        XCTAssertFalse(saved)
        XCTAssertEqual(model.profile, original)
        XCTAssertNotNil(model.errorMessage)

        await model.load()
        XCTAssertEqual(model.profile, original)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testRepeatedLoadAndConcurrentTogglesKeepConfirmedProfile() async throws {
        let url = try temporaryURL()
        let model = ProductViewModel(storageURL: url)
        let original = UserProfile(name: "Sergey", interests: ["water"], onboardingComplete: true)
        await model.saveProfile(original)
        async let firstToggle: Void = model.toggleFavorite(RoutePlan.demo.pois[0])
        async let secondToggle: Void = model.toggleFavorite(RoutePlan.demo.pois[0])
        async let reload: Void = model.load()
        _ = await (firstToggle, secondToggle, reload)
        await model.load()
        XCTAssertEqual(model.profile, original)
        XCTAssertTrue(model.favoritePlaces.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testUnreadableFirstLoadRequiresSuccessfulRetryBeforeOnboarding() async throws {
        let url = try temporaryURL()
        try Data("temporarily unreadable JSON".utf8).write(to: url)
        let model = ProductViewModel(storageURL: url)
        await model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.isStorageReady)
        XCTAssertFalse(model.profile.onboardingComplete)
        XCTAssertNotNil(model.errorMessage)

        var original = ProductSnapshot()
        original.profile = UserProfile(name: "Existing user", interests: ["water"], onboardingComplete: true)
        try JSONEncoder().encode(original).write(to: url)
        await model.load()
        XCTAssertTrue(model.isStorageReady)
        XCTAssertEqual(model.profile, original.profile)
        XCTAssertNil(model.errorMessage)
    }

    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WalkieProductTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("product.json")
    }
}
