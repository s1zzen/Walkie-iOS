import SwiftUI

struct OnboardingView: View {
    @ObservedObject var model: ProductViewModel
    var isEditing = false
    @Environment(\.dismiss) private var dismiss
    @State private var draft = UserProfile()
    @State private var showsSummary = false
    @State private var hasInitialized = false
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 25) {
                    HStack(spacing: 10) {
                        Image(systemName: "figure.walk.circle.fill")
                            .font(.system(size: 38)).foregroundStyle(ProductPalette.accent)
                        Text("walkie").font(.system(size: 28, weight: .bold, design: .rounded))
                        Spacer()
                        Text(showsSummary ? "02 / 02" : "01 / 02")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if let error = model.errorMessage {
                        ProductErrorBanner(message: error)
                        if !model.isStorageReady {
                            Button("Повторить загрузку профиля") {
                                Task {
                                    await model.load()
                                    if model.isStorageReady { draft = model.profile }
                                }
                            }
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("onboarding.retryLoad")
                        }
                    }
                    if showsSummary { summary } else { interestsForm }
                }
                .padding(24)
            }
            .background(ProductPalette.background)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        if showsSummary {
                            guard !isSaving else { return }
                            isSaving = true
                            var candidate = draft
                            candidate.onboardingComplete = true
                            Task {
                                let saved = await model.saveProfile(candidate)
                                isSaving = false
                                if saved && isEditing { dismiss() }
                            }
                        } else { withAnimation(.easeInOut) { showsSummary = true } }
                    } label: {
                        HStack {
                            if model.isBusy { ProgressView().tint(ProductPalette.background) }
                            Text(showsSummary ? (isEditing ? "Сохранить изменения" : "Начать знакомство с городом") : "Продолжить")
                            if !model.isBusy { Image(systemName: "arrow.right") }
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 17)
                    }
                    .buttonStyle(ProductPrimaryButton())
                    .disabled(draft.interests.isEmpty || model.isBusy || isSaving || !hasInitialized || !model.isStorageReady)
                    .accessibilityIdentifier(showsSummary ? "onboarding.confirm" : "onboarding.continue")
                    Text("Профиль сохраняется только на этом iPhone")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24).padding(.vertical, 14)
                .background(ProductPalette.background)
            }
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(isSaving) }
                }
                if showsSummary {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Изменить") { withAnimation { showsSummary = false } }.disabled(isSaving)
                    }
                }
            }
            .task {
                guard !hasInitialized else { return }
                if !model.isLoaded { await model.load() }
                draft = model.profile
                hasInitialized = true
            }
        }
        .preferredColorScheme(.dark)
        .tint(ProductPalette.accent)
        .interactiveDismissDisabled(isSaving)
    }

    private var interestsForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(isEditing ? "Ваш город.\nВаши интересы." : "Город интереснее,\nкогда он ваш.")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("Что вам нравится в прогулках? Выберите хотя бы один интерес — к остальному вернёмся позже.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Как к вам обращаться?").font(.subheadline.weight(.medium))
                TextField("Имя — по желанию", text: $draft.name)
                    .textContentType(.givenName).padding(16)
                    .background(ProductPalette.card, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("onboarding.name")
                    .disabled(!hasInitialized || isSaving || !model.isStorageReady)
            }
            InterestSelectionGrid(selection: $draft.interests).disabled(!hasInitialized || isSaving || !model.isStorageReady)
            Label("Пока это короткая локальная анкета. Полная анкета и персональные рекомендации появятся после подключения сервера.", systemImage: "info.circle")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "sparkles")
                .font(.system(size: 48, weight: .light)).foregroundStyle(ProductPalette.accent)
            Text("Как мы вас поняли")
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Будем открывать город в вашем ритме." : "\(draft.name), будем открывать город в вашем ритме.")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                Label("Вам интересны", systemImage: "heart.fill")
                    .font(.headline).foregroundStyle(ProductPalette.accent)
                Text(draft.interests.compactMap { WalkInterest(rawValue: $0)?.title }.joined(separator: " · "))
                    .font(.title3.weight(.medium))
                Divider()
                Text("Время, настроение и точку старта можно выбирать перед каждой прогулкой.")
                    .foregroundStyle(.secondary)
            }
            .padding(22).background(ProductPalette.card, in: RoundedRectangle(cornerRadius: 24))
            Text("Это краткое резюме выбранных интересов, не результат анализа поведения. Всё можно изменить в профиле.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct InterestSelectionGrid: View {
    @Binding var selection: [String]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(WalkInterest.allCases) { interest in
                let selected = selection.contains(interest.rawValue)
                Button {
                    if selected { selection.removeAll { $0 == interest.rawValue } }
                    else { selection.append(interest.rawValue) }
                } label: {
                    VStack(alignment: .leading, spacing: 13) {
                        HStack {
                            Image(systemName: interest.icon).font(.title3)
                            Spacer()
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.body)
                        }
                        Text(interest.title).font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(selected ? ProductPalette.accent : Color.white.opacity(0.8))
                    .padding(15).frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
                    .background(selected ? ProductPalette.accent.opacity(0.12) : ProductPalette.card, in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? ProductPalette.accent.opacity(0.65) : Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(interest.title)
                .accessibilityValue(selected ? "Выбрано" : "Не выбрано")
                .accessibilityIdentifier("onboarding.interest.\(interest.rawValue)")
            }
        }
    }
}

enum ProductPalette {
    static let background = WTheme.background
    static let card = WTheme.card
    static let accent = WTheme.accent
}

struct ProductPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .foregroundStyle(ProductPalette.background)
            .background(ProductPalette.accent.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35), in: RoundedRectangle(cornerRadius: 19))
    }
}

struct ProductErrorBanner: View {
    let message: String
    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote).foregroundStyle(.orange)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }
}
