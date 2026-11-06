import CoreLocation
import MapKit
import SwiftUI
import WalkieCore

struct RouteReadyView: View {
    @StateObject private var preview: RoutePreviewViewModel
    private var plan: RoutePlan { preview.plan }
    @ObservedObject var product: ProductViewModel
    @ObservedObject var walk: WalkViewModel
    var onStart: () -> Void
    var onEdit: () -> Void
    var editTitle = "Изменить параметры"
    var planning: PlanningViewModel? = nil
    var onRouteChanged: (RoutePlan) -> Void
    var startKind: WalkStartKind
    @Environment(\.openURL) private var openURL
    @State private var selectedPlace: RoutePOI?
    @State private var showsCorrection = false
    @State private var showsEditMenu = false
    @State private var isRebuilding = false
    @State private var actionError: String?
    @State private var preparedShareText: String?
    @State private var showsShare = false
    @State private var loadedMetadata: LiveRouteDetails?
    @State private var showsPermissionGate = false
    @State private var permissionOutcome: WalkPermissionsOutcome?
    @State private var locationDeferred = false
    private var metadata: LiveRouteDetails? {
        if loadedMetadata?.versionID == plan.id { return loadedMetadata }
        return planning?.routeDetails?.versionID == plan.id ? planning?.routeDetails : nil
    }
    private var locationDenied: Bool { [.denied, .restricted].contains(CLLocationManager().authorizationStatus) }
    private var requiresExternalNavigation: Bool { locationDenied || locationDeferred }

    init(plan: RoutePlan, product: ProductViewModel, walk: WalkViewModel, onStart: @escaping () -> Void,
         onEdit: @escaping () -> Void, editTitle: String = "Изменить параметры", planning: PlanningViewModel? = nil,
         onRouteChanged: @escaping (RoutePlan) -> Void = { _ in }, startKind: WalkStartKind = .regular) {
        self.product = product; self.walk = walk; self.onStart = onStart; self.onEdit = onEdit
        self.editTitle = editTitle; self.planning = planning; self.onRouteChanged = onRouteChanged
        self.startKind = startKind
        let restoration: RoutePreviewRestoration = startKind == .repeat ? .exactVersion : .latestCardVersion
        _preview = StateObject(wrappedValue: planning?.previewModel(for: plan, restoration: restoration) ?? RoutePreviewViewModel(plan: plan, api: nil, restoration: restoration))
    }

