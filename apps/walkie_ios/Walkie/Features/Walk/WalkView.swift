import SwiftUI
import UIKit
import WalkieCore

struct WalkView: View {
    @ObservedObject var model: WalkViewModel
    @ObservedObject var planning: PlanningViewModel
    var onChooseRoute: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var showsPlaces = false
    @State private var visitedName = ""
    @State private var deviationDismissed = false
    @State private var showsNewRouteConfirmation = false
    @State private var deviationActionTaken = false
    private var plan: RoutePlan? { model.displayedPlan(fallback: planning.plan) }

    var body: some View {
        NavigationStack {
            Group {
                if let record = model.record, model.showsSummary {
                    WalkSummaryView(record: record, model: model, onDone: { dismiss() })
                } else if let plan { liveMap(plan) }
                else {
                    VStack(spacing: 20) {
                        WKIconBadge(icon: "route", bg: WK.C.violetSoft, size: 80)
                        Text("Город ждёт").wkFont(.h1)
                        Text("Соберите маршрут и отправляйтесь на прогулку.").wkFont(.body, color: WK.C.ink2)
                        WKButton(title: "Создать прогулку", action: onChooseRoute).accessibilityIdentifier("walk.chooseRoute")
                    }.padding(24)
                }
            }.background(WK.C.canvas).toolbar(.hidden, for: .navigationBar)
                .sheet(isPresented: $model.showsWalkMenu) { walkMenu }
                .sheet(isPresented: $showsPlaces) { placesSheet }
                .sheet(isPresented: $model.showsObserver) { ResearchObserverView(coordinator: model.coordinator) }
                .sheet(isPresented: $model.showsVisitConfirmation) { visitSheet }
                .sheet(isPresented: $model.showsShare) { WalkShareSheet(urls: model.exportFiles) }
                .confirmationDialog("Завершить прогулку?", isPresented: $model.showsFinishConfirmation, titleVisibility: .visible) {
                    if model.canComplete { Button("Завершить и сохранить") { Task { await model.complete() } } }
                    Button("Прервать и сохранить", role: .destructive) { Task { await model.interrupt() } }
                    Button("Продолжить прогулку", role: .cancel) {}
                } message: { Text("Отметки сохранятся на iPhone. Неотмеченные и пропущенные места не считаются посещёнными.") }
                .alert("Локальный возврат", isPresented: $model.showsReturnStub) {
                    Button("Понятно", role: .cancel) {}
                } message: {
                    Text("Исходная линия и оставшиеся места доступны на карте без отправки GPS. Пешеходный граф для локального расчёта пути возврата ещё не загружен.")
                }
                .confirmationDialog("Сохранить прогулку и собрать новую?", isPresented: $showsNewRouteConfirmation, titleVisibility: .visible) {
                    Button("Сохранить и выбрать новый маршрут") {
                        Task { await model.interrupt(); onChooseRoute(); dismiss() }
                    }
                    Button("Продолжить прогулку", role: .cancel) {}
                } message: { Text("GPS автоматически не отправляется. Старт нового маршрута вы выберете сами.") }
                .onChange(of: model.coordinator.guidanceState) { _, state in
                    if state == .onRoute { deviationDismissed = false }
                }
                .onChange(of: model.coordinator.automaticVisitNotice?.id) { _, _ in
                    guard model.hasOpenSession, !model.coordinator.researchActive,
                          let notice = model.coordinator.automaticVisitNotice else { return }
                    visitedName = notice.poi.name
                    model.showsVisitConfirmation = true
                }
                .onChange(of: model.showsSummary) { _, closed in
                    if closed { model.showsVisitConfirmation = false; model.showsWalkMenu = false }
                }
        }
    }

