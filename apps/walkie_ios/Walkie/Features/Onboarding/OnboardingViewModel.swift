import Combine
import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var draft = OnboardingDraft()
    @Published private(set) var isLoaded = false
    @Published private(set) var isBusy = false
    @Published private(set) var isStorageReady = false
    @Published var errorMessage: String?
    @Published var email = ""
    @Published var name = ""
    @Published var code = ""
    @Published var isEditingSummary = false
    @Published var showQuestionList = false
    private let store: OnboardingStore
    private var auth: any OnboardingAuthService
    private let editing: Bool
    private let forceLogin: Bool
    private let telemetryEnabled: Bool
    private let telemetry: any ProductTelemetryRecording
    private let now: () -> Date
    private var shownAt = Date()
    private var didShow = false

    init(store: OnboardingStore = OnboardingStore(), auth: any OnboardingAuthService = OnboardingLiveAuthService(), editing: Bool = false, forceLogin: Bool = false, telemetryEnabled: Bool = true, telemetry: any ProductTelemetryRecording = NoOpProductTelemetryRecorder(), now: @escaping () -> Date = Date.init) {
        self.store = store
        self.auth = auth
        self.editing = editing
        self.forceLogin = forceLogin
        self.telemetryEnabled = telemetryEnabled
        self.telemetry = telemetry
        self.now = now
    }

    var stage: OnboardingStage { draft.stage }
    var question: OnboardingQuestion { draft.questions[draft.questionIndex] }
    var selectedIDs: [String] { draft.answers[question.id]?.optionIDs ?? [] }
    var authExplanation: String { auth.deliveryExplanation }
    var isDemo: Bool { auth.isLocalDemo }
    var canContinueQuestion: Bool {
        selectedIDs.count >= max(1, question.minimum) && selectedIDs.count <= question.maximum
    }
    var validName: Bool { OnboardingValidation.isValidName(name) }
    var validEmail: Bool { OnboardingValidation.isValidEmail(email) }
    var screenID: String {
        switch stage {
        case .introduction: return "S-01"
        case .login: return "S-02"
        case .email: return "S-03"
        case .code: return "S-04"
        case .consent, .declined: return "S-05"
        case .name: return "S-06"
        case .rationale: return "S-08"
        case .questionnaire: return "S-09"
        case .summary, .complete: return "S-10"
        }
    }

    func load() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false; isLoaded = true }
        do {
            var loaded = try await store.load()
            let shouldShowLiveEntry = !editing && !auth.isLocalDemo && loaded.environment == "local_demo" && loaded.stage != .complete
            if loaded.environment == "local_demo", loaded.authenticatedLocally { auth = OnboardingLocalAuthService() }
            if shouldShowLiveEntry {
                auth = OnboardingLiveAuthService()
                loaded.stage = .login
                loaded.authenticatedLocally = false
            }
            if !auth.isLocalDemo {
                do {
                    if let remote = try await auth.loadProfile() { applyRemote(remote, to: &loaded) }
                } catch {
                    // Resume already authenticated local work offline. A fresh sign-in must succeed online.
                    if loaded.environment == "live", loaded.authenticatedLocally { errorMessage = "Нет связи: продолжим с ответами на устройстве." }
                }
            }
            if editing && loaded.canComplete { loaded.stage = .summary }
            if forceLogin {
                auth = OnboardingLiveAuthService()
                loaded.stage = .login
                loaded.authenticatedLocally = false
            }
            if loaded.stage == .introduction && loaded.introductionSeen { loaded.stage = .login }
            draft = loaded
            email = loaded.email
            name = loaded.name
            isStorageReady = true
            errorMessage = nil
            shownAt = now()
            if !didShow {
                var candidate = loaded
                candidate.events.append(event("shown"))
                try await store.save(candidate)
                draft = candidate
                didShow = true
                await recordShown(candidate)
            }
        } catch { isStorageReady = false; errorMessage = userFacingError(error) }
    }

    func introductionPage(_ page: Int) async {
        guard (0..<3).contains(page), page != draft.introductionIndex else { return }
        await change { $0.introductionIndex = page }
    }

    func nextIntroduction(skip: Bool = false) async {
        if skip { await recordTelemetry("onboarding_shown", screen: "S-01", payload: ["slide": String(draft.introductionIndex + 1), "skipped": "true"]) }
        await change { candidate in
            if skip || candidate.introductionIndex == 2 {
                candidate.introductionSeen = true
                candidate.stage = .login
            } else { candidate.introductionIndex += 1 }
        }
    }

    func enterEmail() async {
        if isDemo { await prepareLiveSignIn() }
        await recordTelemetry("login_method_selected", screen: "S-02", payload: ["method": "email"])
        await change { $0.stage = .email }
    }

    private func prepareLiveSignIn() async {
        auth = OnboardingLiveAuthService()
        await change { candidate in
            let seen = candidate.introductionSeen
            candidate = OnboardingDraft()
            candidate.introductionSeen = seen
            candidate.environment = "live"
            candidate.stage = .login
        }
    }

    func startLocalDemo() async {
        auth = OnboardingLocalAuthService()
        let saved = await change { candidate in
            let seen = candidate.introductionSeen
            candidate = OnboardingDraft()
            candidate.introductionSeen = seen
            candidate.environment = "local_demo"
            candidate.backendContextBranch = nil
            candidate.authenticatedLocally = true
            candidate.stage = candidate.consent == nil ? .consent : .name
        }
        if saved { UserDefaults.standard.set(true, forKey: "walkie.localDemo") }
    }

    func requestCode() async {
        guard !isBusy, isStorageReady else { return }
        guard validEmail else { errorMessage = OnboardingAuthError.invalidEmail.localizedDescription; return }
        let moment = now()
        if let challenge = draft.challenge, challenge.email == email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), moment < challenge.retryAfter {
            errorMessage = "Запросить код повторно можно через \(Int(ceil(challenge.retryAfter.timeIntervalSince(moment)))) с"
            return
        }
        let recent = draft.codeRequestTimes.filter { moment.timeIntervalSince($0) < 900 }
        guard recent.count < 3 else { errorMessage = "Слишком много запросов. Повтори через \(max(1, Int(ceil((900 - moment.timeIntervalSince(recent[0])) / 60)))) мин"; return }
        isBusy = true
        defer { isBusy = false }
        do {
            let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var beforeRequest = draft
            if beforeRequest.pendingCodeEmail != normalized || beforeRequest.pendingCodeRequestID == nil {
                beforeRequest.pendingCodeRequestID = UUID()
                beforeRequest.pendingCodeEmail = normalized
                try await store.save(beforeRequest)
                draft = beforeRequest
            }
            let challenge = try await auth.requestCode(email: normalized, now: moment, requestID: beforeRequest.pendingCodeRequestID!)
            var candidate = draft
            candidate.email = normalized
            candidate.challenge = challenge
            candidate.codeRequestTimes = recent + [moment]
            candidate.pendingCodeRequestID = nil
            candidate.pendingCodeEmail = nil
            candidate.stage = .code
            candidate.events.append(event("code_requested"))
            try await store.save(candidate)
            draft = candidate
            email = normalized
            code = ""
            errorMessage = nil
            shownAt = moment
        } catch { errorMessage = userFacingError(error) }
    }

    func verifyCode() async {
        guard !isBusy, isStorageReady, code.count == 6, code.allSatisfy(\.isNumber), let challenge = draft.challenge else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await auth.verify(code: code, challenge: challenge, now: now())
            var candidate = draft
            candidate.authenticatedLocally = true
            candidate.environment = isDemo ? "local_demo" : "live"
            candidate.challenge = nil
            switch result {
            case .registration(let suggestion):
                candidate.stage = .consent
                if let suggestion { candidate.name = suggestion; name = suggestion }
            case .signedIn(let remote): applyRemote(remote, to: &candidate)
            }
            candidate.events.append(event("auth_success"))
            try await store.save(candidate)
            draft = candidate
            name = candidate.name
            UserDefaults.standard.set(isDemo, forKey: "walkie.localDemo")
            await recordShown(candidate)
            code = ""
            shownAt = now()
            errorMessage = nil
        } catch {
            if case OnboardingAuthError.invalidCode(let remaining) = error {
                var candidate = draft
                candidate.challenge?.attemptsRemaining = remaining
                do { try await store.save(candidate); draft = candidate }
                catch { errorMessage = userFacingError(error); return }
            }
            errorMessage = userFacingError(error)
        }
    }

    func signInApple(identityToken: String, authorizationCode: String?, fullName: String?) async {
        guard !isBusy, isStorageReady else { return }
        if isDemo { await prepareLiveSignIn() }
        isBusy = true
        defer { isBusy = false }
        await recordTelemetry("login_method_selected", screen: "S-02", payload: ["method": "apple"])
        do {
            let result = try await auth.signInWithApple(identityToken: identityToken, authorizationCode: authorizationCode, fullName: fullName)
            var candidate = draft
            candidate.authenticatedLocally = true
            candidate.environment = "live"
            switch result {
            case .registration(let suggestion):
                candidate.stage = .consent
                candidate.name = suggestion ?? ""
            case .signedIn(let remote): applyRemote(remote, to: &candidate)
            }
            try await store.save(candidate)
            draft = candidate
            name = candidate.name
            UserDefaults.standard.set(false, forKey: "walkie.localDemo")
            await recordShown(candidate)
            errorMessage = nil
        } catch { errorMessage = userFacingError(error) }
    }

    func acceptConsent() async {
        if !isDemo {
            guard !isBusy else { return }
            isBusy = true
            do {
                let remote = try await auth.acceptConsent()
                var candidate = draft
                if let remote { applyRemote(remote, to: &candidate) }
                candidate.consent = OnboardingConsent(version: "1.0", acceptedAt: now(), environment: "live")
                candidate.stage = .name
                candidate.environment = "live"
                try await store.save(candidate)
                draft = candidate
                name = candidate.name
                errorMessage = nil
            } catch { errorMessage = userFacingError(error) }
            isBusy = false
            return
        }
        await change { candidate in
            candidate.consent = OnboardingConsent(version: "1.0", acceptedAt: now())
            candidate.stage = .name
            candidate.events.append(event("consent_accepted", values: ["1.0", "local_demo"]))
        }
    }

    func declineConsent() async {
        do { try await auth.declineConsent() }
        catch { errorMessage = userFacingError(error); return }
        await change { candidate in
            let seen = candidate.introductionSeen
            candidate = OnboardingDraft()
            candidate.introductionSeen = seen
            candidate.stage = .declined
        }
    }

    func returnAfterDecline() async {
        await change { candidate in candidate.authenticatedLocally = isDemo; candidate.stage = isDemo ? .consent : .login }
    }

    func saveName() async {
        guard validName else { return }
        await change { candidate in
            candidate.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            candidate.pendingName = !isDemo
            candidate.stage = .rationale
        }
    }

    func startQuestions() async { await change { $0.stage = .questionnaire } }

    func select(_ option: OnboardingOption) async {
        guard question.options.contains(option) else { return }
        let current = question
        await change { candidate in
            var ids = candidate.answers[current.id]?.optionIDs ?? []
            if current.isMultiple {
                if let index = ids.firstIndex(of: option.id) { ids.remove(at: index) }
                else if option.exclusive { ids = [option.id] }
                else {
                    ids.removeAll { id in current.options.contains { $0.id == id && $0.exclusive } }
                    if ids.count < current.maximum { ids.append(option.id) }
                }
            } else { ids = [option.id] }
            candidate.answers[current.id] = OnboardingAnswer(optionIDs: ids, skipped: false, answeredAt: now())
            candidate.events.append(event("answer", question: current.id, values: ids))
            if !current.isMultiple { advanceQuestion(&candidate) }
        }
    }

    func nextQuestion() async {
        guard canContinueQuestion else { return }
        await change { advanceQuestion(&$0) }
    }

    func skipQuestion() async {
        guard !question.isRequired else { return }
        let id = question.id
        await change { candidate in
            candidate.answers[id] = OnboardingAnswer(optionIDs: [], skipped: true, answeredAt: now())
            candidate.events.append(event("skip", question: id, values: ["no_data"]))
            advanceQuestion(&candidate)
        }
    }

    func editQuestion(_ index: Int) async {
        guard draft.questions.indices.contains(index) else { return }
        isEditingSummary = true
        showQuestionList = false
        await change { candidate in
            candidate.questionIndex = index
            candidate.stage = .questionnaire
            candidate.events.append(event("summary_edit", question: draft.questions[index].id))
        }
    }

    func startSummaryEdit() async {
        await recordTelemetry("profile_summary_edit_started", screen: "S-10", payload: ["phrase_id": "all"])
        showQuestionList = true
    }

    func finish() async -> Bool {
        guard draft.canComplete else { errorMessage = "Добавь имя и от 3 до 5 интересов."; return false }
        if !isDemo {
            guard !isBusy else { return false }
            isBusy = true
            do {
                try await syncPending()
                try await auth.confirmProfile(requestID: draft.confirmationRequestID)
                isBusy = false
            } catch { isBusy = false; errorMessage = "Ответы сохранены на iPhone. Для подтверждения нужна связь: \(userFacingError(error))"; return false }
        }
        return await change { candidate in
            candidate.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            candidate.stage = .complete
            candidate.completedAt = now()
            candidate.events.append(event("profile_confirmed"))
        }
    }

    func back() async {
        await change { candidate in
            candidate.events.append(event("back", question: stage == .questionnaire ? question.id : nil))
            switch candidate.stage {
            case .login: candidate.stage = .introduction
            case .email: candidate.stage = .login
            case .code: candidate.stage = .email
            case .consent, .declined: candidate.stage = .login
            case .name: candidate.stage = .consent
            case .rationale: candidate.stage = .name
            case .questionnaire:
                if isEditingSummary { candidate.stage = .summary; isEditingSummary = false }
                else if candidate.questionIndex > 0 { candidate.questionIndex -= 1 }
                else { candidate.stage = .rationale }
            case .summary: candidate.stage = .questionnaire; candidate.questionIndex = 12
            case .complete: candidate.stage = .summary
            case .introduction: break
            }
        }
    }

    func checkpointExit() async {
        if stage == .questionnaire {
            await recordTelemetry("question_left", screen: "S-09", payload: ["questionnaire": "profile", "question_id": question.id, "action": "exit", "time_on_screen_ms": String(max(0, Int(now().timeIntervalSince(shownAt) * 1000)))])
        }
        await change { candidate in
            candidate.events.append(event("exit", question: stage == .questionnaire ? question.id : nil))
        }
    }

    var interestTitles: [String] {
        draft.questions[1].options.filter { draft.interests.contains($0.id) }.map(\.title)
    }

    var summaryPhrases: [String] {
        if let summary = draft.remoteSummary, !summary.isEmpty { return summary }
        let interests = draft.questions[1].options.filter { draft.interests.contains($0.id) }.map(\.title)
        let interestText = "Твои интересы: " + interests.joined(separator: ", ").lowercased()
        let spontaneous = draft.answers["P8"]?.optionIDs.first
        let structure = spontaneous == "option_1" ? "Готов сворачивать с маршрута ради интересного" : (spontaneous == "option_2" ? "Можешь свернуть, если есть время" : spontaneous == "option_3" ? "Предпочитаешь держаться маршрута" : "Про спонтанность пока ничего не знаем")
        let distance = selectedTitle("P10")
        let pace = selectedTitle("P9")
        let comfort = [distance, pace].compactMap { $0 }.joined(separator: ", ").lowercased()
        return [interestText, structure, comfort.isEmpty ? "Темп и дистанцию пока оставим без предпочтений" : "Комфортно: \(comfort)"]
    }

    func selectedTitle(_ id: String) -> String? {
        guard let selected = draft.answers[id]?.optionIDs.first else { return nil }
        return draft.questions.first { $0.id == id }?.options.first { $0.id == selected }?.title
    }

    private func advanceQuestion(_ candidate: inout OnboardingDraft) {
        if isEditingSummary { candidate.stage = .summary; isEditingSummary = false }
        else if candidate.questionIndex == 12 { candidate.stage = .summary }
        else { candidate.questionIndex += 1 }
    }

    private func event(_ type: String, question: String? = nil, values: [String] = []) -> OnboardingEvent {
        .init(id: UUID(), type: type, screen: screenID, date: now(), questionID: question, values: values,
              timeOnScreenMS: max(0, Int(now().timeIntervalSince(shownAt) * 1_000)), environment: draft.environment)
    }

    @discardableResult
    private func change(_ body: (inout OnboardingDraft) -> Void) async -> Bool {
        guard !isBusy, isStorageReady else { return false }
        isBusy = true
        defer { isBusy = false }
        var candidate = draft
        let previousStage = draft.stage
        let previousQuestion = draft.questionIndex
        let previousIntroduction = draft.introductionIndex
        body(&candidate)
        if candidate.answers != draft.answers {
            candidate.confirmationRequestID = UUID()
            candidate.completedAt = nil
            candidate.remoteSummary = nil
        }
        if candidate.stage != previousStage || candidate.questionIndex != previousQuestion {
            candidate.events.append(OnboardingEvent(id: UUID(), type: "shown", screen: screenID(for: candidate.stage), date: now(), questionID: candidate.stage == .questionnaire ? candidate.questions[candidate.questionIndex].id : nil, environment: candidate.environment))
        }
        if !isDemo {
            for (id, answer) in candidate.answers where draft.answers[id] != answer {
                // Retain even an incomplete multi-selection on resume; only valid answers sync.
                if !candidate.pendingAnswerIDs.contains(id) { candidate.pendingAnswerIDs.append(id) }
            }
        }
        do {
            try await store.save(candidate)
            if previousStage == .questionnaire && (candidate.stage != previousStage || candidate.questionIndex != previousQuestion) {
                let id = draft.questions[previousQuestion].id
                let action = candidate.events.last(where: { ["back", "skip", "answer"].contains($0.type) })?.type
                await recordTelemetry("question_left", screen: "S-09", payload: ["questionnaire": "profile", "question_id": id, "action": action == "back" ? "back" : action == "skip" ? "skipped" : "answered", "time_on_screen_ms": String(max(0, Int(now().timeIntervalSince(shownAt) * 1000)))])
            }
            draft = candidate
            if candidate.stage != previousStage || candidate.questionIndex != previousQuestion || candidate.introductionIndex != previousIntroduction { await recordShown(candidate) }
            if candidate.stage != previousStage || candidate.questionIndex != previousQuestion { shownAt = now() }
            errorMessage = nil
            if !isDemo && candidate.authenticatedLocally && candidate.consent != nil {
                do {
                    try await syncPending()
                    if candidate.stage == .summary {
                        var updated = draft
                        updated.remoteSummary = try await auth.summary()
                        try await store.save(updated)
                        draft = updated
                    }
                } catch { errorMessage = "Ответы сохранены на iPhone и будут отправлены при повторе: \(userFacingError(error))" }
            }
            return true
        } catch { errorMessage = "Не удалось сохранить: \(userFacingError(error))"; return false }
    }

    private func syncPending() async throws {
        if draft.pendingName {
            try await auth.saveName(draft.name)
            var next = draft; next.pendingName = false
            try await store.save(next); draft = next
        }
        for id in draft.pendingAnswerIDs {
            guard let answer = draft.answers[id] else { continue }
            let question = draft.questions.first { $0.id == id }!
            guard answer.skipped || answer.optionIDs.count >= max(1, question.minimum) else { continue }
            try await auth.saveAnswer(question: id, answer: answer)
            var next = draft; next.pendingAnswerIDs.removeAll { $0 == id }; next.remoteSummary = nil
            try await store.save(next); draft = next
        }
    }

    private func applyRemote(_ remote: OnboardingRemoteProfile, to loaded: inout OnboardingDraft) {
        if loaded.userID != remote.userID && loaded.environment == "live" {
            // A draft belongs to its authenticated owner. Never carry pending answers,
            // consent, summary or version idempotency keys to another account.
            let seen = loaded.introductionSeen
            loaded = OnboardingDraft()
            loaded.introductionSeen = seen
        }
        let localAnswers = loaded.answers
        // A previous generated summary can describe answers from before an edit.
        if loaded.answers != remote.answers { loaded.remoteSummary = nil }
        loaded.userID = remote.userID
        if !loaded.pendingName { loaded.name = remote.name }
        loaded.backendContextBranch = remote.branch
        loaded.remoteQuestions = remote.questions
        loaded.questionnaireVersion = remote.questionnaireVersion
        loaded.answers = remote.answers
        for id in loaded.pendingAnswerIDs { loaded.answers[id] = localAnswers[id] }
        loaded.authenticatedLocally = true
        loaded.environment = "live"
        // Existing account already accepted consent at registration; no second consent prompt.
        if loaded.consent == nil { loaded.consent = .init(version: "server_record", acceptedAt: now(), environment: "live") }
        if remote.name.isEmpty { loaded.stage = .name }
        else if remote.confirmed { loaded.stage = .summary }
        else if let id = remote.nextQuestionID, let index = remote.questions.firstIndex(where: { $0.id == id }) {
            loaded.questionIndex = index
            loaded.stage = index == 0 ? .rationale : .questionnaire
        } else { loaded.stage = .summary }
    }

    private func screenID(for stage: OnboardingStage) -> String {
        switch stage {
        case .introduction: return "S-01"
        case .login: return "S-02"
        case .email: return "S-03"
        case .code: return "S-04"
        case .consent, .declined: return "S-05"
        case .name: return "S-06"
        case .rationale: return "S-08"
        case .questionnaire: return "S-09"
        case .summary, .complete: return "S-10"
        }
    }

    private func recordShown(_ snapshot: OnboardingDraft) async {
        switch snapshot.stage {
        case .introduction:
            await recordTelemetry("onboarding_shown", screen: "S-01", payload: ["slide": String(snapshot.introductionIndex + 1), "skipped": "false"])
        case .login: await recordTelemetry("login_screen_shown", screen: "S-02")
        case .questionnaire:
            await recordTelemetry("question_shown", screen: "S-09", payload: ["questionnaire": "profile", "question_id": snapshot.questions[snapshot.questionIndex].id])
        case .summary: await recordTelemetry("profile_summary_shown", screen: "S-10")
        default: break
        }
    }

    private func recordTelemetry(_ type: String, screen: String, payload: [String: String] = [:]) async {
        guard telemetryEnabled, !isDemo, ProcessInfo.processInfo.environment["WALKIE_OFFLINE_DEMO"] != "1",
              ProcessInfo.processInfo.environment["WALKIE_TEST_STORAGE_ID"] == nil else { return }
        // Whitelist v0.2 client events only; the server records consent and answer values.
        try? await telemetry.record(type, screen: screen, payload: payload)
    }
}
