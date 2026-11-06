import Foundation

/// Live API v0.2.0, 18 October. Secrets only in Keychain, profile answers in local draft.
actor OnboardingLiveAuthService: OnboardingAuthService {
    nonisolated let isLocalDemo = false
    nonisolated let deliveryExplanation = "Пришлём код из 6 цифр. Пароль не нужен."
    private let client: BackendClient
    init(client: BackendClient = .shared) { self.client = client }

    func requestCode(email: String, now: Date, requestID: UUID) async throws -> OnboardingCodeChallenge {
        let body = try json(["email": email, "device_id": try deviceID(), "request_id": requestID.uuidString])
        let data = try await client.request(path: "/v1/auth/email/codes", method: "POST", body: body, authenticated: false)
        let response = try JSONDecoder().decode(CodeSent.self, from: data)
        return .init(id: requestID, email: email, createdAt: now,
                     expiresAt: try date(response.expires_at), retryAfter: try date(response.resend_available_at))
    }

    func verify(code: String, challenge: OnboardingCodeChallenge, now: Date) async throws -> OnboardingAuthOutcome {
        guard now < challenge.expiresAt, challenge.attemptsRemaining > 0 else { throw OnboardingAuthError.expired }
        do {
            let data = try await client.request(path: "/v1/auth/email/verify", method: "POST", body: json(["email": challenge.email, "code": code, "device_id": try deviceID()]), authenticated: false)
            let result = try JSONDecoder().decode(AuthResult.self, from: data)
            return try await consume(result)
        } catch let problem as BackendProblem {
            if problem.code == "code_invalid" { throw OnboardingAuthError.invalidCode(remaining: problem.attempts_left ?? max(0, challenge.attemptsRemaining - 1)) }
            if problem.code == "code_expired" { throw OnboardingAuthError.expired }
            throw problem
        }
    }

    func signInWithApple(identityToken: String, authorizationCode: String?, fullName: String?) async throws -> OnboardingAuthOutcome {
        var body: [String: Any] = ["identity_token": identityToken, "device_id": try deviceID()]
        if let authorizationCode { body["authorization_code"] = authorizationCode }
        if let fullName, !fullName.isEmpty { body["full_name"] = fullName }
        let data = try await client.request(path: "/v1/auth/apple", method: "POST", body: json(body), authenticated: false)
        return try await consume(JSONDecoder().decode(AuthResult.self, from: data))
    }

    private func consume(_ result: AuthResult) async throws -> OnboardingAuthOutcome {
        if result.status == "signed_in", let session = result.session {
            try await client.saveSession(session)
            try BackendKeychain.set(nil, for: "registration_token")
            return .signedIn(try await requiredProfile())
        }
        guard result.status == "registration_required", let token = result.registration_token else { throw URLError(.cannotParseResponse) }
        try BackendKeychain.set(Data(token.utf8), for: "registration_token")
        return .registration(suggestedName: result.suggested_name)
    }

    func acceptConsent() async throws -> OnboardingRemoteProfile? {
        guard let data = BackendKeychain.data(for: "registration_token"), let token = String(data: data, encoding: .utf8) else {
            if await client.currentSession() != nil { return try await requiredProfile() }
            throw URLError(.userAuthenticationRequired)
        }
        let response = try await client.request(path: "/v1/auth/registrations", method: "POST", body: json([
            "registration_token": token, "consent_version": "1.0", "acquisition": ["source": "unknown"]
        ]), authenticated: false)
        try await client.saveSession(JSONDecoder().decode(BackendSession.self, from: response))
        try BackendKeychain.set(nil, for: "registration_token")
        return try await requiredProfile()
    }

    func declineConsent() async throws {
        if let data = BackendKeychain.data(for: "registration_token"), let token = String(data: data, encoding: .utf8) {
            _ = try await client.request(path: "/v1/auth/registrations/decline", method: "POST", body: json(["registration_token": token]), authenticated: false)
        }
        try BackendKeychain.set(nil, for: "registration_token")
    }

    func loadProfile() async throws -> OnboardingRemoteProfile? {
        guard await client.currentSession() != nil else { return nil }
        return try await requiredProfile()
    }

    private func requiredProfile() async throws -> OnboardingRemoteProfile {
        let meData = try await client.request(path: "/v1/me")
        let me = try JSONDecoder().decode(Me.self, from: meData)
        let definitionData = try await client.request(path: "/v1/questionnaires/profile")
        let definition = try JSONDecoder().decode(Definition.self, from: definitionData)
        let stateData = try await client.request(path: "/v1/profile")
        let state = try JSONDecoder().decode(Profile.self, from: stateData)
        let mapped = definition.questions.map { question in
            let fallback = OnboardingQuestion.all.first { $0.id == question.id }
            return OnboardingQuestion(id: question.id, tag: question.tag ?? fallback?.tag ?? "ПРОФИЛЬ", title: question.title,
                options: question.options.map { option in
                    .init(id: option.id, title: option.title, icon: fallback?.options.first { $0.id == option.id }?.icon ?? "sparkles", exclusive: option.exclusive ?? false)
                }, minimum: question.required ? (question.min_choices ?? 1) : 0,
                maximum: question.max_choices ?? (question.type == "single" ? 1 : question.options.count),
                isMultiple: question.type != "single")
        }
        guard mapped.map(\.id) == OnboardingQuestion.all.map(\.id) else { throw URLError(.cannotParseResponse) }
        var answers: [String: OnboardingAnswer] = [:]
        for answer in state.answers {
            answers[answer.question_id] = .init(optionIDs: answer.option_ids ?? [], skipped: answer.kind == "skip", answeredAt: (try? date(answer.saved_at)) ?? Date())
        }
        return .init(userID: me.id, name: me.display_name ?? "", branch: me.context_branch, confirmed: me.onboarding.profile_confirmed,
                     questions: mapped, questionnaireVersion: definition.version, answers: answers, nextQuestionID: state.next_question_id)
    }

    func saveName(_ name: String) async throws {
        _ = try await client.request(path: "/v1/me", method: "PATCH", body: json(["display_name": name]))
    }
    func saveAnswer(question: String, answer: OnboardingAnswer) async throws {
        let body: [String: Any] = answer.skipped ? ["kind": "skip"] : ["kind": "choice", "option_ids": answer.optionIDs]
        _ = try await client.request(path: "/v1/profile/answers/\(question)", method: "PUT", body: json(body))
    }
    func confirmProfile(requestID: UUID) async throws {
        _ = try await client.request(path: "/v1/profile/versions", method: "POST", body: json(["request_id": requestID.uuidString]))
    }
    func summary() async throws -> [String]? {
        let data = try await client.request(path: "/v1/profile/summary")
        return try JSONDecoder().decode(Summary.self, from: data).phrases.map(\.text)
    }

    private func deviceID() throws -> String {
        if let data = BackendKeychain.data(for: "device_id"), let id = String(data: data, encoding: .utf8) { return id }
        let id = UUID().uuidString
        try BackendKeychain.set(Data(id.utf8), for: "device_id")
        return id
    }
    private func json(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        guard let date = formatter.date(from: value) else { throw URLError(.cannotParseResponse) }
        return date
    }
    private struct CodeSent: Decodable { let expires_at: String; let resend_available_at: String }
    private struct AuthResult: Decodable { let status: String; let session: BackendSession?; let registration_token: String?; let suggested_name: String? }
    private struct Me: Decodable {
        let id: String; let display_name: String?; let context_branch: String; let onboarding: State
        struct State: Decodable { let profile_confirmed: Bool }
    }
    private struct Definition: Decodable {
        let version: String; let questions: [Question]
        struct Question: Decodable {
            let id: String; let type: String; let title: String; let tag: String?; let required: Bool; let min_choices: Int?; let max_choices: Int?; let options: [Option]
        }
        struct Option: Decodable { let id: String; let title: String; let exclusive: Bool? }
    }
    private struct Profile: Decodable {
        let answers: [Answer]; let next_question_id: String?
        struct Answer: Decodable { let question_id: String; let kind: String; let option_ids: [String]?; let saved_at: String }
    }
    private struct Summary: Decodable {
        let phrases: [Phrase]
        struct Phrase: Decodable { let text: String }
    }
}
