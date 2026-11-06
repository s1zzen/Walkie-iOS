import Foundation

enum OnboardingAuthError: LocalizedError {
    case invalidEmail, unavailable, expired, invalidCode(remaining: Int), rateLimited(until: Date)
    var errorDescription: String? {
        switch self {
        case .invalidEmail: return "Похоже, в адресе опечатка. Пример: name@mail.ru"
        case .unavailable: return "Вход временно недоступен. Попробуй ещё раз."
        case .expired: return "Код аннулирован. Запроси новый код."
        case .invalidCode(let remaining): return "Неверный код. Осталось попыток: \(remaining)"
        case .rateLimited: return "Слишком много запросов. Попробуй позже."
        }
    }
}

/// Implement this contract with the confirmed backend before publishing email auth.
protocol OnboardingAuthService {
    var isLocalDemo: Bool { get }
    var deliveryExplanation: String { get }
    func requestCode(email: String, now: Date, requestID: UUID) async throws -> OnboardingCodeChallenge
    func verify(code: String, challenge: OnboardingCodeChallenge, now: Date) async throws -> OnboardingAuthOutcome
    func acceptConsent() async throws -> OnboardingRemoteProfile?
    func declineConsent() async throws
    func loadProfile() async throws -> OnboardingRemoteProfile?
    func saveName(_ name: String) async throws
    func saveAnswer(question: String, answer: OnboardingAnswer) async throws
    func confirmProfile(requestID: UUID) async throws
    func summary() async throws -> [String]?
    func signInWithApple(identityToken: String, authorizationCode: String?, fullName: String?) async throws -> OnboardingAuthOutcome
}

enum OnboardingAuthOutcome {
    case registration(suggestedName: String?)
    case signedIn(OnboardingRemoteProfile)
}

struct OnboardingRemoteProfile {
    let userID: String
    let name: String
    let branch: String
    let confirmed: Bool
    let questions: [OnboardingQuestion]
    let questionnaireVersion: String
    let answers: [String: OnboardingAnswer]
    let nextQuestionID: String?
}

extension OnboardingAuthService {
    func acceptConsent() async throws -> OnboardingRemoteProfile? { nil }
    func declineConsent() async throws {}
    func loadProfile() async throws -> OnboardingRemoteProfile? { nil }
    func saveName(_ name: String) async throws {}
    func saveAnswer(question: String, answer: OnboardingAnswer) async throws {}
    func confirmProfile(requestID: UUID) async throws {}
    func summary() async throws -> [String]? { nil }
    func signInWithApple(identityToken: String, authorizationCode: String?, fullName: String?) async throws -> OnboardingAuthOutcome { throw OnboardingAuthError.unavailable }
}

struct OnboardingLocalAuthService: OnboardingAuthService {
    let isLocalDemo = true
    let deliveryExplanation = "Локальный тест: письма не отправляются. Код для проверки — 123456."
    func requestCode(email: String, now: Date, requestID: UUID) async throws -> OnboardingCodeChallenge {
        guard OnboardingValidation.isValidEmail(email) else { throw OnboardingAuthError.invalidEmail }
        return .init(id: requestID, email: email, createdAt: now, expiresAt: now.addingTimeInterval(600), retryAfter: now.addingTimeInterval(60))
    }
    func verify(code: String, challenge: OnboardingCodeChallenge, now: Date) async throws -> OnboardingAuthOutcome {
        guard now < challenge.expiresAt, challenge.attemptsRemaining > 0 else { throw OnboardingAuthError.expired }
        guard code == "123456" else { throw OnboardingAuthError.invalidCode(remaining: max(0, challenge.attemptsRemaining - 1)) }
        return .registration(suggestedName: nil)
    }
}
