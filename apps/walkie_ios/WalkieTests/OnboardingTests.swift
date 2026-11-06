import Foundation
import XCTest
@testable import Walkie

final class OnboardingTests: XCTestCase {
    @MainActor
    func testNormalLaunchShowsLoginInsteadOfResumingUnfinishedDemo() async throws {
        let url = try temporaryURL()
        var draft = OnboardingDraft()
        draft.environment = "local_demo"
        draft.authenticatedLocally = true
        draft.stage = .consent
        try await OnboardingStore(url: url).save(draft)
        let model = OnboardingViewModel(store: .init(url: url))
        await model.load()
        XCTAssertEqual(model.stage, .login)
        XCTAssertFalse(model.isDemo)
        XCTAssertFalse(model.draft.authenticatedLocally)
    }

    @MainActor
    func testEmailChoiceLeavesDemoAuthentication() async throws {
        let model = OnboardingViewModel(store: .init(url: try temporaryURL()), auth: OnboardingLocalAuthService())
        await model.load()
        await model.enterEmail()
        XCTAssertEqual(model.stage, .email)
        XCTAssertFalse(model.isDemo)
        XCTAssertEqual(model.draft.environment, "live")
        XCTAssertFalse(model.draft.authenticatedLocally)
    }

    func testValidationRejectsEmptyLongNameAndInvalidEmails() {
        XCTAssertFalse(OnboardingValidation.isValidName(" \n"))
        XCTAssertFalse(OnboardingValidation.isValidName(String(repeating: "я", count: 31)))
        XCTAssertTrue(OnboardingValidation.isValidName("  Сергей "))
        for email in ["", "name", "@example.com", "a@@b.ru", "a@b", "a b@c.ru", "a@.ru", "a@b..ru"] {
            XCTAssertFalse(OnboardingValidation.isValidEmail(email), email)
        }
        XCTAssertTrue(OnboardingValidation.isValidEmail("test+walk@example.org"))
    }

    @MainActor
    func testMandatoryInterestsNoPreselectionCannotSkipAndResumeAfterEveryTap() async throws {
        let url = try temporaryURL()
        let model = OnboardingViewModel(store: .init(url: url), auth: OnboardingLocalAuthService())
        await model.load()
        await model.startLocalDemo()
        await model.acceptConsent()
        model.name = " Сергей "
        await model.saveName()
        await model.startQuestions()
        XCTAssertTrue(model.selectedIDs.isEmpty)
        await model.skipQuestion()
        XCTAssertEqual(model.question.id, "P2")
        await model.skipQuestion()
        XCTAssertEqual(model.question.id, "P2")
        XCTAssertFalse(model.canContinueQuestion)
        for option in model.question.options.prefix(2) { await model.select(option) }
        await model.nextQuestion()
        XCTAssertEqual(model.question.id, "P2")

        let restored = OnboardingViewModel(store: .init(url: url), auth: OnboardingLocalAuthService())
        await restored.load()
        XCTAssertEqual(restored.question.id, "P2")
        XCTAssertEqual(restored.selectedIDs.count, 2)
        XCTAssertEqual(restored.draft.name, "Сергей")
        XCTAssertEqual(restored.draft.consent?.version, "1.0")
        XCTAssertNotNil(restored.draft.consent?.acceptedAt)
        await restored.select(restored.question.options[2])
        XCTAssertTrue(restored.canContinueQuestion)
        await restored.nextQuestion()
        XCTAssertEqual(restored.question.id, "P3")
    }

    @MainActor
    func testInterestsMaximumAndExclusiveNothingAreEnforced() async throws {
        let url = try temporaryURL()
        var draft = OnboardingDraft()
        draft.stage = .questionnaire
        draft.questionIndex = 1
        try await OnboardingStore(url: url).save(draft)
        let model = OnboardingViewModel(store: .init(url: url), auth: OnboardingLocalAuthService())
        await model.load()
        for option in model.question.options.prefix(6) { await model.select(option) }
        XCTAssertEqual(model.selectedIDs.count, 5)
        await model.editQuestion(12)
        await model.select(model.question.options[0])
        await model.select(model.question.options[6])
        XCTAssertEqual(model.selectedIDs, ["none"])
        await model.select(model.question.options[1])
        XCTAssertEqual(model.selectedIDs, ["queues"])
    }