    var body: some View {
        ZStack {
            ProductRouteMap(plan: plan)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Capsule().fill(WK.C.line).frame(width: 40, height: 5).frame(maxWidth: .infinity)
                Text("Маршрут готов").wkFont(.h1).accessibilityIdentifier("route.title")
                HStack(spacing: 8) {
                    WKChip(title: (metadata == nil ? "≈ " : "") + "\(Int((Double(metadata?.durationSeconds ?? plan.estimatedMinutes * 60) / 60).rounded(.up))) мин", icon: "clock", bg: WK.C.canvas)
                    WKChip(title: (metadata == nil ? "≈ " : "") + String(format: "%.1f км", Double(metadata?.distanceMeters ?? Int(plan.approximateDistanceMeters)) / 1_000), icon: "steps", bg: WK.C.canvas)
                    WKChip(title: "\(plan.pois.count) мест", icon: "pin", bg: WK.C.canvas)
                }
                if plan.isDemo { Text("Демо · условная линия, проходы не проверены").wkFont(.caption, color: WK.C.ink2) }
                if requiresExternalNavigation {
                    WKBanner(title: "Без геопозиции ведение недоступно", message: "Разреши доступ в Настройках или открой внешние карты.", icon: "locate", kind: .warning)
                    Button("Разрешить геопозицию") { permissionOutcome = nil; showsPermissionGate = true }.wkFont(.captionS, color: WK.C.violet)
                        .accessibilityIdentifier("route.permissions")
                }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(plan.pois.enumerated()), id: \.element.id) { index, poi in
                            Button { planning?.event("place_card_opened", ["route_id": plan.routeID, "place_id": poi.id, "from": "list"]); selectedPlace = poi } label: {
                                HStack(spacing: 12) {
                                    Text("\(index + 1)").wkFont(.captionS, color: .white).frame(width: 28, height: 28).background(WK.C.violet, in: Circle())
                                    WKIconBadge(icon: categoryIcon(for: poi), bg: WK.C.mintSoft, fg: WK.C.mint, size: 40, radius: 13)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(poi.name).wkFont(.bodyS).multilineTextAlignment(.leading)
                                        Text(metadata?.stops.first(where: { $0.placeID == poi.id })?.category ?? poi.displayCategory).wkFont(.caption, color: WK.C.ink2)
                                    }
                                    Spacer(minLength: 0)
                                    if let seconds = metadata?.stops.first(where: { $0.placeID == poi.id })?.walkSeconds {
                                        Text("\(seconds / 60) мин").wkFont(.captionS, color: WK.C.ink2)
                                    }
                                }.padding(.vertical, 10).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("route.place.\(index)")
                        }
                    }
                }.frame(maxHeight: 270)
                if let actionError = actionError ?? preview.errorMessage { WKBanner(title: actionError, icon: "alert", kind: .error) }
                if let message = walk.coordinator.errorMessage { Text(message).wkFont(.caption, color: WK.C.danger) }
                if !walk.hasOpenSession {
                    Toggle("Записать прогулку для дипломного исследования", isOn: Binding(get: { walk.coordinator.researchEnabled }, set: { walk.coordinator.researchEnabled = $0 })).wkFont(.captionS)
                    if walk.coordinator.researchEnabled {
                        Text("Исследовательские логи сохраняются только на телефоне. Решения сравниваемых алгоритмов скрыты во время прогулки.").wkFont(.caption, color: WK.C.ink2)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        if requiresExternalNavigation { externalMaps() }
                        else if walk.hasOpenSession { onStart() }
                        else { permissionOutcome = nil; showsPermissionGate = true }
                    } label: {
                        HStack(spacing: 6) {
                            if walk.isBusy { ProgressView().tint(.white) }
                            WKIcon(name: requiresExternalNavigation ? "map" : "play", size: 20, color: .white)
                            Text(requiresExternalNavigation ? "В Яндекс Картах" : (walk.hasOpenSession ? "К прогулке" : "Начать прогулку"))
                        }
                    }.buttonStyle(WKButtonStyle()).disabled(!preview.isRestored || walk.isBusy || preview.isBusy || isRebuilding || walk.coordinator.storageUnavailable).accessibilityIdentifier("route.start")
                    Button { showsEditMenu = true } label: { WKIcon(name: "edit", size: 22).frame(width: 24) }
                        .buttonStyle(WKButtonStyle(kind: .secondary, fullWidth: false)).disabled(!preview.isRestored || walk.hasOpenSession || preview.isBusy || isRebuilding).accessibilityIdentifier("route.edit")
                        .accessibilityLabel("Изменить маршрут")
                }
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
                .background(WK.C.surface, in: UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32)).wkElevated()
        }
        .navigationBarTitleDisplayMode(.inline).toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task {
                        planning?.event("share_tapped", ["route_id": plan.routeID, "screen": "S-18"])
                        do { preparedShareText = try await planning?.shareText(plan: plan) ?? shareText; showsShare = true }
                        catch { actionError = userFacingError(error) }
                    }
                } label: { WKIcon(name: "share", size: 22) }.accessibilityLabel("Поделиться маршрутом")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await product.toggleSavedRoute(plan) } } label: { WKIcon(name: product.isRouteSaved(id: plan.id) ? "check" : "heart", size: 22) }
                    .disabled(product.isBusy).accessibilityLabel("Сохранить маршрут").accessibilityValue(product.isRouteSaved(id: plan.id) ? "Сохранён" : "Не сохранён").accessibilityIdentifier("route.save")
            }
        }
        .confirmationDialog("Изменить маршрут", isPresented: $showsEditMenu, titleVisibility: .visible) {
            if planning != nil {
                Button("Другой вариант") { Task { isRebuilding = true; _ = await preview.alternative(); isRebuilding = false } }
                Button("Скорректировать") { showsCorrection = true }
            }
            Button(editTitle) { planning?.startParametersChange(from: plan); onEdit() }
            Button("Открыть в Яндекс Картах", action: externalMaps)
            Button("Отмена", role: .cancel) {}
        }
        .sheet(isPresented: $showsCorrection) { RouteCorrectionView(model: preview) }
        .sheet(isPresented: $showsPermissionGate, onDismiss: startAfterPermissions) {
            WalkPermissionsFlowView { outcome in
                permissionOutcome = outcome
                showsPermissionGate = false
            }
        }
        .sheet(isPresented: $showsShare) { if let preparedShareText { RouteShareSheet(text: preparedShareText) } }
        .sheet(item: $selectedPlace) { poi in
            NavigationStack {
                RoutePlaceDetailPager(plan: plan, product: product, details: metadata, initialID: poi.id)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { selectedPlace = nil } } }
            }.preferredColorScheme(.light)
        }.preferredColorScheme(.light).tint(WK.C.violet)
            .task {
                let originalID = plan.id
                guard await preview.loadIfNeeded() else { return }
                // Restored replacements emit through onChange; unchanged cards
                // still record their first presentation here.
                if plan.id == originalID { planning?.event("route_shown", ["route_id": plan.routeID, "route_version_id": plan.id]) }
            }
            .task(id: plan.id) { loadedMetadata = await planning?.details(for: plan.id) }
            .onChange(of: plan.id) { _, _ in
                planning?.event("route_shown", ["route_id": plan.routeID, "route_version_id": plan.id])
                onRouteChanged(plan)
            }
    }

    private func startAfterPermissions() {
        guard let outcome = permissionOutcome else { return }
        permissionOutcome = nil
        if outcome == .ready {
            locationDeferred = false
            Task {
                await walk.start(route: plan, kind: startKind)
                if walk.hasOpenSession, walk.record?.route.id == plan.id { onStart() }
            }
        } else {
            locationDeferred = true
            actionError = "Геопозиция не разрешена. Можно открыть маршрут в Яндекс Картах или вернуться к разрешению."
        }
    }

    private func externalMaps() {
        let url = metadata?.externalMapsURL ?? yandexURL
        guard let url else { actionError = "Не удалось открыть внешние карты"; return }
        planning?.event("external_maps_open", ["route_id": plan.routeID, "route_version_id": plan.id, "screen": "S-18"])
        openURL(url)
    }
    private var yandexURL: URL? {
        let coordinates = (plan.start.map { [$0] } ?? []) + plan.pois.map(\.coordinate)
        var components = URLComponents(string: "https://yandex.ru/maps/")!
        components.queryItems = [.init(name: "rtext", value: coordinates.map { "\($0.latitude),\($0.longitude)" }.joined(separator: "~")), .init(name: "rtt", value: "pd")]
        return components.url
    }
    private var shareText: String { plan.displayTitle + "\n" + plan.pois.enumerated().map { "\($0.offset + 1). \($0.element.name)" }.joined(separator: "\n") + (plan.isDemo ? "\nДемонстрационный пример Walkie" : "\nWalkie") }
    private func categoryIcon(for poi: RoutePOI) -> String {
        switch poi.symbolName { case "leaf": return "tree"; case "cup.and.saucer": return "coffee"; case "water.waves": return "waves"; case "building.columns", "building.2": return "building"; default: return "pin" }
    }
}

