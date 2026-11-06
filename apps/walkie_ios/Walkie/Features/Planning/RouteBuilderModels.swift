import Foundation
import WalkieCore

enum RouteContextBranch: String, Codable, Sendable { case c0 = "C0", c1 = "C1", c2 = "C2" }

/// K1 is a moderator only. It is kept separate from interests and ranking inputs.
struct RouteContext: Codable, Equatable, Sendable {
    var answers: [String: [String]] = [:]
    var skipped: Set<String> = []
    var phrase = ""
    var phraseSkipped = false
    var phraseFromChip = false
}

struct RouteContextQuestion: Codable, Equatable, Identifiable, Sendable {
    struct Option: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        var isNew: Bool? = nil
        var tag: String? = nil
        enum CodingKeys: String, CodingKey { case id, title, tag; case isNew = "is_new" }
    }
    let id: String
    let type: String
    let title: String
    let required: Bool
    let options: [Option]
    var minChoices: Int? = nil
    var maxChoices: Int? = nil
    enum CodingKeys: String, CodingKey { case id, type, title, required, options; case minChoices = "min_choices", maxChoices = "max_choices" }
}

struct RouteContextDefinition: Sendable {
    var branch: RouteContextBranch
    var questions: [RouteContextQuestion]
    var storedAnswers: [String: [String]] = [:]
    var skippedQuestions: Set<String> = []
    var isComplete = false
    var nextQuestionID: String? = nil
    var phraseSubmitted = false

    /// Frozen handoff copy for explicitly marked offline demonstrations only.
    static let demo = RouteContextDefinition(branch: .c0, questions: [
        RouteContextQuestion(id: "K1", type: "single", title: "С кем гуляешь сегодня?", required: true,
                             options: [.init(id: "alone", title: "Один"), .init(id: "pair", title: "Вдвоём"), .init(id: "group", title: "Компанией от трёх")]),
        RouteContextQuestion(id: "K2", type: "single", title: "Что за прогулка сегодня?", required: false,
                             options: ["Развеяться и подумать", "Открыть новое", "Свидание", "Показать город гостю", "Пройтись активно"].enumerated().map { .init(id: String($0.offset), title: $0.element) }),
        RouteContextQuestion(id: "K3", type: "single", title: "Сколько сил сегодня?", required: false,
                             options: ["Немного, хочется спокойно", "Как обычно", "Хочу нагрузку"].enumerated().map { .init(id: String($0.offset), title: $0.element) }),
        RouteContextQuestion(id: "K4", type: "multi", title: "Чего хочется сегодня? Выбери 1–2", required: false,
                             options: ["architecture_history", "parks_nature", "coffee_desserts", "water", "viewpoints", "contemporary_art"].enumerated().map {
                                 .init(id: $0.element, title: WalkInterest(rawValue: $0.element)?.title ?? $0.element, isNew: $0.offset >= 4)
                             }, minChoices: 1, maxChoices: 2),
        RouteContextQuestion(id: "K5", type: "single", title: "Останавливаемся на кофе или перекус?", required: false,
                             options: ["Да, обязательно", "Если по пути", "Нет"].enumerated().map { .init(id: String($0.offset), title: $0.element) })
    ])
}

enum RouteBuilderStep: Int, Codable, CaseIterable { case origin, finish, budget, company, contextIntro, purpose, energy, interests, coffee, phrase, generation }

struct RouteBuilderDraft: Codable {
    var request: RouteRequest
    var step: RouteBuilderStep
    var branch: RouteContextBranch
    var isComplete = false
}

enum RouteBuilderLocation {
    static func demoOrigin(for area: String) -> Coordinate {
        area == "Замоскворечье" ? Coordinate(latitude: 55.74215, longitude: 37.61882) : Coordinate(latitude: 55.76519, longitude: 37.63809)
    }
}

struct RouteCorrection: Codable, Sendable {
    var id: String
    var understood: Bool
    var constraints: [String]
}

struct RouteGenerationProgress: Sendable, Equatable {
    var stage: String?
    var candidatesFound: Int?
    static let stages = ["collecting_places", "checking_hours", "ordering", "building_line"]
}