    @MainActor
    func testOTPChallengeResumeAttemptLimitAndExpiration() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try temporaryURL()
        let model = OnboardingViewModel(store: .init(url: url), auth: OnboardingLocalAuthService(), now: { date })
        await model.load()
        model.email = "tester@example.com"
        await model.requestCode()
        XCTAssertEqual(model.stage, .code)
        model.code = "000000"
        await model.verifyCode()
        XCTAssertEqual(model.draft.challenge?.attemptsRemaining, 4)
        let restored = OnboardingViewModel(store: .init(url: url), auth: OnboardingLocalAuthService(), now: { date.addingTimeInterval(10) })
        await restored.load()
        XCTAssertEqual(restored.stage, .code)
        XCTAssertEqual(restored.draft.challenge?.id, model.draft.challenge?.id)
        XCTAssertEqual(restored.draft.challenge?.attemptsRemaining, 4)
        for _ in 0..<4 { restored.code = "000000"; await restored.verifyCode() }
        restored.code = "123456"
        await restored.verifyCode()
        XCTAssertFalse(restored.draft.authenticatedLocally)
        XCTAssertEqual(restored.stage, .code)
        XCTAssertNotNil(restored.errorMessage)
        let challenge = try XCTUnwrap(model.draft.challenge)
        do {
            _ = try await OnboardingLocalAuthService().verify(code: "123456", challenge: challenge, now: date.addingTimeInterval(601))
            XCTFail("Expired code should be rejected")
        } catch {}
    }

    @MainActor
    func testCompleteRequiresAllQuestionsAndEditingReturnsToSummary() async throws {
        let url = try temporaryURL()
        let model = OnboardingViewModel(store: .init(url: url), auth: OnboardingLocalAuthService())
        await model.load()
        await model.startLocalDemo()
        await model.acceptConsent()
        model.name = "Сергей"
        await model.saveName()
        await model.startQuestions()
        await model.skipQuestion()
        for option in model.question.options.prefix(3) { await model.select(option) }
        await model.nextQuestion()
        XCTAssertFalse(model.draft.canComplete)
        while model.stage == .questionnaire { await model.skipQuestion() }
        XCTAssertEqual(model.stage, .summary)
        let completed = await model.finish()
        XCTAssertTrue(completed)
        let restored = OnboardingViewModel(store: .init(url: url), auth: OnboardingLocalAuthService(), editing: true)
        await restored.load()
        XCTAssertEqual(restored.stage, .summary)
        let previousConfirmationID = restored.draft.confirmationRequestID
        await restored.editQuestion(8)
        await restored.select(restored.question.options[1])
        XCTAssertEqual(restored.stage, .summary)
        XCTAssertEqual(restored.draft.answers["P9"]?.optionIDs, ["option_2"])
        XCTAssertEqual(restored.draft.interests.count, 3)
        XCTAssertNotEqual(restored.draft.confirmationRequestID, previousConfirmationID)
        XCTAssertNil(restored.draft.completedAt)
        await restored.editQuestion(1)
        let removed = restored.question.options[0]
        let added = restored.question.options[3]
        await restored.select(removed)
        await restored.select(added)
        await restored.nextQuestion()
        XCTAssertFalse(restored.draft.interests.contains(removed.id))
        XCTAssertTrue(restored.draft.interests.contains(added.id))
        XCTAssertTrue(restored.interestTitles.contains(added.title))
        XCTAssertTrue(restored.summaryPhrases[0].contains(added.title.lowercased()))
        let savedEdit = await restored.finish()
        XCTAssertTrue(savedEdit)
        let reopened = OnboardingViewModel(store: .init(url: url), auth: OnboardingLocalAuthService(), editing: true)
        await reopened.load()
        XCTAssertEqual(reopened.draft.interests, restored.draft.interests)
        XCTAssertEqual(reopened.interestTitles, restored.interestTitles)
    }

    @MainActor
    func testDeclineErasesRegistrationAndAnswers() async throws {
        let model = OnboardingViewModel(store: .init(url: try temporaryURL()), auth: OnboardingLocalAuthService())
        await model.load()
        await model.startLocalDemo()
        await model.acceptConsent()
        model.name = "Private"
        await model.saveName()
        await model.startQuestions()
        await model.select(model.question.options[0])
        await model.declineConsent()
        XCTAssertEqual(model.stage, .declined)
        XCTAssertNil(model.draft.consent)
        XCTAssertFalse(model.draft.authenticatedLocally)
        XCTAssertTrue(model.draft.answers.isEmpty)
        XCTAssertTrue(model.draft.name.isEmpty)
    }

    func testCorruptAndFutureDraftsAreNeverOverwrittenByFreshStore() async throws {
        let url = try temporaryURL()
        let original = Data("do not destroy original".utf8)
        try original.write(to: url)
        let store = OnboardingStore(url: url)
        do { try await store.save(OnboardingDraft()); XCTFail("Expected corrupt-file rejection") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
        var future = OnboardingDraft(); future.schemaVersion = 99
        let futureData = try JSONEncoder().encode(future)
        try futureData.write(to: url)
        do { _ = try await OnboardingStore(url: url).load(); XCTFail("Expected schema rejection") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), futureData)
    }

    @MainActor
    func testForceLoginDoesNotResumeCompletedProfile() async throws {
        let url = try temporaryURL()
        var draft = OnboardingDraft()
        draft.authenticatedLocally = true
        draft.stage = .summary
        try await OnboardingStore(url: url).save(draft)
        let model = OnboardingViewModel(store: .init(url: url), auth: OnboardingLocalAuthService(), forceLogin: true)
        await model.load()
        XCTAssertEqual(model.stage, .login)
        XCTAssertFalse(model.draft.authenticatedLocally)
        XCTAssertFalse(model.isDemo)
    }

    @MainActor
    func testOfflineAnswersPersistLocallyAndRetryWithoutLosingPartialMultiselect() async throws {
        let url = try temporaryURL()
        var draft = OnboardingDraft()
        draft.stage = .questionnaire
        draft.questionIndex = 1
        draft.environment = "live"
        draft.authenticatedLocally = true
        draft.consent = .init(version: "1.0", acceptedAt: Date(), environment: "live")
        try await OnboardingStore(url: url).save(draft)
        let transport = OnboardingRecordingAuth()
        let model = OnboardingViewModel(store: .init(url: url), auth: transport, telemetryEnabled: false)
        await model.load()
        for option in model.question.options.prefix(3) { await model.select(option) }
        await model.nextQuestion()
        XCTAssertEqual(model.question.id, "P3")
        XCTAssertEqual(model.draft.pendingAnswerIDs, ["P2"])
        let persisted = try await OnboardingStore(url: url).load()
        XCTAssertEqual(persisted.answers["P2"]?.optionIDs.count, 3)

        await transport.setAvailable()
        let resumed = OnboardingViewModel(store: .init(url: url), auth: transport, telemetryEnabled: false)
        await resumed.load()
        await resumed.select(resumed.question.options[0])
        XCTAssertTrue(resumed.draft.pendingAnswerIDs.isEmpty)
        let delivered = await transport.deliveredQuestions()
        XCTAssertTrue(delivered.contains("P2"))
        XCTAssertTrue(delivered.contains("P3"))
    }

    @MainActor
    func testDifferentLiveOwnerCannotInheritPendingAnswersConsentOrVersionKey() async throws {
        let url = try temporaryURL()
        var old = OnboardingDraft()
        old.userID = "previous-owner"
        old.environment = "live"
        old.authenticatedLocally = true
        old.stage = .questionnaire
        old.name = "Предыдущий пользователь"
        old.pendingName = true
        old.pendingAnswerIDs = ["P3"]
        old.answers["P3"] = .init(optionIDs: ["option_1"], skipped: false, answeredAt: Date())
        old.consent = .init(version: "previous-owner-consent", acceptedAt: Date(), environment: "live")
        old.remoteSummary = ["Личные предпочтения предыдущего пользователя"]
        let oldVersionKey = old.confirmationRequestID
        try await OnboardingStore(url: url).save(old)
        let remote = OnboardingRemoteProfile(userID: "new-owner", name: "Новый пользователь", branch: "C1", confirmed: false,
            questions: OnboardingQuestion.all, questionnaireVersion: "2.0", answers: [:], nextQuestionID: "P1")
        let model = OnboardingViewModel(store: .init(url: url), auth: OnboardingNewOwnerAuth(remote: remote), telemetryEnabled: false)
        await model.load()
        XCTAssertEqual(model.draft.userID, "new-owner")
        XCTAssertTrue(model.draft.pendingAnswerIDs.isEmpty)
        XCTAssertFalse(model.draft.pendingName)
        XCTAssertTrue(model.draft.answers.isEmpty)
        XCTAssertNil(model.draft.remoteSummary)
        XCTAssertNotEqual(model.draft.consent?.version, "previous-owner-consent")
        XCTAssertNotEqual(model.draft.confirmationRequestID, oldVersionKey)
        XCTAssertEqual(model.draft.backendContextBranch, "C1")
    }

    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WalkieOnboardingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("onboarding.json")
    }
}