private struct RoutePlaceDetailPager: View {
    let plan: RoutePlan
    @ObservedObject var product: ProductViewModel
    let details: LiveRouteDetails?
    @State private var index: Int
    init(plan: RoutePlan, product: ProductViewModel, details: LiveRouteDetails?, initialID: String) {
        self.plan = plan; self.product = product; self.details = details
        _index = State(initialValue: plan.pois.firstIndex(where: { $0.id == initialID }) ?? 0)
    }
    var body: some View {
        let poi = plan.pois[index]
        PlaceDetailView(poi: poi, product: product, details: details?.stops.first(where: { $0.placeID == poi.id }),
            pageLabel: "\(index + 1) / \(plan.pois.count)",
            onPrevious: index > 0 ? { index -= 1 } : nil,
            onNext: index + 1 < plan.pois.count ? { index += 1 } : nil)
            .id(poi.id)
    }
}

private struct RouteShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [text], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct ProductRouteMap: View {
    let plan: RoutePlan
    @State private var position: MapCameraPosition = .automatic
    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom]) {
            ForEach(plan.legs) { leg in
                MapPolyline(coordinates: leg.coordinates.map(\.clLocation)).stroke(.white, lineWidth: 11)
                MapPolyline(coordinates: leg.coordinates.map(\.clLocation)).stroke(WK.C.violet, style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(plan.pois.enumerated()), id: \.element.id) { index, poi in
                Annotation(poi.name, coordinate: poi.coordinate.clLocation) {
                    Text("\(index + 1)").wkFont(.captionS, color: .white).frame(width: 32, height: 32).background(WK.C.violet, in: Circle()).overlay(Circle().strokeBorder(.white, lineWidth: 3))
                }.annotationTitles(.hidden)
            }
        }.mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
            .onChange(of: plan.id) { _, _ in position = .automatic }.environment(\.colorScheme, .light)
    }
}

