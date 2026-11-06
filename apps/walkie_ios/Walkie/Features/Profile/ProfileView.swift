import SwiftUI

struct ProfileView: View {
    @ObservedObject var model: ProductViewModel
    @ObservedObject var history: HistoryViewModel
    @ObservedObject var account: AccountViewModel
    var onSignOut: () -> Void = {}
    @State private var showsEditor = false
    @State private var showsPro = false
    @State private var showsPrivacy = false
    @State private var showsAccount = false
    @State private var deleteConfirmation = false
    @State private var editorSaving = false
    @State private var profileSaveError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Профиль").wkFont(.h1)
                        Spacer()
                        if account.socialEnabled { NavigationLink { ServiceUnavailableView(title: "Лента", message: "Новых событий пока нет", icon: "bell") } label: { WKIcon(name: "bell") } }
                    }.frame(minHeight: 52)
                    HStack(spacing: 14) {
                        WKAvatar(initials: String(displayName.prefix(1)), userId: account.info?.id ?? "local", size: 72)
                            .overlay(Circle().stroke(WK.C.lime, lineWidth: 3))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(displayName).wkFont(.h1, color: .white)
                            Text("\(history.sessions.count) маршрутов").wkFont(.captionS)
                                .padding(.horizontal, 10).padding(.vertical, 4).background(WK.C.lime, in: Capsule())
                        }
                        Spacer(minLength: 0)
                        Button { showsEditor = true } label: { WKIconBadge(icon: "edit", bg: .white, fg: WK.C.violet, size: 40) }
                            .accessibilityIdentifier("profile.edit").accessibilityLabel("Редактировать профиль")
                    }.padding(18).background(WK.C.violet, in: RoundedRectangle(cornerRadius: 32))
                    HStack(spacing: 8) {
                        stat("за всё время", value: distance, icon: "route", color: WK.C.sky)
                        stat("шагов за неделю", value: account.info.map { String($0.stats.steps_week) } ?? "—", icon: "steps", color: WK.C.mint)
                        stat("средняя оценка", value: account.info?.stats.rating_avg.map { String(format: "%.1f", $0) } ?? "—", icon: "star", color: WK.C.sun)
                    }
                    if let error = account.errorMessage { WKBanner(title: "Синхронизация недоступна", message: error, kind: .warning) }
                    VStack(spacing: 0) {
                        row("Анкета", subtitle: "Интересы, темп, что не подходит", icon: "sparkles", color: WK.C.violetSoft) { showsEditor = true }
                        Divider()
                        row("Приватность", subtitle: account.settings.routes_visibility == "only_me" ? "Маршруты видны только мне" : "Маршруты видны друзьям", icon: "lock", color: WK.C.mintSoft) { showsPrivacy = true }
                        Divider()
                        row("Уведомления", subtitle: "4 категории", icon: "bell", color: WK.C.coralSoft) { showsPrivacy = true }
                        if !history.sessions.isEmpty {
                            Divider()
                            row("Walkie Pro", subtitle: "Подписка · 299 ₽ в месяц", icon: "sparkles", color: WK.C.lime) { showsPro = true }
                        }
                        Divider()
                        row("Учётная запись", subtitle: "Способы входа, выход, удаление", icon: "user", color: WK.C.sunSoft) { showsAccount = true }
                    }.padding(.horizontal, 16).background(WK.C.surface, in: RoundedRectangle(cornerRadius: 24)).wkCardShadow()
                    Text("GPS-трек и исследовательские записи хранятся на этом iPhone. Экспорт доступен в истории прогулок.")
                        .wkFont(.caption, color: WK.C.ink2)
                }.padding(20).padding(.bottom, 80)
            }
            .background(WK.C.canvas).toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showsEditor) {
                OnboardingFlowView(editing: true) { name, interests in
                    guard !editorSaving else { return }
                    editorSaving = true
                    Task {
                        let saved = await model.saveProfile(UserProfile(name: name, interests: interests, onboardingComplete: true))
                        editorSaving = false
                        if saved {
                            profileSaveError = nil
                            showsEditor = false
                            await account.refresh()
                        } else {
                            profileSaveError = model.errorMessage ?? "Профиль не удалось сохранить на iPhone. Ответы анкеты сохранены; повтори подтверждение."
                        }
                    }
                }
                .disabled(editorSaving)
                .interactiveDismissDisabled(editorSaving)
                .alert("Профиль не обновлён", isPresented: Binding(get: { profileSaveError != nil }, set: { if !$0 { profileSaveError = nil } })) {
                    Button("Понятно") { profileSaveError = nil }
                } message: { Text(profileSaveError ?? "Повтори сохранение.") }
            }
            .sheet(isPresented: $showsPro) { ProIntentView(account: account, entry: "profile") }
            .sheet(isPresented: $showsPrivacy) { privacy }
            .sheet(isPresented: $showsAccount) { accountView }
            .task { await history.refresh(); await account.refresh() }
        }
    }
    private var displayName: String { account.info?.display_name ?? (model.profile.name.isEmpty ? "Исследователь" : model.profile.name) }
    private var distance: String { account.info.map { String(format: "%.1f км", Double($0.stats.distance_total_m) / 1000) } ?? "—" }
    private func stat(_ title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) { WKIcon(name: icon, size: 18, color: color); Text(value).wkFont(.bodyS); Text(title).wkFont(.micro, color: WK.C.ink2) }
            .frame(maxWidth: .infinity, alignment: .leading).wkCard(padding: 12, radius: 20)
    }
    private func row(_ title: String, subtitle: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                WKIconBadge(icon: icon, bg: color, fg: WK.C.violet, size: 36, radius: 12)
                VStack(alignment: .leading, spacing: 2) { Text(title).wkFont(.bodyS); Text(subtitle).wkFont(.caption, color: WK.C.ink2) }
                Spacer(); WKIcon(name: "chev-r", size: 18, color: WK.C.ink3)
            }.padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private var privacy: some View {
        NavigationStack {
            Form {
                Section("Видимость маршрутов") {
                    Picker("Кто видит мои маршруты", selection: $account.settings.routes_visibility) { Text("Только я").tag("only_me"); Text("Друзья").tag("friends") }
                    Toggle("Участие в рейтинге", isOn: $account.settings.leaderboard_enabled).disabled(!account.socialEnabled)
                }
                Section("Уведомления") {
                    Toggle("Приглашения", isOn: $account.settings.notifications.invites)
                    Toggle("Совместные маршруты", isOn: $account.settings.notifications.joint_routes)
                    Toggle("Напомнить об оценке", isOn: $account.settings.notifications.rating_reminder)
                    Toggle("Итоги недели", isOn: $account.settings.notifications.weekly_results)
                }
                Section { Text("Эти настройки не разрешают отправку GPS-трека.") }
                if let error = account.errorMessage { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Приватность").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Сохранить") { Task { if await account.saveSettings() { showsPrivacy = false } } }.disabled(account.isBusy) } }
        }
    }
    private var accountView: some View {
        NavigationStack {
            Form {
                Section("Сессия") { Text(account.hasSession ? "Вход на сервер выполнен" : "Локальный режим") }
                Section {
                    Button("Выйти") { Task { if await account.signOut() { onSignOut() } } }
                    Button("Удалить учётную запись", role: .destructive) { deleteConfirmation = true }
                }
                if let error = account.errorMessage { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Учётная запись").navigationBarTitleDisplayMode(.inline)
                .confirmationDialog("Удалить учётную запись без возможности восстановления?", isPresented: $deleteConfirmation, titleVisibility: .visible) {
                    Button("Удалить учётную запись", role: .destructive) { Task { if await account.signOut(deleteAccount: true) { onSignOut() } } }
                } message: { Text("Сервер удалит профиль и маршруты. Локальные исследовательские записи останутся на устройстве.") }
        }
    }
}

struct ProIntentView: View {
    @Environment(\.productTelemetry) private var telemetry
    @State private var dismissalRecorded = false
    @ObservedObject var account: AccountViewModel
    var entry: String
    @Environment(\.dismiss) private var dismiss
    @State private var accepted = false
    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Button { dismiss() } label: { WKIcon(name: "x", size: 22, color: .white).padding(12).background(.white.opacity(0.2), in: Circle()) }.accessibilityLabel("Закрыть")
                WKIconBadge(icon: "sparkles", bg: WK.C.lime, fg: WK.C.violet, size: 64)
                Text("Walkie Pro").wkFont(.display, color: .white)
                Text("Больше прогулок, которые хочется пройти").wkFont(.body, color: .white.opacity(0.85))
                HStack(alignment: .firstTextBaseline) { Text("299 ₽").wkFont(.display, color: WK.C.lime); Text("в месяц").wkFont(.bodyS, color: .white) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                .background(WK.C.violet, in: UnevenRoundedRectangle(bottomLeadingRadius: 40, bottomTrailingRadius: 40))
            VStack(spacing: 16) {
                benefit("Офлайн-режим", subtitle: "Маршрут и карта без интернета", icon: "wifi-off", color: WK.C.violetSoft)
                benefit("Эксклюзивные маршруты", subtitle: "От партнёров Walkie", icon: "star", color: WK.C.sunSoft)
                benefit("Расширенные описания мест", subtitle: "История, факты и подсказки", icon: "info", color: WK.C.mintSoft)
            }.wkCard(padding: 18).padding(.horizontal, 20)
            Spacer(minLength: 0)
            if accepted || account.info?.pro.in_early_access == true {
                Text("✓ Ты в списке раннего доступа").wkFont(.bodyS, color: WK.C.violet).padding(18)
                Text("Сообщим, когда подписка появится. Оплата не списана.").wkFont(.caption, color: WK.C.ink2)
            } else {
                WKButton(title: account.isBusy ? "Сохраняем…" : "Оформить", kind: .lime, icon: "sparkles") { Task { accepted = await account.subscribe(entry: entry) } }
                    .disabled(account.isBusy).padding(.horizontal, 20).accessibilityIdentifier("pro.subscribe")
            }
            if let error = account.errorMessage { Text(error).wkFont(.caption, color: WK.C.danger).padding(.horizontal, 20) }
            Button("Не сейчас") { recordDismissal(); dismiss() }
                .wkFont(.bodyS, color: WK.C.ink3).padding(.bottom, 16)
        }.background(WK.C.canvas).task { try? await telemetry.record("pro_shown", screen: "S-45", payload: ["entry": entry]) }
            .onDisappear { recordDismissal() }
    }
    private func recordDismissal() {
        guard !dismissalRecorded else { return }
        dismissalRecorded = true
        Task { try? await telemetry.record("pro_not_now", screen: "S-45", payload: ["entry": entry]) }
    }
    private func benefit(_ title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) { WKIconBadge(icon: icon, bg: color, fg: WK.C.violet); VStack(alignment: .leading, spacing: 3) { Text(title).wkFont(.bodyS); Text(subtitle).wkFont(.caption, color: WK.C.ink2) }; Spacer() }
    }
}

struct ServiceUnavailableView: View {
    let title: String
    let message: String
    let icon: String
    var body: some View {
        VStack(spacing: 16) { WKIconBadge(icon: icon, size: 72); Text(title).wkFont(.h1); Text(message).wkFont(.body, color: WK.C.ink2).multilineTextAlignment(.center) }
            .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity).background(WK.C.canvas)
    }
}