private actor OnboardingRecordingAuth: OnboardingAuthService {
    nonisolated let isLocalDemo = false
    nonisolated let deliveryExplanation = "Test transport"
    private var available = false
    private var delivered: [String] = []
    func setAvailable() { available = true }
    func deliveredQuestions() -> [String] { delivered }
    func requestCode(email: String, now: Date, requestID: UUID) async throws -> OnboardingCodeChallenge { throw URLError(.notConnectedToInternet) }
    func verify(code: String, challenge: OnboardingCodeChallenge, now: Date) async throws -> OnboardingAuthOutcome { throw URLError(.notConnectedToInternet) }
    func saveAnswer(question: String, answer: OnboardingAnswer) async throws {
        guard available else { throw URLError(.notConnectedToInternet) }
        delivered.append(question)
    }
}

private struct OnboardingNewOwnerAuth: OnboardingAuthService {
    let remote: OnboardingRemoteProfile
    let isLocalDemo = false
    let deliveryExplanation = "Test transport"
    func loadProfile() async throws -> OnboardingRemoteProfile? { remote }
    func requestCode(email: String, now: Date, requestID: UUID) async throws -> OnboardingCodeChallenge { throw URLError(.notConnectedToInternet) }
    func verify(code: String, challenge: OnboardingCodeChallenge, now: Date) async throws -> OnboardingAuthOutcome { .signedIn(remote) }
}