struct RouteCorrectionView: View {
    @ObservedObject var model: RoutePreviewViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var correction: RouteCorrection?
    @State private var isBusy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let correction, correction.understood {
                        Text("Мы поняли так").wkFont(.h1)
                        ForEach(correction.constraints, id: \.self) { Text($0).wkFont(.body).wkCard() }
                        Text("Проверь пожелания перед обновлением маршрута.").wkFont(.caption, color: WK.C.ink2)
                        WKButton(title: "Всё верно, перестроить") {
                            Task { isBusy = true; if await model.applyCorrection(correction) { dismiss() } else { error = model.errorMessage }; isBusy = false }
                        }.disabled(isBusy)
                        WKButton(title: "Уточнить", kind: .secondary) { self.correction = nil }
                    } else {
                        TextField("Что изменить в маршруте?", text: $text, axis: .vertical).lineLimit(4...5).wkFont(.body).padding(16).background(WK.C.surface, in: RoundedRectangle(cornerRadius: 24))
                            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(WK.C.violet, lineWidth: 2))
                            .onChange(of: text) { _, value in if value.count > 140 { text = String(value.prefix(140)) } }
                        Text("\(text.count)/140").wkFont(.caption, color: WK.C.ink3)
                        Text("Быстрые подсказки").wkFont(.caption, color: WK.C.ink2)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                            ForEach(["без кафе", "больше парков", "убери музей", "покороче", "больше видов"], id: \.self) { chip in
                                Button { text = chip } label: { WKChip(title: chip) }.buttonStyle(.plain)
                            }
                        }
                        WKButton(title: "Готово") {
                            Task {
                                isBusy = true; error = nil
                                do { let result = try await model.parseCorrection(text); correction = result; if !result.understood { error = "Не удалось понять пожелание. Попробуй одну из подсказок." } }
                                catch { self.error = userFacingError(error) }
                                isBusy = false
                            }
                        }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
                    }
                    if isBusy { ProgressView().frame(maxWidth: .infinity) }
                    if let error { WKBanner(title: error, icon: "alert", kind: .error) }
                }.padding(20)
            }.background(WK.C.canvas).navigationTitle("Скорректировать маршрут").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(isBusy) } }
        }.preferredColorScheme(.light).tint(WK.C.violet)
    }
}
