import SwiftUI
import WalkieCore

@main
struct WalkieApp: App {
    var body: some Scene {
        WindowGroup {
            AccountContainerView()
                .tint(WK.C.violet)
                .preferredColorScheme(.light)
                .environment(\.locale, Locale(identifier: "ru_RU"))
        }
    }
}

/// Recreate stateful stores on identity changes; never reuse another account's caches.
private struct AccountContainerView: View {
    @State private var dependencies = AppDependencies()
    @State private var generation = UUID()
    @State private var forceLogin = false

    var body: some View {
        RootView(dependencies: dependencies, forceLogin: forceLogin) { profile, login in
            dependencies.planning.cancel()
            if dependencies.walk.record?.state == .recording { await dependencies.walk.pause() }
            let replacement = AppDependencies()
            await replacement.product.load()
            if let profile { _ = await replacement.product.saveProfile(profile) }
            dependencies = replacement
            forceLogin = login
            generation = UUID()
        }.id(generation)
    }
}

struct RootView: View {
    let dependencies: AppDependencies
    var onIdentityChanged: (UserProfile?, Bool) async -> Void
    @ObservedObject private var product: ProductViewModel
    @ObservedObject private var planning: PlanningViewModel
    @ObservedObject private var walk: WalkViewModel
    @ObservedObject private var account: AccountViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: WKTab = .route
    @State private var selectedRoute: RoutePlan?
    @State private var selectedStartKind: WalkStartKind = .regular
    @State private var showsPlanningRoute = false
    @State private var showsWalk = false
    @State private var requiresLogin = false
    @State private var showsFirstPro = false
    @State private var proWalkID: UUID?
    @State private var pendingHistoryWalk = false
    @AppStorage private var firstProShown: Bool

    init(dependencies: AppDependencies, forceLogin: Bool = false, onIdentityChanged: @escaping (UserProfile?, Bool) async -> Void = { _, _ in }) {
        self.dependencies = dependencies
        self.onIdentityChanged = onIdentityChanged
        _requiresLogin = State(initialValue: forceLogin)
        _firstProShown = AppStorage(wrappedValue: false, "walkie.firstProShown.\(dependencies.scopeID)")
        product = dependencies.product; planning = dependencies.planning
        walk = dependencies.walk; account = dependencies.account
    }

    var body: some View {
        Group {
            if !product.isLoaded {
                ProgressView("Walkie").frame(maxWidth: .infinity, maxHeight: .infinity).background(WK.C.canvas)
            } else if !product.profile.onboardingComplete || requiresLogin {
                OnboardingFlowView(forceLogin: requiresLogin, onEnvironmentSelected: { isDemo in
                    UserDefaults.standard.set(isDemo, forKey: "walkie.localDemo")
                }) { name, interests in
                    Task {
                        let profile = UserProfile(name: name, interests: interests, onboardingComplete: true)
                        if dependencies.scopeID != AppDependencies.currentScopeID() {
                            await onIdentityChanged(profile, false)
                        } else if await product.saveProfile(profile) { requiresLogin = false; await account.refresh() }
                    }
                }
            } else { mainTabs }
        }
        .environment(\.productTelemetry, dependencies.telemetry)
        .task {
            if !product.isLoaded { await product.load() }
            await walk.coordinator.restoreLatestSessionIfNeeded()
            await account.refresh()
            await dependencies.flushOutboxes()
            if product.profile.onboardingComplete && !account.hasSession && !UserDefaults.standard.bool(forKey: "walkie.localDemo") {
                requiresLogin = true
            }
        }
        .onChange(of: product.profile.interests) { _, interests in
            planning.updateProfileInterests(interests, walkIsActive: walk.hasOpenSession)
        }
        .onChange(of: account.hasSession) { wasSignedIn, signedIn in
            if wasSignedIn && !signedIn && !account.isOfflineDemo { requiresLogin = true }
        }
        .onChange(of: walk.hasOpenSession) { wasOpen, isOpen in
            dependencies.refreshConnectivity()
            if wasOpen && !isOpen {
                planning.walkDidFinish()
                Task { await dependencies.history.refresh() }
            }
        }
        .onReceive(account.$configuration) { configuration in
            if let configuration { dependencies.applyConfiguration(configuration) }
        }
        .onReceive(dependencies.$pendingProOffer) { id in
            if let id, !showsWalk, !walk.hasOpenSession, !showsPlanningRoute, selectedRoute == nil,
               !planning.draftExists, tab == .route, !requiresLogin, product.profile.onboardingComplete { proWalkID = id; showsFirstPro = true }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await dependencies.flushOutboxes() } }
        }
        .onChange(of: tab) { _, selected in if selected == .route { Task { await dependencies.flushOutboxes() } } }
    }
    private var mainTabs: some View {
        TabView(selection: $tab) {
            PlanningView(model: planning, walk: walk, product: product, onOpenWalk: { showsWalk = true }, showsRoute: $showsPlanningRoute, onOpenProfile: { tab = .profile }, onOpenHistory: { tab = .myRoutes }, socialEnabled: account.socialEnabled)
                .toolbar(.hidden, for: .tabBar)
                .tag(WKTab.route)
            MyRoutesView(product: product, history: dependencies.history) { route, kind in
                selectedStartKind = kind; selectedRoute = route
            }
                .toolbar(.hidden, for: .tabBar)
                .tag(WKTab.myRoutes)
            if account.socialEnabled {
                NavigationStack { ServiceUnavailableView(title: "Друзья", message: "Здесь появятся друзья и приглашения на совместные прогулки", icon: "users") }
                    .toolbar(.hidden, for: .tabBar)
                    .tag(WKTab.friends)
            }
            ProfileView(model: product, history: dependencies.history, account: account, onSignOut: {
                Task { await onIdentityChanged(nil, true) }
            })
                .toolbar(.hidden, for: .tabBar)
                .tag(WKTab.profile)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !showsPlanningRoute { ProductTabBar(selection: $tab, socialEnabled: account.socialEnabled).padding(.bottom, 6) }
        }
        .fullScreenCover(isPresented: $showsWalk, onDismiss: {
            Task {
                await dependencies.history.refresh()
                await dependencies.flushOutboxes()
                if dependencies.scopeID == "demo", !firstProShown && !walk.hasOpenSession && walk.summaryDecisionMade {
                    firstProShown = true; showsFirstPro = true
                } else if !walk.hasOpenSession, let id = dependencies.pendingProOffer { proWalkID = id; showsFirstPro = true }
            }
        }) {
            NavigationStack {
                WalkView(model: walk, planning: planning, onChooseRoute: { showsWalk = false; tab = .route })
                    .toolbar { ToolbarItem(placement: .topBarLeading) { Button { showsWalk = false } label: { WKIcon(name: "chev-l") }.accessibilityLabel("Свернуть прогулку") } }
            }
        }
        .sheet(item: $selectedRoute, onDismiss: {
            if pendingHistoryWalk { pendingHistoryWalk = false; showsWalk = true }
            else { Task { await dependencies.flushOutboxes() } }
        }) { route in
            NavigationStack {
                RouteReadyView(plan: route, product: product, walk: walk, onStart: { pendingHistoryWalk = true; selectedRoute = nil }, onEdit: { selectedRoute = nil; tab = .route }, editTitle: "Создать другую прогулку", planning: planning, startKind: selectedStartKind)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Закрыть") { selectedRoute = nil } } }
            }
        }
        .sheet(isPresented: $showsFirstPro) {
            ProIntentView(account: account, entry: "first_walk")
                .onAppear { if let id = proWalkID { Task { await dependencies.markProOfferShown(id) } } }
        }
    }
}

