import SwiftUI
import AuthenticationServices

/// S-01…S-10; permissions S-07 are deliberately requested by the feature that needs them.
struct OnboardingFlowView: View {
    @Environment(\.productTelemetry) private var telemetry
    private let editing: Bool
    private let forceLogin: Bool
    private let store: OnboardingStore
    private let auth: any OnboardingAuthService
    private let telemetryOverride: (any ProductTelemetryRecording)?
    private let onEnvironmentSelected: (Bool) -> Void
    private let onComplete: (String, [String]) -> Void

    init(editing: Bool = false, forceLogin: Bool = false, store: OnboardingStore = OnboardingStore(), auth: any OnboardingAuthService = OnboardingLiveAuthService(), telemetry: (any ProductTelemetryRecording)? = nil, onEnvironmentSelected: @escaping (Bool) -> Void = { _ in }, onComplete: @escaping (String, [String]) -> Void) {
        self.editing = editing
        self.forceLogin = forceLogin
        self.store = store
        self.auth = auth
        self.telemetryOverride = telemetry
        self.onEnvironmentSelected = onEnvironmentSelected
        self.onComplete = onComplete
    }
    var body: some View {
        OnboardingFlowContent(editing: editing, forceLogin: forceLogin, store: store, auth: auth,
                              telemetry: telemetryOverride ?? telemetry, onEnvironmentSelected: onEnvironmentSelected, onComplete: onComplete)
    }
}

private struct OnboardingFlowContent: View {
    @StateObject private var model: OnboardingViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var legalPage: OnboardingLegalPage?
    @State private var introductionPage = 0
    private let onComplete: (String, [String]) -> Void
    private let editing: Bool
    private let onEnvironmentSelected: (Bool) -> Void

