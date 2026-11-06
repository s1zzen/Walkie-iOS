import SwiftUI

/// Just-in-time S-07 appears only after an explicit tap on the walk start button.
@MainActor
struct WalkPermissionsFlowView: View {
    @Environment(\.productTelemetry) private var telemetry
    private let client: any WalkPermissionsClient
    private let onComplete: (WalkPermissionsOutcome) -> Void
    private let purpose: WalkPermissionPurpose

    init(client: (any WalkPermissionsClient)? = nil, purpose: WalkPermissionPurpose = .walkStart, onComplete: @escaping (WalkPermissionsOutcome) -> Void) {
        self.client = client ?? SystemWalkPermissionsClient()
        self.onComplete = onComplete
        self.purpose = purpose
    }
    var body: some View {
        WalkPermissionsContent(model: WalkPermissionsViewModel(client: client, telemetry: telemetry, purpose: purpose), onComplete: onComplete)
    }
}

@MainActor
private struct WalkPermissionsContent: View {
    @StateObject private var model: WalkPermissionsViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let onComplete: (WalkPermissionsOutcome) -> Void
    @State private var didComplete = false

    init(model: WalkPermissionsViewModel, onComplete: @escaping (WalkPermissionsOutcome) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onComplete = onComplete
    }

    var body: some View {
        NavigationStack {
            Group {
                if let permission = model.current {
                    explanation(permission)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(WK.C.canvas)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await model.notNow() } } label: { WKIcon(name: "x", size: 22) }
                        .accessibilityLabel("Не сейчас").accessibilityIdentifier("permission.close")
                        .disabled(model.isRequesting)
                }
            }
            .toolbarBackground(WK.C.canvas, for: .navigationBar)
        }
        .tint(WK.C.violet).preferredColorScheme(.light)
        .interactiveDismissDisabled()
        .task { await model.begin(); completeIfNeeded() }
        .onChange(of: model.outcome) { _, _ in completeIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAfterSettings() } }
        }
    }

    private func explanation(_ permission: WalkPermission) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 12) {
                    WKIcon(name: model.status == .approximate ? "locate" : permission == .location ? "nav" : "steps", size: compactHero ? 36 : 48,
                           color: heroForeground(permission))
                        .frame(width: compactHero ? 72 : 96, height: compactHero ? 72 : 96)
                        .background(WK.C.surface, in: RoundedRectangle(cornerRadius: compactHero ? 24 : 32)).wkElevated()
                    HStack(spacing: 6) {
                        WKIcon(name: "lock", size: 16, color: WK.C.ink2)
                        Text(model.status.isPreviouslyDenied ? "Сейчас доступ выключен" : model.status == .approximate ? "Сейчас: приблизительно" : permission == .location ? "Только «При использовании»" : "Шаги остаются на iPhone").wkFont(.captionS)
                    }.padding(.horizontal, 12).padding(.vertical, 8).wkGlass(radius: 16)
                }
                .frame(maxWidth: .infinity).frame(height: compactHero ? 150 : 220)
                .background(heroBackground(permission), in: RoundedRectangle(cornerRadius: 36))
                Text(title(permission)).wkFont(.h1).accessibilityIdentifier("permission.title.\(permission.rawValue)")
                Text(subtitle(permission)).wkFont(.body, color: WK.C.ink2)
                VStack(spacing: 14) {
                    point("check", model.status.isPreviouslyDenied ? "После включения вернись в Walkie — всё подхватится" : permission == .location ? "Покажем положение на маршруте. Посещения ты подтверждаешь сам" : "Шаги дополняют итог прогулки и локальные исследовательские записи", positive: true)
                    point("info", permission == .location ? "Без неё: старт выбираешь на карте, маршрут можно открыть в Яндекс Картах" : "Без него: прогулка работает по геопозиции, вместо шагов — прочерк", positive: false)
                }.wkCard(padding: 16)
                if model.status == .denied || model.status == .restricted {
                    Text(permission == .location ? "Настройки › Walkie › Геопозиция › При использовании" : "Настройки › Конфиденциальность и безопасность › Движение и фитнес › Walkie")
                        .wkFont(.captionS, color: WK.C.violet).padding(.horizontal, 14).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading).background(WK.C.violetSoft, in: RoundedRectangle(cornerRadius: 16))
                }
                if model.status == .approximate {
                    Text("Для точного положения открой Настройки › Walkie › Геопозиция и включи «Точная геопозиция». Даже точное разрешение не гарантирует правильные координаты.")
                        .wkFont(.caption, color: WK.C.ink2)
                }
                if let error = model.errorMessage { WKBanner(title: error, kind: .warning) }
            }.padding(20)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 10) {
                if model.status != .unavailable {
                    WKButton(title: model.isRequesting ? "Ждём ответ iPhone…" : primaryTitle) { Task { await model.allow() } }
                        .disabled(model.isRequesting).accessibilityIdentifier("permission.allow.\(permission.rawValue)")
                }
                if model.status == .approximate {
                    WKButton(title: "Продолжить с приблизительной", kind: .secondary) { Task { await model.continueWithApproximateLocation() } }
                        .disabled(model.isRequesting).accessibilityIdentifier("permission.approximate")
                }
                Button("Не сейчас") { Task { await model.notNow() } }
                    .wkFont(.bodyS, color: WK.C.violet).frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(model.isRequesting).accessibilityIdentifier("permission.skip.\(permission.rawValue)")
            }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 16)
                .background(LinearGradient(colors: [WK.C.canvas.opacity(0), WK.C.canvas, WK.C.canvas], startPoint: .top, endPoint: .bottom))
        }
    }

    private var primaryTitle: String {
        if model.status == .notDetermined { return "Разрешить" }
        if model.status == .granted { return "Продолжить" }
        return "Открыть Настройки"
    }
    private func title(_ permission: WalkPermission) -> String {
        if model.status == .approximate { return "Нужна точная геопозиция" }
        if model.status.isPreviouslyDenied { return permission == .location ? "Включи геопозицию в Настройках" : "Включи шагомер в Настройках" }
        if model.status == .unavailable { return permission == .location ? "Геопозиция недоступна" : "На этом устройстве нет шагомера" }
        return permission == .location ? "Покажем, где ты на маршруте" : "Посчитаем шаги за прогулку"
    }
    private func subtitle(_ permission: WalkPermission) -> String {
        if model.status == .denied { return "Ты уже отказал в доступе, поэтому системный запрос больше не появится" }
        if model.status == .restricted { return "Доступ ограничен настройками устройства. Проверь разрешения в iOS." }
        if model.status == .approximate { return "С приблизительной точкой трудно ориентироваться. Включи точную геопозицию или продолжи с ограничениями." }
        return permission == .location
            ? "Геопозиция нужна, чтобы выбрать старт и вести по точкам во время прогулки. GPS-трек остаётся на телефоне."
            : "Данные движения помогают дополнить прогулку шагами. Разрешение необязательное: можно продолжить без шагов."
    }
    private var compactHero: Bool { model.status.isPreviouslyDenied || model.status == .approximate }
    private func heroBackground(_ permission: WalkPermission) -> Color {
        if model.status.isPreviouslyDenied { return WK.C.coralSoft }
        if model.status == .approximate { return WK.C.sunSoft }
        return permission == .location ? Color(hex: 0xDDF1FF) : Color(hex: 0xECFFC2)
    }
    private func heroForeground(_ permission: WalkPermission) -> Color {
        if model.status.isPreviouslyDenied { return WK.C.coral }
        if model.status == .approximate { return WK.C.sun }
        return permission == .location ? WK.C.sky : WK.C.mint
    }
    private func point(_ icon: String, _ text: String, positive: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            WKIconBadge(icon: icon, bg: positive ? WK.C.mintSoft : WK.C.sunken, fg: positive ? WK.C.mint : WK.C.ink2, size: 40, radius: 13)
            Text(text).wkFont(.bodyS).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func completeIfNeeded() {
        guard !didComplete, let outcome = model.outcome else { return }
        didComplete = true
        onComplete(outcome)
    }
}