    private func liveMap(_ plan: RoutePlan) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            ZStack {
                RouteMapView(plan: plan, observation: model.record?.state == .recording ? model.coordinator.latestObservation : nil,
                    visitedPOIIDs: model.visitedIDs(for: plan), selectedPOIID: model.nextPlace(in: plan)?.id).ignoresSafeArea()
                VStack(spacing: 12) {
                    nextPlace(plan)
                    if let error = model.coordinator.errorMessage { WKBanner(title: "Запись остановлена", message: error, kind: .error) }
                    if let message = model.coordinator.recoveryMessage { WKBanner(title: "Прогулка восстановлена", message: message, kind: .info) }
                    if model.coordinator.researchActive {
                        Text("Исследовательская запись · решения A / B1 скрыты").wkFont(.captionS).padding(10).wkGlass(radius: 18)
                    }
                    if model.hasOpenSession, !model.coordinator.researchActive,
                       model.coordinator.guidanceState == .offRoute, !deviationDismissed { deviationBanner }
                    Spacer(minLength: 20)
                    walkPanel(plan)
                }.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
            }
        }
    }

    private var deviationBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Кажется, маршрут остался в стороне").wkFont(.bodyS)
            Text("GPS может ошибаться. Вы можете свободно отойти и продолжить прогулку.").wkFont(.caption, color: WK.C.ink2)
            WKButton(title: "Вернуть на маршрут", kind: .primary) { deviationActionTaken = true; model.requestReturnToPreviousRoute() }
            WKButton(title: "Собрать новый маршрут", kind: .tinted) { deviationActionTaken = true; model.reaction("reroute"); showsNewRouteConfirmation = true }
            HStack {
                Button("Я на маршруте") { deviationActionTaken = true; model.reaction("on_route"); deviationDismissed = true }
                Spacer()
                Button("Не беспокоить") { deviationActionTaken = true; model.reaction("mute"); deviationDismissed = true }
            }.wkFont(.captionS, color: WK.C.violet)
        }.padding(16).wkGlass(radius: 28).accessibilityIdentifier("walk.deviation")
            .onAppear { deviationActionTaken = false }
            .onDisappear { if !deviationActionTaken { model.reaction("none") } }
    }

    private func nextPlace(_ plan: RoutePlan) -> some View {
        HStack(spacing: 12) {
            WKIconBadge(icon: "nav", bg: WK.C.violet, fg: .white, size: 52, radius: 18)
            Button { showsPlaces = true } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.record?.state == .paused ? "Прогулка на паузе" : "Следующая точка").wkFont(.captionS, color: WK.C.ink2)
                    Text(model.nextPlace(in: plan)?.name ?? "Все места просмотрены").wkFont(.bodyS).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.distanceToNext(in: plan)).wkFont(.h3, color: WK.C.violet)
                Text("по прямой").wkFont(.caption, color: WK.C.ink2)
            }
        }.padding(12).wkGlass(radius: 28)
    }

    private func walkPanel(_ plan: RoutePlan) -> some View {
        VStack(spacing: 14) {
            HStack {
                Text("\(model.visitedIDs(for: plan).count) из \(plan.pois.count) мест").wkFont(.h3)
                Spacer()
                Text(model.hasOpenSession ? "прошло \(model.elapsedText)" : "Готовы к прогулке?").wkFont(.captionS, color: WK.C.ink2)
            }
            HStack(spacing: 4) {
                ForEach(plan.pois) { place in
                    Capsule().fill(model.visitedIDs(for: plan).contains(place.id) ? WK.C.mint
                        : model.nextPlace(in: plan)?.id == place.id ? WK.C.violet : WK.C.sunken).frame(height: 8)
                }
            }
            HStack(spacing: 8) {
                stat("steps", model.coordinator.latestMotion.map { "\($0.steps)" } ?? "—", "шагов¹")
                stat("pin", "\(model.visitedIDs(for: plan).count)", "отмечено")
                stat("clock", model.elapsedText, "с паузами")
            }
            if !model.hasOpenSession {
                Toggle("Пилот дипломного исследования", isOn: Binding(get: { model.coordinator.researchEnabled }, set: { model.coordinator.researchEnabled = $0 }))
                    .wkFont(.captionS).tint(WK.C.violet).accessibilityIdentifier("walk.researchOptIn")
                if model.coordinator.researchEnabled {
                    Text("Согласие на локальную запись GPS и шагов. Наблюдатель размечает положение по местности. Экспорт — по вашей команде.")
                        .wkFont(.caption, color: WK.C.ink2)
                }
                WKButton(title: "Начать прогулку", icon: "play") { Task { await model.start(route: plan) } }
                    .disabled(model.isBusy || model.coordinator.storageUnavailable).accessibilityIdentifier("walk.start")
            } else {
                if let next = model.nextPlace(in: plan) {
                    WKButton(title: "Я здесь", icon: "check") {
                        Task {
                            await model.markVisited(next)
                            if model.hasOpenSession, model.visitedIDs(for: plan).contains(next.id) { visitedName = next.name; model.showsVisitConfirmation = true }
                        }
                    }.disabled(model.record?.state != .recording || model.isBusy).accessibilityIdentifier("walk.visitNext")
                }
                HStack(spacing: 10) {
                    if model.record?.state == .paused {
                        WKButton(title: model.coordinator.researchRecoveryReadOnly ? "Закрыть запись" : "Продолжить", kind: .secondary, icon: "play") {
                            if model.coordinator.researchRecoveryReadOnly { model.showsFinishConfirmation = true }
                            else { Task { await model.resume() } }
                        }.accessibilityIdentifier("walk.resume")
                    } else if let next = model.nextPlace(in: plan) {
                        WKButton(title: "Пропустить точку", kind: .secondary, icon: "skip") { Task { await model.skip(next) } }.accessibilityIdentifier("walk.skipNext")
                    } else { WKButton(title: "Завершить") { model.showsFinishConfirmation = true } }
                    Button { model.showsWalkMenu = true } label: {
                        WKIcon(name: "more", size: 22, color: .white).frame(width: 56, height: 56)
                    }.background(WK.C.ink, in: Circle()).accessibilityLabel("Меню прогулки").accessibilityIdentifier("walk.menu")
                }.disabled(model.isBusy)
            }
            HStack {
                Text("GPS и отметки — на этом iPhone")
                Spacer()
                Button("Свернуть") { dismiss() }.accessibilityIdentifier("walk.collapse")
            }.wkFont(.micro, color: WK.C.ink2)
        }.padding(16).wkGlass(radius: 32)
    }

    private func stat(_ icon: String, _ value: String, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) { WKIcon(name: icon, size: 14, color: WK.C.violet); Text(value).wkFont(.calloutS).lineLimit(1).minimumScaleFactor(0.7) }
            Text(title).wkFont(.micro, color: WK.C.ink2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            .background(WK.C.surface, in: RoundedRectangle(cornerRadius: 18))
    }

    private var walkMenu: some View {
        NavigationStack {
            List {
                Section {
                    Button(model.record?.state == .paused ? "Продолжить прогулку" : "Пауза") {
                        model.showsWalkMenu = false
                        Task { if model.record?.state == .paused { await model.resume() } else { await model.pause() } }
                    }.accessibilityIdentifier("walk.pause")
                    Button("Места маршрута") { model.showsWalkMenu = false; showsPlaces = true }
                    Button("Вернуться к линии маршрута") { model.showsWalkMenu = false; model.requestReturnToPreviousRoute() }.accessibilityIdentifier("walk.returnStub")
                    Button("Прервать прогулку", role: .destructive) { model.showsWalkMenu = false; model.showsFinishConfirmation = true }.accessibilityIdentifier("walk.finish")
                }
                if model.coordinator.researchActive {
                    Section("Для наблюдателя") {
                        Button("Разметка положения и намерения") { model.showsWalkMenu = false; model.showsObserver = true }
                        Text("Метки: \(model.coordinator.researchMarkerCount). Решения скрыты.").wkFont(.caption, color: WK.C.ink2)
                    }
                }
                Section("Геолокация и приватность") {
                    Text(model.coordinator.sensorStatus).accessibilityIdentifier("walk.locationStatus")
                    Text("¹ Шаги с последнего старта датчика. Нет данных — прочерк. Позиция iOS может ошибаться. Автоотметки используют радиус и время из маршрута, ручные отметки хранятся отдельно.")
                    if let deadline = model.coordinator.pauseTimeoutAt {
                        Text("Явная пауза: прогулка закроется незавершённой в \(deadline.formatted(date: .omitted, time: .shortened)). Возобновление до этого времени отменяет таймер.")
                    }
                    Button("Настройки геолокации") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                }.font(.footnote)
            }.navigationTitle("Меню прогулки").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { model.showsWalkMenu = false } } }
        }.presentationDetents([.medium, .large])
    }

    private var placesSheet: some View {
        NavigationStack {
            List {
                if let plan {
                    ForEach(Array(plan.pois.enumerated()), id: \.element.id) { index, place in
                        HStack(spacing: 12) {
                            WKIconBadge(icon: model.visitedIDs(for: plan).contains(place.id) ? "check" : "pin", size: 36)
                            VStack(alignment: .leading) {
                                Text("\(index + 1). \(place.name)").wkFont(.bodyS)
                                Text((model.record?.autoVisitedPOIIDs ?? []).contains(place.id) ? "Автоотметка по радиусу и времени"
                                    : model.visitedIDs(for: plan).contains(place.id) ? "Вы отметили посещение"
                                    : (model.record?.manualSkippedPOIIDs ?? []).contains(place.id) ? "Пропущено" : "В плане").wkFont(.caption, color: WK.C.ink2)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }.navigationTitle("Места маршрута").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { showsPlaces = false } } }
        }
    }

    private var visitSheet: some View {
        VStack(spacing: 18) {
            WKIconBadge(icon: "check", bg: WK.C.mintSoft, fg: WK.C.mint, size: 72)
            Text("Точка посещена").wkFont(.h1)
            Text(visitedName).wkFont(.body).multilineTextAlignment(.center)
            Text(model.coordinator.automaticVisitNotice?.poi.name == visitedName
                ? "Автоотметка по радиусу и времени · сохранена на телефоне" : "Ваша отметка сохранена на телефоне")
                .wkFont(.caption, color: WK.C.ink2)
            WKButton(title: plan.flatMap { model.nextPlace(in: $0) } == nil ? "К итогу прогулки" : "К следующему месту") {
                model.showsVisitConfirmation = false
                if model.hasOpenSession, plan.flatMap({ model.nextPlace(in: $0) }) == nil { model.showsFinishConfirmation = true }
            }
        }.padding(24).presentationDetents([.medium]).presentationDragIndicator(.visible)
    }
}

extension RecordingState {
    var displayName: String {
        switch self {
        case .recording: return "На прогулке"
        case .paused: return "На паузе"
        case .finished: return "Завершена"
        case .interrupted: return "Прервана"
        }
    }
}

struct WalkShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
