import Foundation

enum OnboardingStage: String, Codable, CaseIterable {
    case introduction, login, email, code, consent, declined, name, rationale, questionnaire, summary, complete
}

struct OnboardingOption: Identifiable, Codable, Equatable {
    let id: String
    let title: String
    var icon: String = "sparkles"
    var exclusive = false
}

/// Frozen copy from questionnaires.md v2.0. Stable IDs are stored instead of UI indices.
struct OnboardingQuestion: Identifiable, Codable, Equatable {
    let id: String
    let tag: String
    let title: String
    let options: [OnboardingOption]
    var minimum = 0
    var maximum = 1
    var isMultiple = false
    var isRequired: Bool { minimum > 0 }
    var step: Int { (Int(id.dropFirst()) ?? 1) + 2 }

    static let all: [Self] = [
        .init(id: "P1", tag: "ОБРАЗ ПРОГУЛКИ", title: "Идеальная прогулка на полтора часа — это скорее…", options: [
            .init(id: "water_views", title: "Набережная и виды", icon: "waves"),
            .init(id: "old_center", title: "Улицы и дворы старого центра", icon: "building"),
            .init(id: "park_green", title: "Парк и зелень", icon: "tree"),
            .init(id: "city_cafes", title: "Город, кофе и заведения", icon: "coffee")]),
        .init(id: "P2", tag: "ИНТЕРЕСЫ", title: "Что тебе интересно в городе?", options: [
            .init(id: "architecture_history", title: "Архитектура и история", icon: "building"),
            .init(id: "museums_exhibitions", title: "Музеи и выставки", icon: "palette"),
            .init(id: "contemporary_art", title: "Современное искусство и стрит-арт", icon: "sparkles"),
            .init(id: "parks_nature", title: "Парки и природа", icon: "tree"),
            .init(id: "water", title: "Вода: набережные, пруды, каналы", icon: "waves"),
            .init(id: "viewpoints", title: "Смотровые площадки и виды", icon: "eye"),
            .init(id: "coffee_desserts", title: "Кофе и десерты", icon: "coffee"),
            .init(id: "food_markets", title: "Еда и рынки", icon: "food"),
            .init(id: "local_shops", title: "Локальные магазины, книжные, барахолки", icon: "bag"),
            .init(id: "quiet_courtyards", title: "Тихие дворы и переулки", icon: "moon"),
            .init(id: "photogenic_places", title: "Фотогеничные места", icon: "camera"),
            .init(id: "outdoor_sports", title: "Спорт и активность на улице", icon: "activity")], minimum: 3, maximum: 5, isMultiple: true),
        .init(id: "P3", tag: "НОВЫЕ МЕСТА", title: "Рядом открылось место, о котором ты ничего не знаешь. Ты скорее…", options: options("Зайду сразу, интересно", "Сначала почитаю отзывы", "Схожу, если кто-то посоветует", "Вряд ли пойду, мне хватает проверенных мест")),
        .init(id: "P4", tag: "НОВЫЕ МЕСТА", title: "Маршрут может привести в место, о котором почти никто не пишет. Это…", options: options("То, ради чего я и иду", "Интересно, если таких мест одно-два", "Лучше проверенное", "Только известные места")),
        .init(id: "P5", tag: "ЛЮДИ ВОКРУГ", title: "Где тебе комфортнее гулять?", options: options("Где людно и живо", "Скорее людно, но без толпы", "Скорее тихо", "Чем меньше людей, тем лучше")),
        .init(id: "P6", tag: "КОМПАНИЯ", title: "Ты чаще гуляешь…", options: options("Почти всегда с кем-то", "Чаще с кем-то", "Чаще один", "Почти всегда один")),
        .init(id: "P7", tag: "ПЛАНИРОВАНИЕ", title: "Перед прогулкой ты обычно…", options: options("Заранее продумываю, куда и когда", "Примерно понимаю направление", "Иду куда глаза глядят")),
        .init(id: "P8", tag: "СПОНТАННОСТЬ", title: "Увидел по пути что-то интересное не по маршруту…", options: options("Сверну не раздумывая", "Сверну, если есть время", "Останусь на маршруте")),
        .init(id: "P9", tag: "ТЕМП", title: "Твой обычный темп прогулки", options: options("Быстрый, люблю пройти много", "Средний", "Неспешный, часто останавливаюсь")),
        .init(id: "P10", tag: "ДИСТАНЦИЯ", title: "Сколько комфортно пройти за прогулку?", options: options("До 3 км", "3–5 км", "5–8 км", "Больше 8 км")),
        .init(id: "P11", tag: "ОСТАНОВКИ", title: "Остановки в кафе во время прогулки — это…", options: options("Обязательная часть прогулки", "Хорошо, если по пути", "Редко", "Я гуляю без остановок")),
        .init(id: "P12", tag: "ВРЕМЯ ПРОГУЛОК", title: "Когда чаще всего гуляешь? Выбери всё, что подходит", options: options("Будни днём", "Будни вечером", "Выходные днём", "Выходные вечером", "Поздно вечером"), maximum: 5, isMultiple: true),
        .init(id: "P13", tag: "ОГРАНИЧЕНИЯ", title: "Есть то, чего лучше избегать?", options: [
            .init(id: "crowds", title: "Шумные и людные места"), .init(id: "queues", title: "Очереди"),
            .init(id: "stairs", title: "Много лестниц и подъёмов"), .init(id: "long_transitions", title: "Долгие переходы между точками"),
            .init(id: "tourist", title: "Туристические точки"), .init(id: "alcohol", title: "Бары и алкоголь"),
            .init(id: "none", title: "Ничего из этого", exclusive: true)], maximum: 6, isMultiple: true)
    ]