struct ProductTabBar: View {
    @Binding var selection: WKTab
    let socialEnabled: Bool
    private var tabs: [WKTab] { WKTab.allCases.filter { socialEnabled || $0 != .friends } }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 3) {
                        WKIcon(name: tab.icon, size: 24, color: selection == tab ? WK.C.violet : WK.C.ink2)
                        Text(tab.title).wkFont(.micro, color: selection == tab ? WK.C.violet : WK.C.ink2)
                    }.frame(maxWidth: .infinity).frame(height: 52)
                        .background(selection == tab ? WK.C.violetSoft : .clear, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("tab.\(tab.rawValue)")
                    .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }.padding(6).wkGlass(Capsule()).padding(.horizontal, 16)
    }
}

struct MyRoutesView: View {
    @ObservedObject var product: ProductViewModel
    @ObservedObject var history: HistoryViewModel
    var onSelect: (RoutePlan, WalkStartKind) -> Void
    @State private var selection = 0
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Мои маршруты").wkFont(.h1).padding(.top, 16)
                    Text("История хранится на этом устройстве отдельно для деморежима и каждого аккаунта.")
                        .wkFont(.caption, color: WK.C.ink2)
                    Picker("Маршруты", selection: $selection) { Text("Все").tag(0); Text("Завершённые").tag(1); Text("Сохранённые").tag(2) }.pickerStyle(.segmented)
                    if selection == 2 {
                        if product.savedRoutes.isEmpty { empty }
                        ForEach(product.savedRoutes) { route in routeCard(route, subtitle: "Сохранённый маршрут") }
                    } else {
                        let sessions = history.sessions.filter { selection != 1 || $0.state == .finished }
                        if sessions.isEmpty { empty }
                        ForEach(sessions) { session in
                            NavigationLink { WalkHistoryDetailView(session: session, model: history) } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(session.route.displayTitle).wkFont(.h3)
                                    HStack { WKChip(title: "\(session.route.pois.count) мест", icon: "pin"); Spacer(); Text(session.state == .finished ? "Завершена" : "Прервана").wkFont(.captionS, color: WK.C.ink2) }
                                    Text(session.startedAt, style: .date).wkFont(.caption, color: WK.C.ink2)
                                }.wkCard()
                            }.buttonStyle(.plain).accessibilityIdentifier("history.session")
                            Button("Пройти снова") { onSelect(session.route, .repeat) }.wkFont(.calloutS, color: WK.C.violet)
                        }
                    }
                }.padding(20).padding(.bottom, 20)
            }.background(WK.C.canvas).toolbar(.hidden, for: .navigationBar)
                .task { await history.refresh() }.refreshable { await history.refresh() }
        }
    }
    private var empty: some View {
        VStack(spacing: 16) { WKIconBadge(icon: "map", size: 72); Text("Первый маршрут впереди").wkFont(.h2); Text("Создай прогулку — здесь появятся маршрут и история").wkFont(.body, color: WK.C.ink2).multilineTextAlignment(.center) }.padding(.vertical, 60).frame(maxWidth: .infinity)
    }
    private func routeCard(_ route: RoutePlan, subtitle: String) -> some View {
        Button { onSelect(route, history.sessions.contains(where: { $0.route.routeID == route.routeID }) ? .repeat : .regular) } label: {
            VStack(alignment: .leading, spacing: 12) { Text(route.displayTitle).wkFont(.h3); Text(route.pois.map(\.name).joined(separator: " → ")).wkFont(.caption, color: WK.C.ink2); WKChip(title: "\(route.pois.count) мест", icon: "pin") }.frame(maxWidth: .infinity, alignment: .leading).wkCard()
        }.buttonStyle(.plain)
    }
}
