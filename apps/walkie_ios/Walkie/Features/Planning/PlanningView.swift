import SwiftUI
import WalkieCore

struct PlanningView: View {
    @ObservedObject var model: PlanningViewModel
    @ObservedObject var walk: WalkViewModel
    @ObservedObject var product: ProductViewModel
    var onOpenWalk: () -> Void
    @Binding var showsRoute: Bool
    var onOpenProfile: (() -> Void)? = nil
    var onOpenHistory: (() -> Void)? = nil
    var socialEnabled = false
    @State private var showsBuilder = false
    @State private var showsTogether = false
    @State private var showsNotifications = false
    @State private var resumePrompts: Set<String> = []
    @State private var showsDraftResume = false
    @State private var opensRouteAfterBuilder = false
    @State private var isForgettingDraft = false
    @AppStorage("walkie.demoServerRoutes") private var demoServerRoutes = false
    @AppStorage("walkie.localDemo") private var localDemo = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if localDemo || ProcessInfo.processInfo.environment["WALKIE_OFFLINE_DEMO"] == "1" {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Маршруты с сервера", isOn: $demoServerRoutes)
                                .tint(WK.C.violet)
                                .accessibilityIdentifier("planning.serverRoutes")
                                .disabled(walk.hasOpenSession || model.isLoading || model.isPreparingContext)
                            Text(demoServerRoutes
                                 ? "Используется сохранённая серверная сессия. Начало, финиш и ответы отправляются API; GPS-трек остаётся на телефоне. Если вход ещё не выполнен: Профиль → Учётная запись → Выйти, затем войди по почте или Apple."
                                 : "Локальные примеры: линия соединяет места и может пересекать воду и здания. Она не предназначена для пешеходной навигации.")
                                .wkFont(.caption, color: WK.C.ink2)
                        }.wkCard()
                    }
                    if walk.hasOpenSession {
                        Button { walk.resumeAction("continue_walk"); onOpenWalk() } label: { WKBanner(title: "Прогулка продолжается", message: "Вернуться к карте и оставшимся местам →", icon: "steps", kind: .info) }.buttonStyle(.plain)
                            .onAppear { showWalkResumePrompt() }
                    }
                    hero
                    if !walk.hasOpenSession && showsDraftResume {
                        VStack(alignment: .leading, spacing: 10) {
                            WKBanner(title: "Продолжим создавать прогулку?", message: "Параметры и ответы сохранены на телефоне.", icon: "clock")
                            Button {
                                model.event("resume_action", ["action": "continue"])
                                showsBuilder = true
                            } label: {
                                Text("Продолжить").frame(maxWidth: .infinity)
                            }.buttonStyle(WKButtonStyle(kind: .dark, height: 44))
                            Button(isForgettingDraft ? "Убираем…" : "Забыть черновик") {
                                isForgettingDraft = true
                                Task {
                                    if await model.forgetDraft() { showsDraftResume = false }
                                    isForgettingDraft = false
                                }
                            }.wkFont(.captionS, color: WK.C.ink2)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .accessibilityIdentifier("planning.forgetDraft")
                        }.onAppear { if resumePrompts.insert(model.request.requestID).inserted { model.event("resume_prompt_shown", ["kind": "route_draft"]) } }
                    }
                    HStack(alignment: .top, spacing: 12) {
                        if socialEnabled { Button { showsTogether = true } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                WKIcon(name: "users", size: 34, color: .white)
                                Spacer(minLength: 0)
                                Text("Совместный\nмаршрут").wkFont(.h3, color: .white)
                                Text("Скоро в Walkie").wkFont(.caption, color: .white)
                            }.padding(16).frame(maxWidth: .infinity, minHeight: 170, alignment: .leading).background(WK.C.coral, in: RoundedRectangle(cornerRadius: 28))
                        }.buttonStyle(.plain) }
                        VStack(alignment: .leading, spacing: 12) {
                            WKIconBadge(icon: "cloud", bg: WK.C.sky.opacity(0.15), fg: WK.C.sky, size: 40)
                            Spacer(minLength: 0)
                            Text("Москва").wkFont(.h3)
                            Text("Погода пока недоступна").wkFont(.caption, color: WK.C.ink2)
                        }.padding(16).frame(maxWidth: .infinity, minHeight: 170, alignment: .leading).background(WK.C.surface, in: RoundedRectangle(cornerRadius: 28)).wkCardShadow()
                    }
                    HStack { Text("Недавние").wkFont(.h3); Spacer(); if let onOpenHistory { Button("Все", action: onOpenHistory).wkFont(.calloutS, color: WK.C.violet) } }
                    if recentRoutes.isEmpty {
                        Text("Твои прогулки будут здесь. Начнём с первой?").wkFont(.callout, color: WK.C.ink2).wkCard()
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(recentRoutes) { route in
                                    Button { Task { if await model.selectSavedRoute(route) { showsRoute = true } } } label: {
                                        HStack(spacing: 10) {
                                            Image("route-home-map").resizable().scaledToFill().frame(width: 44, height: 44).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
                                            VStack(alignment: .leading, spacing: 2) { Text(route.displayTitle).wkFont(.calloutS).lineLimit(2); Text("\(route.pois.count) мест").wkFont(.micro, color: WK.C.ink2) }
                                        }.padding(10).frame(width: 174, alignment: .leading).background(WK.C.surface, in: RoundedRectangle(cornerRadius: 22)).wkCardShadow()
                                    }.buttonStyle(.plain).accessibilityIdentifier("planning.lastRoute")
                                }
                            }.padding(.bottom, 8)
                        }
                    }
                    if let error = model.draftError { WKBanner(title: error, icon: "alert", kind: .error) }
                    if let error = model.errorMessage { WKBanner(title: error, icon: "alert", kind: .error) }
                }.padding(.horizontal, WK.S.screen).padding(.top, 8).padding(.bottom, 24)
            }.background(WK.C.canvas).toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showsRoute) {
                    if let plan = model.plan {
                        RouteReadyView(plan: plan, product: product, walk: walk, onStart: { showsRoute = false; onOpenWalk() },
                            onEdit: { showsRoute = false; showsBuilder = true }, planning: model)
                    }
                }
                .fullScreenCover(isPresented: $showsBuilder, onDismiss: {
                    // Update the home screen only after the builder transition ends.
                    showsDraftResume = model.draftExists
                    if opensRouteAfterBuilder { opensRouteAfterBuilder = false; showsRoute = true }
                }) {
                    RouteBuilderView(model: model, onClose: { showsBuilder = false }, onReady: {
                        opensRouteAfterBuilder = true
                        showsBuilder = false
                    })
                }
                .sheet(isPresented: $showsTogether) { TogetherPlaceholderView() }
                .sheet(isPresented: $showsNotifications) {
                    NavigationStack {
                        ContentUnavailableView("Пока нет уведомлений", systemImage: "bell", description: Text("Новости и приглашения появятся здесь после включения социальных функций."))
                            .background(WK.C.canvas).navigationTitle("Лента")
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showsNotifications = false } } }
                    }
                }.task {
                    await model.loadDraftIfNeeded()
                    showsDraftResume = model.draftExists
                    model.loadCachedPlan()
                    openRequestedBuilder()
                }
                .onChange(of: model.wantsBuilder) { _, wants in if wants { openRequestedBuilder() } }
                .onChange(of: socialEnabled) { _, enabled in if !enabled { showsTogether = false; showsNotifications = false } }
                .onChange(of: demoServerRoutes) { _, _ in model.startNewDraft() }
        }.tint(WK.C.violet).preferredColorScheme(.light).disabled(isForgettingDraft)
    }

    private func openRequestedBuilder() {
        guard model.wantsBuilder else { return }
        model.wantsBuilder = false
        showsBuilder = true
    }

    private func showWalkResumePrompt() {
        guard let record = walk.record, resumePrompts.insert(record.id.uuidString).inserted else { return }
        walk.coordinator.onProductEvent?("resume_prompt_shown", ["kind": "walk", "walk_id": record.id.uuidString,
            "route_id": record.route.routeID, "route_version_id": record.route.id])
    }

    private var recentRoutes: [RoutePlan] {
        var routes = model.plan.map { [$0] } ?? []
        routes += product.savedRoutes.filter { candidate in !routes.contains { $0.id == candidate.id } }
        return Array(routes.prefix(5))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { onOpenProfile?() } label: { WKAvatar(initials: String(product.profile.name.prefix(1)).uppercased(), userId: product.profile.name) }
                .buttonStyle(.plain).disabled(onOpenProfile == nil).accessibilityLabel("Открыть профиль")
            VStack(alignment: .leading, spacing: 2) {
                Text(product.profile.name.isEmpty ? "Привет!" : "Привет, \(product.profile.name)").wkFont(.h3)
                Text(Date.now.formatted(.dateTime.weekday(.wide))).wkFont(.caption, color: WK.C.ink2)
            }
            Spacer()
            if socialEnabled { WKCircleButton(icon: "bell", accessibilityLabel: "Уведомления") { showsNotifications = true } }
        }.frame(minHeight: 52)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer(minLength: 30)
            HStack(spacing: 6) { WKIcon(name: "bolt", size: 14); Text("≈ 1 минута").wkFont(.micro) }.padding(.horizontal, 10).padding(.vertical, 6).background(WK.C.lime, in: RoundedRectangle(cornerRadius: 12))
            Text("Создать\nпрогулку").wkFont(.display, color: .white)
            Text("Подберём места под твои интересы, время и погоду").wkFont(.callout, color: .white)
            WKButton(title: "Поехали", kind: .lime, icon: "play", fullWidth: false) { model.startNewDraft(); showsBuilder = true }
                .disabled(walk.hasOpenSession).accessibilityIdentifier("planning.generate")
        }.padding(20).frame(maxWidth: .infinity, minHeight: 290, alignment: .leading)
            .background {
                GeometryReader { geometry in
                    WK.C.violet.overlay { Image("route-home-map").resizable().scaledToFill().frame(width: geometry.size.width, height: 852).offset(y: -120).opacity(0.22) }
                        .overlay { Image("route-home-line").resizable().scaledToFill().opacity(0.22) }.clipped()
                }
            }.clipShape(RoundedRectangle(cornerRadius: 32))
    }
}

struct DemoInfoView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Локальные примеры Walkie").wkFont(.h1)
                    Text("Демонстрационный каталог содержит две прогулки по Москве. Подпись «Демо» отличает их от маршрутов сервера. Условные линии и оценка времени не являются проверенной пешеходной навигацией.").wkFont(.body, color: WK.C.ink2)
                    Text("Геопозиция, посещения и исследовательские логи остаются на телефоне. Старт и финиш отправляются только при подтверждении построения.").wkFont(.body, color: WK.C.ink2)
                }.padding(24)
            }.background(WK.C.canvas).navigationTitle("О приложении").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }.preferredColorScheme(.light)
    }
}

struct TogetherPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                WKIconBadge(icon: "users", bg: WK.C.coralSoft, fg: WK.C.coral, size: 84)
                Text("Прогулка — общая").wkFont(.h1)
                Text("Совместные маршруты пока выключены в пилоте. Здесь появятся выбор друзей и голосование за маршрут.").wkFont(.body, color: WK.C.ink2)
                Spacer(); WKButton(title: "Вернуться") { dismiss() }
            }.padding(24).background(WK.C.canvas).navigationTitle("Гулять вместе").navigationBarTitleDisplayMode(.inline)
        }.preferredColorScheme(.light)
    }
}
