import CoreLocation
import MapKit
import SwiftUI
import WalkieCore

struct RouteBuilderView: View {
    @ObservedObject var model: PlanningViewModel
    var onClose: () -> Void
    var onReady: () -> Void
    @StateObject private var location = RouteLocationPickerModel()
    @State private var position: MapCameraPosition = .region(.init(center: .init(latitude: 55.76519, longitude: 37.63809), span: .init(latitudeDelta: 0.012, longitudeDelta: 0.012)))
    @State private var query = ""
    @State private var customTime = false
    @State private var finishOnMap = false
    @State private var selectedOptions: Set<String> = []
    @State private var generationStarted = Date()
    @State private var showsLocationExplanation = false
    @State private var locationPermissionOutcome: WalkPermissionsOutcome?
    @State private var questionShownAt = Date()
    @State private var mapCenter = Coordinate(latitude: 55.76519, longitude: 37.63809)
    @State private var pinPosition: CGPoint?
    @AppStorage("walkie.localDemo") private var localDemo = false
    @AppStorage("walkie.demoServerRoutes") private var demoServerRoutes = false

    private var step: RouteBuilderStep { model.builderStep }
    private var isMapStep: Bool { [.origin, .finish, .budget].contains(step) }
    private var isSelectingPin: Bool { step == .origin || (step == .finish && finishOnMap) }
    private var usesLocalExamples: Bool {
        (localDemo || ProcessInfo.processInfo.environment["WALKIE_OFFLINE_DEMO"] == "1") && !demoServerRoutes
    }

    var body: some View {
        NavigationStack {
            ZStack {
                WK.C.canvas.ignoresSafeArea()
                if isMapStep { mapContent }
                else if step == .generation { generation }
                else { questionnaire }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { back() } label: { WKIcon(name: step == .origin ? "x" : "chev-l", size: 22) }
                        .disabled(model.isCommitting).accessibilityLabel(step == .origin ? "Закрыть" : "Назад")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { leaveQuestion("exit"); closeAfterSaving() } label: { WKIcon(name: "x", size: 20) }
                        .disabled(model.isCommitting).accessibilityLabel("Сохранить и закрыть")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) { if let error = model.draftError { WKBanner(title: error, icon: "alert", kind: .error).padding(.horizontal, 20) } }
            .task(id: step) {
                questionShownAt = Date()
                if isMapStep {
                    let point = step == .finish ? model.request.destination : model.request.origin
                    if let point { mapCenter = point; position = .region(.init(center: point.clLocation, span: .init(latitudeDelta: 0.012, longitudeDelta: 0.012))) }
                }
                selectedOptions = Set(model.request.context.answers[currentQuestionID] ?? [])
                if !isMapStep, step != .generation, step != .contextIntro { model.event("question_shown", ["questionnaire": "context", "question_id": step == .phrase ? "phrase" : currentQuestionID]) }
                if step == .generation {
                    generationStarted = Date()
                    if await model.generate() { onReady() }
                }
            }
            .onChange(of: location.coordinate) { _, coordinate in
                guard let coordinate else { return }
                selectCoordinate(coordinate, source: location.source, recenter: location.shouldRecenter)
            }
            .onChange(of: location.address) { _, address in
                guard let address else { return }
                if step == .origin, model.request.origin == location.coordinate { model.request.originTitle = address }
                if step == .finish, model.request.destination == location.coordinate { model.request.destinationTitle = address }
            }
            .onDisappear { if model.isLoading && !model.isCommitting { model.cancel() }; Task { await model.flushDraft() } }
            .sheet(isPresented: $showsLocationExplanation, onDismiss: {
                if locationPermissionOutcome == .ready { location.locateOnce() }
                locationPermissionOutcome = nil
            }) {
                WalkPermissionsFlowView(purpose: .routeOrigin) { outcome in
                    locationPermissionOutcome = outcome
                    showsLocationExplanation = false
                }
            }
        }.tint(WK.C.violet).preferredColorScheme(.light).interactiveDismissDisabled(model.isCommitting)
    }