    init(editing: Bool, forceLogin: Bool, store: OnboardingStore, auth: any OnboardingAuthService, telemetry: any ProductTelemetryRecording, onEnvironmentSelected: @escaping (Bool) -> Void, onComplete: @escaping (String, [String]) -> Void) {
        _model = StateObject(wrappedValue: OnboardingViewModel(store: store, auth: auth, editing: editing, forceLogin: forceLogin, telemetry: telemetry))
        self.editing = editing
        self.onEnvironmentSelected = onEnvironmentSelected
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            Group {
                if !model.isLoaded { ProgressView("Загружаем профиль…") }
                else if !model.isStorageReady {
                    ContentUnavailableView {
                        Label("Анкета недоступна", systemImage: "externaldrive.badge.exclamationmark")
                    } description: { Text(model.errorMessage ?? "Не удалось открыть сохранённые ответы.") } actions: {
                        Button("Повторить") { Task { await model.load() } }
                    }
                } else { screen }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(WK.C.canvas)
            .toolbar {
                if ![.introduction, .login, .summary, .complete].contains(model.stage) {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { Task { await model.back() } } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Назад")
                    }
                }
                if editing {
                    ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } }
                }
            }
            .toolbarBackground(WK.C.canvas, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.isStorageReady { bottomActions }
            }
            .overlay(alignment: .top) {
                if let error = model.errorMessage, model.isStorageReady {
                    VStack(spacing: 6) {
                        Text(error).wkFont(.captionS, color: WK.C.danger)
                        Button("Закрыть") { model.errorMessage = nil }.wkFont(.caption)
                    }
                    .padding(12).frame(maxWidth: .infinity)
                    .background(WK.C.dangerSoft, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                    .accessibilityIdentifier("onboarding.error")
                }
            }
            .disabled(model.isBusy)
            .animation(WKMotion.screen, value: model.stage)
        }
        .tint(WK.C.violet)
        .preferredColorScheme(.light)
        .task { await model.load(); introductionPage = model.draft.introductionIndex }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await model.checkpointExit() } }
        }
        .sheet(item: $legalPage) { page in legalView(page) }
        .sheet(isPresented: $model.showQuestionList) { questionList }
    }

    @ViewBuilder private var screen: some View {
        switch model.stage {
        case .introduction: introduction
        case .login: login
        case .email: email
        case .code: code
        case .consent: consent
        case .declined: declined
        case .name: name
        case .rationale: rationale
        case .questionnaire: questionnaire
        case .summary, .complete: summary
        }
    }

    private var introduction: some View {
        VStack(spacing: 12) {
            HStack {
                WKIconBadge(icon: "steps", bg: WK.C.violet, fg: WK.C.lime, size: 36, radius: 12)
                Spacer()
                Button("Пропустить") { Task { await model.nextIntroduction(skip: true) } }.wkFont(.calloutS, color: WK.C.ink2).accessibilityIdentifier("onboarding.introSkip")
            }.padding(.horizontal, 20)
            TabView(selection: $introductionPage) {
                introductionSlide(0, title: "Гуляй интереснее, а не дольше", message: "Walkie собирает пешую прогулку под твои интересы, время и погоду — за минуту вместо часа поиска").tag(0)
                introductionSlide(1, title: "Расскажи, что тебе нравится", message: "Выбирай любимые места — мы соберём маршрут под тебя").tag(1)
                introductionSlide(2, title: "Анкета займёт около 1,5 минуты", message: "Короткие вопросы помогут найти места, в которые захочется вернуться").tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .onChange(of: introductionPage) { _, page in Task { await model.introductionPage(page) } }
        }
    }

    private func introductionSlide(_ index: Int, title: String, message: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image("onboarding-hero-\(index + 1)").resizable().scaledToFit()
                    .frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 36))
                    .accessibilityHidden(true)
                Text(title).wkFont(.h1)
                Text(message).wkFont(.body, color: WK.C.ink2)
            }.padding(20)
        }
    }

    private var login: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 18) {
                    WKIconBadge(icon: "steps", bg: WK.C.lime, fg: WK.C.violet, size: 72, radius: 24)
                    Text("walkie").wkFont(.display, color: WK.C.lime)
                    Text("Пешие маршруты в один клик").wkFont(.display, color: .white)
                    Text("Под твои интересы, время и настроение").wkFont(.body, color: .white)
                    HStack { ForEach(["Парки", "Кофе", "Виды"], id: \.self) { WKChip(title: $0) } }
                }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                .background(WK.C.violet, in: UnevenRoundedRectangle(bottomLeadingRadius: 40, bottomTrailingRadius: 40))
                if model.isDemo {
                    Text("Локальный тест доступен отдельно. Для работы с сервером войди через Apple или почту.")
                        .wkFont(.caption, color: WK.C.ink2).padding(.horizontal, 20)
                }
            }
        }
    }

    private var email: some View {
        page {
            WKIconBadge(icon: "mail", size: 64, radius: 24)
            Text("Вход по почте").wkFont(.h1)
            Text(model.isDemo ? model.authExplanation : "Пришлём код из 6 цифр. Пароль не нужен").wkFont(.body, color: WK.C.ink2)
            TextField("name@mail.ru", text: $model.email)
                .keyboardType(.emailAddress).textContentType(.emailAddress)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .textFieldStyle(WKTextFieldStyle(icon: "mail", isError: !model.email.isEmpty && !model.validEmail))
                .accessibilityIdentifier("onboarding.email")
            if !model.email.isEmpty && !model.validEmail {
                Text("Похоже, в адресе опечатка. Пример: name@mail.ru").wkFont(.caption, color: WK.C.danger)
            }
        }
    }

    private var code: some View {
        page {
            WKIconBadge(icon: "mail", size: 64, radius: 24)
            Text("Введи код").wkFont(.h1).fixedSize(horizontal: false, vertical: true)
            Text(model.isDemo ? model.authExplanation : "Код отправлен на \(model.draft.email)").wkFont(.body, color: WK.C.ink2)
            ZStack {
                HStack(spacing: 7) {
                    ForEach(0..<6, id: \.self) { index in
                        Text(codeDigit(index)).wkFont(.h2)
                            .frame(maxWidth: .infinity).frame(height: 62)
                            .background(WK.C.surface, in: RoundedRectangle(cornerRadius: 16))
                            .overlay(RoundedRectangle(cornerRadius: 16).stroke(index == model.code.count ? WK.C.violet : WK.C.line, lineWidth: 2))
                    }
                }.accessibilityHidden(true)
                TextField("", text: $model.code, prompt: Text(""))
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .foregroundStyle(.clear).tint(.clear)
                    .frame(height: 62)
                    .accessibilityLabel("Код из 6 цифр")
                    .accessibilityIdentifier("onboarding.code")
                    .onChange(of: model.code) { _, value in model.code = String(value.filter(\.isNumber).prefix(6)) }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(ceil((model.draft.challenge?.retryAfter ?? context.date).timeIntervalSince(context.date))))
                if seconds > 0 {
                    Text("Отправить код заново можно через \(seconds / 60):\(String(format: "%02d", seconds % 60))").wkFont(.callout, color: WK.C.ink2)
                } else {
                    Button("Запросить новый код") { Task { await model.requestCode() } }.wkFont(.calloutS, color: WK.C.violet)
                }
            }
            if !model.isDemo { Text("Не пришло письмо? Загляни в «Спам»").wkFont(.caption, color: WK.C.ink2) }
        }
    }

    private var consent: some View {
        page {
            WKIconBadge(icon: "shield", bg: WK.C.mintSoft, fg: WK.C.mint, size: 64, radius: 24)
            Text("Пара слов о данных").wkFont(.h1)
            Text("Чтобы строить маршруты под тебя, нам нужно твоё согласие на обработку:").wkFont(.body, color: WK.C.ink2)
            VStack(spacing: 18) {
                infoRow("Профиль и анкета", detail: "Имя, интересы и ответы — для подбора мест", icon: "user")
                infoRow("Геоданные", detail: "Остаются на телефоне; текущая точка отправляется только по твоей кнопке для построения маршрута", icon: "pin")
                infoRow("Действия в приложении", detail: "События для проверки качества маршрутов и исследования", icon: "activity")
            }.wkCard(padding: 16)
            Button("Полный текст согласия · версия 1.0") { legalPage = .consent }.wkFont(.calloutS, color: WK.C.violet).underline()
            if model.isDemo { Text("Тестовый локальный режим: согласие и время фиксируются на устройстве.").wkFont(.caption, color: WK.C.ink2) }
        }
    }

    private var declined: some View {
        page {
            WKIconBadge(icon: "shield", bg: WK.C.sunSoft, fg: WK.C.ink, size: 64)
            Text("Без согласия маршрут не построить").wkFont(.h1)
            Text("Аккаунт не создан, данные регистрации удалены. Ты можешь вернуться и принять согласие.").wkFont(.body, color: WK.C.ink2)
        }
    }

    private var name: some View {
        page {
            WKAvatar(initials: model.name.isEmpty ? "?" : String(model.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2)).uppercased(), userId: model.draft.userID, size: 88)
            Text("Как тебя называть?").wkFont(.h1)
            TextField("Твоё имя", text: $model.name).textContentType(.givenName)
                .textFieldStyle(WKTextFieldStyle(icon: "user", isError: model.name.count > 30))
                .accessibilityIdentifier("onboarding.name")
            Text("\(model.name.count)/30").wkFont(.caption, color: model.name.count > 30 ? WK.C.danger : WK.C.ink3)
            Text(model.name.count > 30 ? "Слишком длинно: максимум 30 символов" : "Имя нужно, чтобы друзья тебя узнали")
                .wkFont(.callout, color: model.name.count > 30 ? WK.C.danger : WK.C.ink2)
        }
    }

    private var rationale: some View {
        page {
            WKProgressBar(step: 2, total: 15, label: "Шаг 2 из 15 · согласие и имя уже засчитаны")
            VStack(alignment: .leading, spacing: 18) {
                HStack { WKIconBadge(icon: "clock", bg: WK.C.lime, fg: WK.C.ink); Text("~1,5 минуты").wkFont(.h2, color: .white) }
                Text("13 коротких вопросов").wkFont(.display, color: .white)
                Text("После этого маршрут собирается за минуту вместо часа").wkFont(.body, color: .white)
                Text("Без оценок по шкале · можно пропускать · без предвыбора").wkFont(.captionS, color: WK.C.lime)
            }.padding(24).background(WK.C.violet, in: RoundedRectangle(cornerRadius: 36))
            VStack(spacing: 18) {
                infoRow("Сразу покажем, как мы тебя поняли", detail: "И дадим поправить", icon: "sparkles")
                infoRow("Выйдешь — продолжишь с того же места", detail: "Ответы сохраняются по одному", icon: "refresh")
            }.wkCard()
        }
    }

    private var questionnaire: some View {
        let question = model.question
        return page {
            WKProgressBar(step: question.step, total: 15)
            Text("\(question.id.replacingOccurrences(of: "P", with: "П")) · \(question.tag)\(question.isRequired ? " · ОБЯЗАТЕЛЬНЫЙ" : "")")
                .wkFont(.micro, color: WK.C.violet).padding(.horizontal, 10).padding(.vertical, 6)
                .background(WK.C.violetSoft, in: Capsule())
            Text(question.title).wkFont(.h1).accessibilityIdentifier("onboarding.question.\(question.id)")
            if question.id == "P2" {
                Text("Выбери от 3 до 5").wkFont(.callout, color: WK.C.ink2)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in interestTile(option, index: index) }
                }
                Text("Выбрано \(model.selectedIDs.count) из 5\(model.selectedIDs.count < 3 ? " · нужно ещё минимум \(3 - model.selectedIDs.count)" : model.selectedIDs.count == 5 ? " — максимум" : "")")
                    .wkFont(.captionS, color: WK.C.ink2)
            } else {
                VStack(spacing: 10) {
                    ForEach(question.options) { option in
                        WKOptionCard(title: option.title, icon: question.id == "P1" ? option.icon : nil,
                                     isSelected: model.selectedIDs.contains(option.id), isMulti: question.isMultiple) {
                            Task { await model.select(option) }
                        }.accessibilityIdentifier("onboarding.\(question.id).\(option.id)")
                    }
                }
            }
            Text("Ответы сохраняются на каждом шаге").wkFont(.caption, color: WK.C.ink3)
        }.id(question.id)
    }

    private var summary: some View {
        page {
            VStack(alignment: .leading, spacing: 18) {
                WKIconBadge(icon: "sparkles", bg: WK.C.lime, fg: WK.C.ink, size: 52)
                Text("Как мы тебя поняли").wkFont(.display, color: .white).accessibilityIdentifier("onboarding.summary")
                Text("Проверь: если что-то не так — поправь, это займёт пару секунд").wkFont(.body, color: .white)
            }.padding(24).background(WK.C.violet, in: RoundedRectangle(cornerRadius: 36))
            Text("Выбранные интересы: " + model.interestTitles.joined(separator: ", "))
                .wkFont(.calloutS).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("onboarding.selectedInterests")
            if editing {
                Text("Чтобы применить изменения к профилю, нажми «Сохранить профиль» внизу.")
                    .wkFont(.caption, color: WK.C.ink2)
            }
            ForEach(Array(model.summaryPhrases.enumerated()), id: \.offset) { index, phrase in
                HStack(alignment: .top, spacing: 16) {
                    WKIconBadge(icon: ["building", "bolt", "steps"][min(index, 2)], size: 48)
                    Text(phrase).wkFont(.bodyS).frame(maxWidth: .infinity, alignment: .leading)
                }.wkCard(padding: 16)
            }
        }
    }

    @ViewBuilder private var bottomActions: some View {
        VStack(spacing: 12) {
            switch model.stage {
            case .introduction:
                HStack(spacing: 6) { ForEach(0..<3, id: \.self) { index in Capsule().fill(index == introductionPage ? WK.C.violet : WK.C.line).frame(width: index == introductionPage ? 24 : 8, height: 8) } }
                WKButton(title: introductionPage == 2 ? "Начать" : "Далее") {
                    Task { await model.nextIntroduction(); introductionPage = model.draft.introductionIndex }
                }
            case .login:
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.fullName, .email]
                    } onCompletion: { result in
                        switch result {
                        case .success(let authorization):
                            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                                  let data = credential.identityToken, let token = String(data: data, encoding: .utf8) else {
                                model.errorMessage = "Apple не вернула токен входа. Попробуй ещё раз."
                                return
                            }
                            let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
                            let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
                            Task { await model.signInApple(identityToken: token, authorizationCode: code, fullName: name) }
                        case .failure(let error):
                            if (error as? ASAuthorizationError)?.code != .canceled { model.errorMessage = userFacingError(error) }
                        }
                    }.signInWithAppleButtonStyle(.black).frame(height: 56).clipShape(Capsule())
                    WKButton(title: "Войти по почте", kind: .secondary, icon: "mail") { Task { await model.enterEmail() } }
                    Button("Локальный тест без аккаунта") { Task { await model.startLocalDemo() } }.wkFont(.captionS, color: WK.C.ink2).accessibilityIdentifier("onboarding.localDemo")
                HStack(spacing: 4) {
                    Button("Правила сервиса") { legalPage = .terms }
                    Text("·")
                    Button("Политика данных") { legalPage = .privacy }
                }.wkFont(.caption, color: WK.C.violet)
            case .email:
                WKButton(title: model.isBusy ? "Отправляем…" : model.isDemo ? "Получить тестовый код" : "Получить код") { Task { await model.requestCode() } }.disabled(!model.validEmail).opacity(model.validEmail ? 1 : 0.4)
            case .code:
                WKButton(title: "Продолжить") { Task { await model.verifyCode() } }.disabled(model.code.count != 6).opacity(model.code.count == 6 ? 1 : 0.4)
            case .consent:
                WKButton(title: "Принимаю") { Task { await model.acceptConsent() } }.accessibilityIdentifier("onboarding.acceptConsent")
                Button("Отказаться") { Task { await model.declineConsent() } }.wkFont(.bodyS, color: WK.C.violet)
            case .declined:
                WKButton(title: "Вернуться и принять") { Task { await model.returnAfterDecline() } }
                Button("На экран входа") { Task { await model.back() } }.wkFont(.bodyS, color: WK.C.violet)
            case .name:
                WKButton(title: "Далее") { Task { await model.saveName() } }.disabled(!model.validName).opacity(model.validName ? 1 : 0.4).accessibilityIdentifier("onboarding.saveName")
            case .rationale:
                WKButton(title: "Поехали", icon: "play") { Task { await model.startQuestions() } }.accessibilityIdentifier("onboarding.startQuestions")
            case .questionnaire:
                if model.question.isMultiple {
                    WKButton(title: model.isEditingSummary ? "К итогам анкеты" : "Далее") { Task { await model.nextQuestion() } }
                        .disabled(!model.canContinueQuestion).opacity(model.canContinueQuestion ? 1 : 0.4)
                        .accessibilityIdentifier("onboarding.nextQuestion")
                }
                if !model.question.isRequired {
                    Button("Пропустить") { Task { await model.skipQuestion() } }.wkFont(.callout, color: WK.C.ink3).accessibilityIdentifier("onboarding.skipQuestion")
                } else {
                    Text("Пропуска нет: без интересов отбор = популярность").wkFont(.caption, color: WK.C.ink3).multilineTextAlignment(.center)
                }
            case .summary, .complete:
                WKButton(title: editing ? "Сохранить профиль" : "Всё верно", icon: "check") {
                    Task { if await model.finish() { onEnvironmentSelected(model.isDemo); onComplete(model.draft.name, model.draft.interests) } }
                }.accessibilityIdentifier("onboarding.complete")
                WKButton(title: "Поправить", kind: .secondary, icon: "edit") { Task { await model.startSummaryEdit() } }.accessibilityIdentifier("onboarding.editAnswers")
            }
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .background(LinearGradient(colors: [WK.C.canvas.opacity(0), WK.C.canvas, WK.C.canvas], startPoint: .top, endPoint: .bottom))
    }

    private var questionList: some View {
        NavigationStack {
            List {
                ForEach(Array(model.draft.questions.enumerated()), id: \.element.id) { index, question in
                    Button { Task { await model.editQuestion(index) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(question.title).wkFont(.calloutS)
                            let answer = model.draft.answers[question.id]
                            Text(answer?.skipped == true ? "Пропущено" : question.options.filter { answer?.optionIDs.contains($0.id) == true }.map(\.title).joined(separator: ", "))
                                .wkFont(.caption, color: WK.C.ink2)
                        }
                    }.accessibilityIdentifier("onboarding.editQuestion.\(question.id)")
                }
            }.navigationTitle("Поправить ответы").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { model.showQuestionList = false } } }
        }.tint(WK.C.violet)
    }

    private func page<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 20, content: content).frame(maxWidth: .infinity, alignment: .leading).padding(20) }
            .scrollDismissesKeyboard(.interactively)
    }

    private func interestTile(_ option: OnboardingOption, index: Int) -> some View {
        let selected = model.selectedIDs.contains(option.id)
        let blocked = !selected && model.selectedIDs.count == 5
        let colors = [WK.C.coralSoft, WK.C.violetSoft, WK.C.dangerSoft, WK.C.mintSoft, WK.C.violetSoft, WK.C.sunSoft]
        return Button { Task { await model.select(option) } } label: {
            HStack(spacing: 8) {
                WKIconBadge(icon: option.icon, bg: WK.C.surface, fg: WK.C.violet, size: 30)
                Text(option.title).wkFont(.captionS, color: selected ? .white : WK.C.ink).multilineTextAlignment(.leading)
                if selected { WKIcon(name: "check", size: 14, color: .white) }
            }.frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).padding(8)
                .background(selected ? WK.C.violet : colors[index % colors.count], in: RoundedRectangle(cornerRadius: 20))
        }.buttonStyle(.plain).opacity(blocked ? 0.45 : 1).disabled(blocked)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("onboarding.P2.\(option.id)")
    }

    private func infoRow(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            WKIconBadge(icon: icon, size: 40, radius: 14)
            VStack(alignment: .leading, spacing: 4) { Text(title).wkFont(.bodyS); Text(detail).wkFont(.callout, color: WK.C.ink2) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeDigit(_ index: Int) -> String {
        let digits = Array(model.code)
        return digits.indices.contains(index) ? String(digits[index]) : ""
    }

    private func legalView(_ page: OnboardingLegalPage) -> some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(page.title).wkFont(.h1)
                    Text("Тестовая сборка Walkie").wkFont(.bodyS)
                    Text("Профиль и ответы сохраняются на устройстве и используются для подбора прогулок. Геопозиция и данные движения обрабатываются локально во время активной прогулки. Текущая точка может передаваться серверу по отдельной команде построения маршрута. Локальные файлы можно удалить вместе с данными приложения.").wkFont(.body)
                    Text("Окончательный юридический текст версии 1.0 ещё не включён в handoff. Этот экран описывает поведение тестовой сборки и должен быть заменён утверждённым текстом перед публичным пилотом.").wkFont(.callout, color: WK.C.ink2)
                }.padding(20)
            }.background(WK.C.canvas).navigationTitle(page.title).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { legalPage = nil } } }
        }
    }
}

private enum OnboardingLegalPage: String, Identifiable {
    case consent, terms, privacy
    var id: String { rawValue }
    var title: String {
        switch self { case .consent: return "Согласие · версия 1.0"; case .terms: return "Правила сервиса"; case .privacy: return "Политика данных" }
    }
}