    private static func options(_ titles: String...) -> [OnboardingOption] {
        titles.enumerated().map { OnboardingOption(id: "option_\($0.offset + 1)", title: $0.element) }
    }
}

struct OnboardingAnswer: Codable, Equatable {
    var optionIDs: [String]
    var skipped: Bool
    var answeredAt: Date
}

struct OnboardingConsent: Codable, Equatable {
    let version: String
    let acceptedAt: Date
    /// Demonstrator approval is not a signed production consent.
    var environment = "local_demo"
}

struct OnboardingEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let type: String
    let screen: String
    let date: Date
    var questionID: String?
    var values: [String] = []
    var timeOnScreenMS: Int = 0
    var environment = "local_demo"
}

struct OnboardingCodeChallenge: Codable, Equatable {
    let id: UUID
    let email: String
    let createdAt: Date
    let expiresAt: Date
    let retryAfter: Date
    var attemptsRemaining = 5
}

struct OnboardingDraft: Codable, Equatable {
    var schemaVersion = 1
    var questionnaireVersion = "2.0-2026-10-10"
    var remoteQuestions: [OnboardingQuestion]?
    var remoteSummary: [String]?
    var userID = UUID().uuidString
    var stage = OnboardingStage.introduction
    var introductionIndex = 0
    var introductionSeen = false
    var email = ""
    var name = ""
    var authenticatedLocally = false
    var consent: OnboardingConsent?
    var questionIndex = 0
    var answers: [String: OnboardingAnswer] = [:]
    var challenge: OnboardingCodeChallenge?
    var codeRequestTimes: [Date] = []
    var events: [OnboardingEvent] = []
    var completedAt: Date?
    /// Production C0/C1/C2 belongs to the backend. No local random assignment.
    var backendContextBranch: String?
    var acquisitionChannel = "local_demo"
    var environment = "local_demo"
    var confirmationRequestID = UUID()
    var pendingAnswerIDs: [String] = []
    var pendingName = false
    var pendingCodeRequestID: UUID?
    var pendingCodeEmail: String?

    var questions: [OnboardingQuestion] { remoteQuestions ?? OnboardingQuestion.all }

    var interests: [String] { answers["P2"]?.optionIDs ?? [] }
    var canComplete: Bool {
        consent != nil && authenticatedLocally && OnboardingValidation.isValidName(name)
            && interests.count >= 3 && interests.count <= 5
            && interests.allSatisfy { id in questions.first(where: { $0.id == "P2" })?.options.contains { $0.id == id } == true }
            && questions.allSatisfy { question in
                guard let answer = answers[question.id] else { return false }
                return answer.skipped ? !question.isRequired : answer.optionIDs.count >= max(1, question.minimum)
            }
    }
}

enum OnboardingValidation {
    static func isValidName(_ name: String) -> Bool {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value.count <= 30
    }
    static func isValidEmail(_ email: String) -> Bool {
        let value = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 254, !value.contains(" "), !value.contains("\n") else { return false }
        let pieces = value.split(separator: "@", omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[0].isEmpty, pieces[0].count <= 64 else { return false }
        let domain = pieces[1].split(separator: ".", omittingEmptySubsequences: false)
        return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
            && domain.last!.count >= 2 && !value.contains("..")
    }
}
