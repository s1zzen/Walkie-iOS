import Foundation

enum OnboardingStorageError: LocalizedError {
    case corrupt, invalid, unsupported
    var errorDescription: String? {
        switch self {
        case .corrupt: return "Файл анкеты повреждён. Исходные данные сохранены, повторная запись остановлена."
        case .invalid: return "Не удалось проверить ответы анкеты."
        case .unsupported: return "Эта версия анкеты пока не поддерживается."
        }
    }
}

actor OnboardingStore {
    let url: URL
    private var hasLoaded = false

    init(url: URL = OnboardingStore.defaultURL) { self.url = url }
    static var defaultURL: URL {
        var support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Walkie", isDirectory: true)
        #if DEBUG
        if let rawID = ProcessInfo.processInfo.environment["WALKIE_TEST_STORAGE_ID"], let id = UUID(uuidString: rawID) {
            support = support.appendingPathComponent("UITests/\(id.uuidString)", isDirectory: true)
        }
        #endif
        return support.appendingPathComponent("Profile/onboarding.json")
    }

    func load() throws -> OnboardingDraft {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch {
            let error = error as NSError
            guard error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileReadNoSuchFile.rawValue else { throw error }
            hasLoaded = true
            return OnboardingDraft()
        }
        let draft: OnboardingDraft
        do { draft = try JSONDecoder().decode(OnboardingDraft.self, from: data) }
        catch { hasLoaded = false; throw OnboardingStorageError.corrupt }
        try validate(draft)
        hasLoaded = true
        return draft
    }

    func save(_ draft: OnboardingDraft) throws {
        // Every instance must successfully read before it may replace an existing file.
        if !hasLoaded { _ = try load() }
        try validate(draft)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(draft)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private func validate(_ draft: OnboardingDraft) throws {
        guard draft.schemaVersion == 1 else { throw OnboardingStorageError.unsupported }
        guard (0..<13).contains(draft.questionIndex), (0..<3).contains(draft.introductionIndex) else { throw OnboardingStorageError.invalid }
        guard draft.questions.map(\.id) == OnboardingQuestion.all.map(\.id),
              draft.questions.allSatisfy({ question in
                  !question.options.isEmpty && Set(question.options.map(\.id)).count == question.options.count
                    && question.minimum >= 0 && question.maximum >= max(1, question.minimum)
                    && question.maximum <= question.options.count
              }) else { throw OnboardingStorageError.invalid }
        for (id, answer) in draft.answers {
            guard let question = draft.questions.first(where: { $0.id == id }),
                  Set(answer.optionIDs).count == answer.optionIDs.count,
                  answer.optionIDs.allSatisfy({ id in question.options.contains(where: { $0.id == id }) }),
                  answer.optionIDs.count <= question.maximum,
                  !(question.isRequired && answer.skipped),
                  !answer.skipped || answer.optionIDs.isEmpty,
                  !question.options.contains(where: { $0.exclusive && answer.optionIDs.contains($0.id) }) || answer.optionIDs.count == 1 else {
                throw OnboardingStorageError.invalid
            }
        }
        if draft.stage == .complete && (!draft.canComplete || draft.completedAt == nil) { throw OnboardingStorageError.invalid }
    }
}