    private var mapContent: some View {
        GeometryReader { available in
        MapReader { proxy in
            Map(position: $position, interactionModes: [.pan, .zoom]) {
                let point = step == .finish ? model.request.destination : (model.request.origin ?? RouteBuilderLocation.demoOrigin(for: model.request.startArea))
                if !isSelectingPin, let point {
                    Annotation(step == .finish ? "Финиш" : "Старт", coordinate: point.clLocation) {
                        WKIcon(name: step == .finish ? "flag" : "pin", size: 26, color: .white)
                            .padding(12).background(WK.C.violet, in: Circle()).overlay(Circle().strokeBorder(.white, lineWidth: 3))
                    }.annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .onMapCameraChange(frequency: .onEnd) { context in
                let center = context.camera.centerCoordinate
                mapCenter = .init(latitude: center.latitude, longitude: center.longitude)
                pinPosition = proxy.convert(center, to: .local)
                guard isSelectingPin, position.positionedByUser else { return }
                location.selectPin(mapCenter)
            }
            .onTapGesture { point in
                guard step == .origin || (step == .finish && finishOnMap), let coordinate = proxy.convert(point, from: .local) else { return }
                location.selectPin(.init(latitude: coordinate.latitude, longitude: coordinate.longitude), recenter: true)
            }
            .overlay {
                if isSelectingPin {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            WKIcon(name: step == .finish ? "flag" : "pin", size: 24, color: .white)
                                .frame(width: 48, height: 48).background(WK.C.violet, in: Circle())
                                .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                                .shadow(color: WK.C.ink.opacity(0.14), radius: 16, x: 0, y: 12)
                            RoundedRectangle(cornerRadius: 2).fill(WK.C.ink).frame(width: 4, height: 14)
                            Image("map-pin-foot").resizable().frame(width: 14, height: 6)
                        }.frame(width: 48, height: 68)
                            .position(x: pinPosition?.x ?? geometry.size.width / 2,
                                      y: (pinPosition?.y ?? (geometry.size.height - geometry.safeAreaInsets.bottom) / 2) - 31)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .overlay(alignment: .top) {
                if step == .origin || (step == .finish && finishOnMap) {
                    VStack(spacing: 8) {
                        HStack {
                            WKIcon(name: "search", size: 18, color: WK.C.ink3)
                            TextField("Поиск адреса", text: $query).wkFont(.body).submitLabel(.search).onSubmit { Task { await location.search(query) } }
                                .onChange(of: query) { _, value in location.updateSearch(value) }
                            if location.isSearching || location.isResolvingAddress { ProgressView() }
                        }.padding(14).background(WK.C.surface, in: Capsule()).wkCardShadow()
                        if !location.suggestions.isEmpty {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(location.suggestions.prefix(4).enumerated()), id: \.offset) { _, suggestion in
                                    Button {
                                        query = suggestion.title
                                        Task { await location.selectSuggestion(suggestion) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 2) { Text(suggestion.title).wkFont(.calloutS); Text(suggestion.subtitle).wkFont(.caption, color: WK.C.ink2) }
                                            .padding(12).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }.background(WK.C.surface, in: RoundedRectangle(cornerRadius: 20)).wkCardShadow()
                        }
                        if let error = location.error { Text(error).wkFont(.caption, color: WK.C.danger).padding(12).background(WK.C.surface, in: RoundedRectangle(cornerRadius: 16)) }
                    }.padding(.horizontal, 20).padding(.top, 8)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ViewThatFits(in: .vertical) {
                    mapControls
                    ScrollView { mapControls }
                        .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxWidth: .infinity, maxHeight: available.size.height * 0.62, alignment: .bottom)
                .background(WK.C.surface, in: UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32)).wkElevated()
            }
            .frame(width: available.size.width, height: available.size.height)
        }
        }
    }

    private var mapControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(WK.C.line).frame(width: 40, height: 5).frame(maxWidth: .infinity)
            WKStepper(current: step.rawValue)
            if step == .origin { originControls }
            if step == .finish { finishControls }
            if step == .budget { budgetControls }
            if let error = model.contextError { WKBanner(title: error, icon: "alert", kind: .error) }
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var originControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Откуда стартуем?").wkFont(.h2)
            HStack(spacing: 12) {
                WKIconBadge(icon: "nav", bg: WK.C.sky.opacity(0.15), fg: WK.C.sky, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(usesLocalExamples && model.request.origin == nil ? "Старт примера" : "Точка на карте").wkFont(.captionS, color: WK.C.ink2)
                    Text(model.request.originTitle ?? model.request.startArea).wkFont(.bodyS).lineLimit(2).accessibilityIdentifier("planning.originTitle")
                    if let point = model.request.origin { Text(String(format: "%.5f, %.5f", point.latitude, point.longitude)).wkFont(.caption, color: WK.C.ink2) }
                }
                Spacer()
                Button { locationPermissionOutcome = nil; showsLocationExplanation = true } label: { WKIcon(name: "locate", color: WK.C.violet) }
                    .accessibilityLabel("Моё местоположение, только по нажатию").accessibilityIdentifier("planning.locate")
            }.padding(14).background(WK.C.canvas, in: RoundedRectangle(cornerRadius: 20))
            if usesLocalExamples {
            Text("Примеры для локального демо").wkFont(.caption, color: WK.C.ink2)
            HStack {
                ForEach(RouteRequest.startAreas, id: \.self) { area in
                    Button { model.request.startArea = area; query = ""; location.selectPin(RouteBuilderLocation.demoOrigin(for: area), recenter: true); model.request.originTitle = area } label: {
                        WKChip(title: area, isSelected: model.request.startArea == area)
                    }.buttonStyle(.plain)
                }
            }
            }
            Text("Двигай карту, чтобы уточнить точку, или найди адрес. Координаты старта будут переданы при подтверждении параметров.").wkFont(.caption, color: WK.C.ink2)
            WKButton(title: "Подтвердить старт") { model.builderStep = .finish }.accessibilityIdentifier("planning.confirmOrigin")
        }
    }

    private var finishControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Где закончим?").wkFont(.h2)
            WKOptionCard(title: "Без конечной точки", icon: "route", isSelected: !finishOnMap) { finishOnMap = false; model.request.destination = nil; model.request.finishAtStart = false }
            Text("Маршрут закончится у последнего места").wkFont(.caption, color: WK.C.ink2)
            WKOptionCard(title: "Указать на карте", icon: "flag", isSelected: finishOnMap) {
                finishOnMap = true
                selectCoordinate(mapCenter, recenter: false)
                location.selectPin(mapCenter)
            }
            if finishOnMap { Text(model.request.destinationTitle ?? "Двигай карту под пином, чтобы выбрать финиш. Возможность дойти проверит сервер.").wkFont(.caption, color: WK.C.ink2) }
            WKButton(title: "Далее") { model.builderStep = .budget }
                .disabled(finishOnMap && model.request.destination == nil).accessibilityIdentifier("planning.confirmFinish")
        }.onAppear { finishOnMap = model.request.destination != nil }
    }

    private var budgetControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Сколько есть времени?").wkFont(.h2)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach([60, 90, 120, 180], id: \.self) { minutes in
                    Button { customTime = false; model.request.durationMinutes = minutes } label: {
                        Text(duration(minutes)).wkFont(.bodyS, color: !customTime && model.request.durationMinutes == minutes ? .white : WK.C.ink)
                            .frame(maxWidth: .infinity, minHeight: 56)
                            .background(!customTime && model.request.durationMinutes == minutes ? WK.C.ink : WK.C.canvas, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                }
            }
            Button { customTime.toggle() } label: { HStack { WKIcon(name: "sliders", size: 18); Text("Своё").wkFont(.bodyS) }.frame(maxWidth: .infinity, minHeight: 56).background(WK.C.canvas, in: RoundedRectangle(cornerRadius: 18)) }.buttonStyle(.plain)
            if customTime {
                Stepper(duration(model.request.durationMinutes), value: $model.request.durationMinutes, in: 30...240, step: 15).wkFont(.h3)
                Slider(value: Binding(get: { Double(model.request.durationMinutes) }, set: { model.request.durationMinutes = Int($0) }), in: 30...240, step: 15)
                HStack { Text("30 мин"); Spacer(); Text("4 часа") }.wkFont(.caption, color: WK.C.ink2)
            }
            Text("Время старта — сейчас. При построении сервер проверит часы работы мест.").wkFont(.caption, color: WK.C.ink2)
            WKButton(title: model.isPreparingContext ? "Сохраняем…" : "Далее") { Task { _ = await model.prepareContext() } }
                .disabled(model.isPreparingContext).accessibilityIdentifier("planning.confirmBudget")
        }
    }

    private var currentQuestionID: String {
        switch step { case .purpose: return "K2"; case .energy: return "K3"; case .interests: return "K4"; case .coffee: return "K5"; default: return "K1" }
    }

    private var questionnaire: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WKProgressBar(step: step == .company ? 1 : max(1, step.rawValue - 3), total: 5, color: WK.C.lime,
                              label: step == .company || step == .phrase ? "Про эту прогулку" : "Вопрос \(max(1, step.rawValue - 4)) из 4")
                if step == .contextIntro {
                    WKIconBadge(icon: "sparkles", size: 72)
                    Text("4 вопроса про эту прогулку").wkFont(.h1)
                    Text("Около 20 секунд. Про настроение, силы, интересы и остановки.").wkFont(.body, color: WK.C.ink2)
                    WKButton(title: "Начать") { model.builderStep = .purpose }
                } else if step == .phrase { phraseControls }
                else if let question = model.contextQuestions.first(where: { $0.id == currentQuestionID }) {
                    Text(question.id + (question.required ? " · ОБЯЗАТЕЛЬНЫЙ" : "")).wkFont(.micro).padding(.horizontal, 10).padding(.vertical, 4).background(WK.C.lime, in: Capsule())
                    Text(question.title).wkFont(.h1).fixedSize(horizontal: false, vertical: true)
                    if question.id == "K1" {
                        HStack(alignment: .top, spacing: 10) {
                            ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                                Button { answer(question, choices: [option.id]) } label: {
                                    VStack(spacing: 12) {
                                        WKIconBadge(icon: index == 0 ? "user" : "users", bg: WK.C.surface, fg: index == 0 ? WK.C.violet : (index == 1 ? WK.C.coral : WK.C.mint), size: 56, radius: 20)
                                        Text(option.title).wkFont(.bodyS).multilineTextAlignment(.center)
                                    }.padding(8).frame(maxWidth: .infinity, minHeight: 170).background(index == 0 ? WK.C.violetSoft : (index == 1 ? WK.C.coralSoft : WK.C.mintSoft), in: RoundedRectangle(cornerRadius: 28))
                                }.buttonStyle(.plain).disabled(model.isPreparingContext).accessibilityIdentifier("planning.context.K1.\(option.id)")
                            }
                        }
                    } else {
                        ForEach(question.options) { option in
                            WKOptionCard(title: option.title + (option.isNew == true || option.tag == "new" ? " · новое" : ""), isSelected: selectedOptions.contains(option.id), isMulti: question.type == "multi") {
                                if question.type == "multi" {
                                    if selectedOptions.contains(option.id) { selectedOptions.remove(option.id) }
                                    else if selectedOptions.count < (question.maxChoices ?? 2) { selectedOptions.insert(option.id) }
                                } else { answer(question, choices: [option.id]) }
                            }.disabled(model.isPreparingContext).accessibilityIdentifier("planning.context.\(question.id).\(option.id)")
                        }
                        if question.type == "multi" {
                            WKButton(title: "Далее") { answer(question, choices: selectedOptions.sorted()) }
                                .disabled(selectedOptions.count < (question.minChoices ?? 1) || model.isPreparingContext).accessibilityIdentifier("planning.context.next")
                        }
                    }
                    if !question.required { Button("Пропустить") { answer(question, choices: nil) }.wkFont(.caption, color: WK.C.ink3).frame(maxWidth: .infinity, minHeight: 44).disabled(model.isPreparingContext).accessibilityIdentifier("planning.context.skip") }
                } else { WKBanner(title: "Не удалось загрузить вопрос", message: "Вернись к времени и повтори загрузку.", icon: "alert", kind: .error) }
                if model.isPreparingContext { ProgressView().frame(maxWidth: .infinity) }
                if let error = model.contextError { WKBanner(title: error, icon: "alert", kind: .error) }
                if let error = model.draftError { WKBanner(title: error, icon: "alert", kind: .error) }
            }.padding(20)
        }
    }

    private var phraseControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ОДНОЙ ФРАЗОЙ").wkFont(.micro).padding(8).background(WK.C.lime, in: Capsule())
            Text("Расскажи одной фразой, какой будет прогулка").wkFont(.h1)
            TextField("Например: спокойно погулять вдвоём и выпить кофе", text: $model.request.context.phrase, axis: .vertical)
                .lineLimit(4...5).wkFont(.body).padding(16).background(WK.C.surface, in: RoundedRectangle(cornerRadius: 24))
                .onChange(of: model.request.context.phrase) { _, value in if value.count > 140 { model.request.context.phrase = String(value.prefix(140)) } }
            Text("\(model.request.context.phrase.count)/140").wkFont(.caption, color: WK.C.ink3)
            Text("Примеры — нажми, чтобы вставить").wkFont(.caption, color: WK.C.ink2)
            ForEach(["спокойно погулять вдвоём и выпить кофе", "показать друзьям центр, без музеев", "быстро размяться у дома"], id: \.self) { text in
                Button { model.request.context.phrase = text; model.request.context.phraseFromChip = true } label: {
                    HStack { WKIcon(name: "sparkles", size: 16, color: WK.C.violet); Text(text).wkFont(.calloutS).multilineTextAlignment(.leading) }.padding(12).background(WK.C.surface, in: Capsule())
                }.buttonStyle(.plain)
            }
            WKButton(title: "Готово") { model.request.context.phraseSkipped = false; leaveQuestion("answered"); model.builderStep = .generation }
                .disabled(model.request.context.phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Пропустить") { model.request.context.phraseSkipped = true; leaveQuestion("skipped"); model.builderStep = .generation }
                .wkFont(.caption, color: WK.C.ink3).frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var generation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ZStack {
                    Circle().stroke(WK.C.violet.opacity(0.1), lineWidth: 1).frame(width: 270, height: 270)
                    Circle().stroke(WK.C.violet.opacity(0.2), lineWidth: 1).frame(width: 220, height: 220)
                    Image("route-home-map").resizable().scaledToFill().frame(width: 170, height: 170).clipped().clipShape(Circle())
                    if model.isLoading { ProgressView().tint(WK.C.violet).scaleEffect(1.5) }
                }.frame(maxWidth: .infinity)
                if let error = model.errorMessage {
                    Text("Не получилось собрать маршрут").wkFont(.h1)
                    WKBanner(title: error, message: "Ответы анкеты сохранены", icon: "alert", kind: .error)
                    WKButton(title: "Повторить") { Task { generationStarted = Date(); if await model.generate() { onReady() } } }
                    WKButton(title: "Изменить параметры", kind: .secondary) { model.builderStep = .origin }
                } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.generationLongWaitVisible ? "Почти готово" : "Собираем маршрут…").wkFont(.h1)
                            Text("Обычно это меньше минуты").wkFont(.body, color: WK.C.ink2)
                        }
                    ForEach(Array(["Подбор мест", "Проверка часов работы", "Порядок и темп", "Пешеходная линия"].enumerated()), id: \.offset) { index, title in
                        let current = RouteGenerationProgress.stages.firstIndex(of: model.generationProgress?.stage ?? "") ?? 0
                        HStack { WKIcon(name: index < current ? "check" : "clock", size: 20, color: index < current ? WK.C.mint : WK.C.ink3); Text(title).wkFont(.body, color: WK.C.ink2) }
                    }
                    if let count = model.generationProgress?.candidatesFound { Text("Найдено мест рядом: \(count)").wkFont(.caption, color: WK.C.ink2) }
                    WKButton(title: "Отменить", kind: .secondary) { model.cancel(); model.builderStep = .budget }.disabled(model.isCommitting)
                }
            }.padding(24)
        }.task {
            while !Task.isCancelled, model.builderStep == .generation {
                await model.refreshGenerationProgress()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func answer(_ question: RouteContextQuestion, choices: [String]?) {
        Task {
            guard await model.answerContext(question.id, choices: choices, timeOnScreenMS: max(0, Int(Date().timeIntervalSince(questionShownAt) * 1_000))) else { return }
            if question.id == "K1" {
                switch model.contextBranch { case .c0: model.builderStep = .generation; case .c1: model.builderStep = .contextIntro; case .c2: model.builderStep = .phrase }
            } else { model.builderStep = RouteBuilderStep(rawValue: step.rawValue + 1) ?? .generation; if question.id == "K5" { model.builderStep = .generation } }
        }
    }

    private func selectCoordinate(_ coordinate: Coordinate, source: String = "map_pin", recenter: Bool = true) {
        if step == .finish { model.request.destination = coordinate; model.request.destinationTitle = location.address }
        else {
            model.request.origin = coordinate
            model.request.originSource = source
            model.request.originTitle = source == "current_location" ? "Моё местоположение" : (source == "address_search" ? query : "Точка на карте")
        }
        if recenter { position = .region(.init(center: coordinate.clLocation, span: .init(latitudeDelta: 0.012, longitudeDelta: 0.012))) }
    }

    private func back() {
        leaveQuestion("back")
        if step == .origin { closeAfterSaving() }
        else if step == .company || step == .generation { model.cancel(); model.builderStep = .budget }
        else if step == .phrase || step == .contextIntro { model.builderStep = .company }
        else { model.builderStep = RouteBuilderStep(rawValue: step.rawValue - 1) ?? .origin }
    }
    private func closeAfterSaving() { Task { if await model.flushDraft() { onClose() } } }
    private func leaveQuestion(_ action: String) {
        guard !isMapStep, step != .generation, step != .contextIntro else { return }
        model.event("question_left", ["questionnaire": "context", "question_id": step == .phrase ? "phrase" : currentQuestionID,
            "action": action, "time_on_screen_ms": String(max(0, Int(Date().timeIntervalSince(questionShownAt) * 1_000)))])
    }
    private func duration(_ minutes: Int) -> String { minutes % 60 == 0 ? "\(minutes / 60) ч" : "\(minutes / 60) ч \(minutes % 60) мин" }
}

@MainActor
final class RouteLocationPickerModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published var coordinate: Coordinate?
    @Published var error: String?
    @Published var isSearching = false
    @Published var suggestions: [MKLocalSearchCompletion] = []
    @Published private(set) var address: String?
    @Published private(set) var isResolvingAddress = false
    private(set) var source = "map_pin"
    private(set) var shouldRecenter = true
    private var locationRequested = false
    private let manager = CLLocationManager()
    private let completer = MKLocalSearchCompleter()
    private let reverseGeocoder: any RouteReverseGeocoding
    private var addressTask: Task<Void, Never>?
    private var selectionID = UUID()
    init(reverseGeocoder: (any RouteReverseGeocoding)? = nil) {
        self.reverseGeocoder = reverseGeocoder ?? AppleRouteReverseGeocoder()
        super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyBest
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = .init(center: .init(latitude: 55.75, longitude: 37.62), span: .init(latitudeDelta: 0.7, longitudeDelta: 0.7))
    }
    func selectPin(_ point: Coordinate, recenter: Bool = false) {
        guard point.isValid else { return }
        source = "map_pin"; shouldRecenter = recenter
        publishSelection(point)
    }
    private func publishSelection(_ point: Coordinate) {
        selectionID = UUID()
        let token = selectionID
        coordinate = point; address = nil; error = nil
        isResolvingAddress = true
        addressTask?.cancel()
        let resolver = reverseGeocoder
        addressTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                let title = try await resolver.address(for: point)
                guard !Task.isCancelled, self?.selectionID == token else { return }
                self?.address = title
                self?.isResolvingAddress = false
            } catch is CancellationError { }
            catch {
                guard self?.selectionID == token else { return }
                self?.isResolvingAddress = false
                self?.error = "Адрес определить не удалось. Выбранная точка сохранена; можно продолжить по координатам."
            }
        }
    }
    func updateSearch(_ value: String) { completer.queryFragment = value; if value.isEmpty { suggestions = [] } }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { suggestions = completer.results }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { suggestions = [] }
    func selectSuggestion(_ suggestion: MKLocalSearchCompletion) async {
        suggestions = []; source = "address_search"; shouldRecenter = true; isSearching = true
        defer { isSearching = false }
        do {
            let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion)).start()
            guard let place = response.mapItems.first else { error = "Адрес не найден. Укажи точку на карте."; return }
            publishSelection(.init(latitude: place.placemark.coordinate.latitude, longitude: place.placemark.coordinate.longitude))
            suggestions = []
        } catch { self.error = "Адрес не найден или нет сети. Укажи точку на карте." }
    }
    func locateOnce() {
        error = nil
        source = "current_location"
        shouldRecenter = true
        locationRequested = true
        if manager.authorizationStatus == .notDetermined { locationRequested = false; error = "Сначала разреши геопозицию на экране пояснения или выбери точку на карте." }
        else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted { error = "Разреши геопозицию в Настройках или выбери точку на карте." }
        else { manager.requestLocation() }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard locationRequested else { return }
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways { manager.requestLocation() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locationRequested else { return }
        locationRequested = false
        guard let value = locations.last else { return }
        publishSelection(.init(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude))
    }
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) { locationRequested = false; self.error = "Не удалось определить место. Выбери точку на карте." }
    func search(_ query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSearching = true; error = nil
        source = "address_search"
        shouldRecenter = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        request.region = .init(center: .init(latitude: 55.75, longitude: 37.62), span: .init(latitudeDelta: 0.7, longitudeDelta: 0.7))
        do {
            let response = try await MKLocalSearch(request: request).start()
            guard let place = response.mapItems.first else { error = "Адрес не найден. Укажи точку на карте."; return }
            publishSelection(.init(latitude: place.placemark.coordinate.latitude, longitude: place.placemark.coordinate.longitude))
        } catch { self.error = "Адрес не найден или нет сети. Укажи точку на карте." }
    }
}

extension Coordinate {
    var clLocation: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}
