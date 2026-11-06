import SwiftUI
import MapKit
import UniformTypeIdentifiers

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct ContentView: View {
    @StateObject private var recorder = FieldRecorder()
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    @State private var route: TestRoute?
    @State private var savedRoutes: [TestRoute] = []
    @State private var draft: [GeoPoint] = []
    @State private var routeName = "Тестовая прогулка"
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: .init(latitude: 55.751244, longitude: 37.618423),
        span: .init(latitudeDelta: 0.018, longitudeDelta: 0.018)))
    @State private var mapCenter = GeoPoint(latitude: 55.751244, longitude: 37.618423)
    @State private var importing = false
    @State private var planning = false
    @State private var planningTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { routeScreen }
                .tabItem { Label("Маршрут", systemImage: "map") }.tag(0)
            NavigationStack {
                RecordingScreen(recorder: recorder, route: route) { tab = 0 }
            }
            .tabItem { Label("Тест", systemImage: "record.circle") }.tag(1)
            NavigationStack { SessionsScreen(recorder: recorder) }
                .tabItem { Label("Логи", systemImage: "folder") }.tag(2)
        }
        .tint(.teal)
        .onAppear {
            reloadRoutes(); recorder.refreshSessions()
            #if DEBUG && targetEnvironment(simulator)
            SimulatorSmoke.runIfRequested(recorder: recorder)
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            recorder.recordLifecycle(String(describing: phase))
        }
        .onChange(of: recorder.errorMessage) { _, message in
            if let message { errorMessage = message }
        }
        .alert("Не удалось выполнить действие", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("Понятно", role: .cancel) { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml],
                      allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5 * 1024 * 1024 else { throw FieldLabError.message("GPX должен быть не больше 5 МБ.") }
                let imported = try RouteImport.gpx(data: Data(contentsOf: url), name: url.deletingPathExtension().lastPathComponent)
                try selectAndSave(imported)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var routeScreen: some View {
        VStack(spacing: 0) {
            ZStack {
                Map(position: $camera) {
                    if let route {
                        ForEach(Array(route.segments.enumerated()), id: \.offset) { _, segment in
                            MapPolyline(coordinates: segment.map(\.coordinate)).stroke(.blue, lineWidth: 5)
                        }
                    }
                    if draft.count > 1 {
                        MapPolyline(coordinates: draft.map(\.coordinate))
                            .stroke(.teal, style: StrokeStyle(lineWidth: 3, dash: [7, 5]))
                    }
                    ForEach(Array(draft.enumerated()), id: \.offset) { index, point in
                        Annotation("\(index + 1)", coordinate: point.coordinate) {
                            Text("\(index + 1)").font(.caption.bold()).foregroundStyle(.white)
                                .frame(width: 26, height: 26).background(.teal, in: Circle())
                        }
                    }
                    if let fix = recorder.latestLocation, fix.point.isValid {
                        Marker("Измерение геолокации", systemImage: "location.fill", coordinate: fix.point.coordinate)
                            .tint(.orange)
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                .mapControls { MapCompass(); MapScaleView() }
                .onMapCameraChange(frequency: .onEnd) { context in
                    mapCenter = GeoPoint(latitude: context.region.center.latitude, longitude: context.region.center.longitude)
                }
                if !recorder.isRecording && !planning {
                    Image(systemName: "plus").font(.title2.weight(.medium))
                        .foregroundStyle(.primary).padding(8)
                        .background(.regularMaterial, in: Circle()).allowsHitTesting(false)
                }
                VStack {
                    Spacer()
                    HStack {
                        Text(recorder.isRecording ? "План: синий · GPS: оранжевый, не истина" : "Двигай карту: новая точка будет под крестиком")
                            .font(.caption).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                        Spacer(minLength: 0)
                    }.padding(10)
                }.allowsHitTesting(false)
            }
            .frame(minHeight: 220, maxHeight: .infinity)
            routeControls.padding(14).background(.regularMaterial)
        }
        .navigationTitle("Walkie · Field Lab")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Импорт GPX", systemImage: "square.and.arrow.down") { importing = true }
                    if !savedRoutes.isEmpty {
                        Section("Сохранённые маршруты") {
                            ForEach(savedRoutes) { saved in
                                Button(saved.name) { route = saved; draft = []; routeName = saved.name; fit(saved) }
                            }
                        }
                    }
                    Button("Новый маршрут", systemImage: "plus") { route = nil; draft = [] }
                } label: { Image(systemName: "folder.badge.plus") }
                .disabled(recorder.isRecording || planning)
            }
        }
    }

    private var routeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recorder.isRecording {
                Label("Маршрут зафиксирован на время теста", systemImage: "lock.fill").font(.subheadline)
                Button("Перейти к записи") { tab = 1 }.buttonStyle(.borderedProminent)
            } else {
                if let route {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(route.name).font(.headline).lineLimit(1)
                            Text("\(route.points.count) точек · \(route.segments.count) сегм. · \(route.source)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Button("Тест") { tab = 1 }.buttonStyle(.borderedProminent)
                    }
                }
                if planning {
                    HStack { ProgressView(); Text("Строю пеший путь…"); Spacer(); Button("Отмена") { planningTask?.cancel() } }
                } else {
                    TextField("Название маршрута", text: $routeName).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Точка \(draft.count + 1)", systemImage: "plus.circle.fill") {
                            if draft.last != mapCenter { draft.append(mapCenter) }
                        }.buttonStyle(.borderedProminent).disabled(draft.count >= 100)
                        Button("Назад", systemImage: "arrow.uturn.backward") { if !draft.isEmpty { draft.removeLast() } }
                            .buttonStyle(.bordered).disabled(draft.isEmpty)
                        Button { draft = [] } label: { Image(systemName: "xmark.circle") }
                            .accessibilityLabel("Очистить точки").disabled(draft.isEmpty)
                    }
                    HStack {
                        Button("Пеший путь", systemImage: "figure.walk") { buildWalkingRoute() }
                            .buttonStyle(.bordered).disabled(draft.count < 2 || draft.count > 8)
                        Button("Ручная линия", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                            do {
                                let manual = TestRoute(name: cleanName, source: "manual_polyline", segments: [draft])
                                try selectAndSave(manual)
                            } catch { errorMessage = error.localizedDescription }
                        }.buttonStyle(.bordered).disabled(draft.count < 2)
                    }
                    Text("Пеший путь: 2–8 точек, интернет и покрытие Apple Maps. Ручная линия соединяет твои точки напрямую — расставь их на всех поворотах. Для точного плана можно импортировать GPX через меню сверху.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var cleanName: String { routeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Тестовая прогулка" : String(routeName.prefix(100)) }

    private func reloadRoutes() {
        do { savedRoutes = try RouteService.loadSavedRoutes() }
        catch { errorMessage = error.localizedDescription }
    }

    private func selectAndSave(_ newRoute: TestRoute) throws {
        try RouteService.save(newRoute)
        route = newRoute; routeName = newRoute.name; draft = []; reloadRoutes(); fit(newRoute)
    }

    private func fit(_ route: TestRoute) {
        var rect = MKMapRect.null
        for point in route.points {
            let p = MKMapPoint(point.coordinate)
            rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
        }
        if !rect.isNull {
            camera = .rect(rect.insetBy(dx: -max(800, rect.width * 0.15), dy: -max(800, rect.height * 0.15)))
        }
    }

    private func buildWalkingRoute() {
        let points = draft, name = cleanName
        planning = true
        planningTask = Task { @MainActor in
            defer { planning = false; planningTask = nil }
            do {
                let result = try await RouteService().walkingRoute(through: points, name: name)
                try Task.checkCancellation()
                try selectAndSave(result)
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
}

private struct RecordingScreen: View {
    @ObservedObject var recorder: FieldRecorder
    let route: TestRoute?
    var chooseRoute: () -> Void
    @State private var sessionName = "Прогулка"
    @State private var notes = ""
    @State private var markerNote = ""
    @State private var localError: String?
    @State private var confirmStop = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: recorder.isRecording ? "record.circle.fill" : "figure.walk.circle")
                            .foregroundStyle(recorder.isRecording ? .red : .teal)
                        Text(recorder.isRecording ? "Идёт запись" : "Полевой тест").font(.title2.bold())
                        Spacer()
                        Text(duration(recorder.elapsed)).font(.title2.monospacedDigit())
                    }
                    Text(recorder.status).font(.subheadline).foregroundStyle(.secondary)
                    Text(recorder.authorizationDescription).font(.caption)
                    if let warning = recorder.recordingWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }.labCard()

                if !recorder.isRecording {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(route?.name ?? "Сначала нужен маршрут").font(.headline)
                        if route == nil { Button("Задать маршрут", action: chooseRoute).buttonStyle(.bordered) }
                        TextField("Название теста", text: $sessionName).textFieldStyle(.roundedBorder)
                        TextField("Условия: район, телефон в руке/кармане…", text: $notes, axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...4)
                        Button("Разрешить геолокацию и движение", systemImage: "location.circle") { recorder.requestPermissions() }
                            .buttonStyle(.bordered)
                        Button("Начать запись", systemImage: "record.circle") {
                            guard let route else { return }
                            do { try recorder.start(route: route, name: String(sessionName.prefix(100)), notes: String(notes.prefix(2000))) }
                            catch { localError = error.localizedDescription }
                        }.buttonStyle(.borderedProminent).controlSize(.large).disabled(route == nil)
                        Text("Запускай тест, пока приложение открыто. Экран можно заблокировать; непрерывность датчиков в фоне нужно проверить на телефоне. Принудительное закрытие остановит запись.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.labCard()
                }

                if let fix = recorder.latestLocation {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Последнее измерение, не эталон").font(.headline)
                        Text(String(format: "%.6f, %.6f", fix.latitude, fix.longitude)).font(.system(.body, design: .monospaced))
                        Text(String(format: "Заявленная точность: %.0f м · возраст: %.0f с", fix.horizontalAccuracy,
                                    max(0, recorder.elapsed - fix.elapsed + fix.receivedAt.timeIntervalSince(fix.observedAt))))
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Шаги: \(recorder.motion.steps.map(String.init) ?? "—") · дистанция шагомера: \(recorder.motion.distance.map { String(format: "%.0f м", $0) } ?? "—")")
                            .font(.caption)
                    }.labCard()
                }

                ForEach(recorder.results) { result in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(result.algorithm == "geometric_v1" ? "Геометрия" : "Геометрия + проверки").font(.headline)
                            Spacer()
                            Circle().fill(color(result.state)).frame(width: 10, height: 10)
                        }
                        Text(result.state.title).foregroundStyle(color(result.state)).font(.subheadline.bold())
                        Text(result.reason).font(.caption).foregroundStyle(.secondary)
                        if let distance = result.distanceToRoute { Text(String(format: "До плана: %.1f м", distance)).font(.caption.monospacedDigit()) }
                    }.labCard()
                }

                if recorder.isRecording {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Отметить, что происходит на самом деле").font(.headline)
                        Text("Сверяйся с окружающей обстановкой. Эти отметки не передаются алгоритмам и не являются точным геодезическим эталоном.")
                            .font(.caption).foregroundStyle(.secondary)
                        marker("Я на маршруте", "actual_on_route", "checkmark.circle", .green)
                        marker("Я сошёл с маршрута", "actual_off_route", "arrow.triangle.branch", .orange)
                        marker("Координаты явно неверные", "gps_wrong", "location.slash", .red)
                        HStack {
                            marker("В руке", "phone_hand", "hand.raised", .teal)
                            marker("В кармане", "phone_pocket", "iphone", .teal)
                        }
                        TextField("Примечание или ориентир", text: $markerNote, axis: .vertical).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Ориентир", systemImage: "mappin.and.ellipse") { saveMarker("landmark") }
                            Button("Заметка", systemImage: "text.bubble") { saveMarker("note") }.disabled(markerNote.isEmpty)
                        }.buttonStyle(.bordered)
                    }.labCard()
                    Button("Завершить и сохранить", systemImage: "stop.circle.fill", role: .destructive) { confirmStop = true }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Label("Локально, без сервера Walkie", systemImage: "internaldrive").font(.headline)
                    Text("Файлы → Обзор → На моём iPhone → Walkie Field Lab → Sessions. Маршруты лежат рядом, в Routes. В логах есть чувствительные координаты и данные движения — делись ими осознанно.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Это регистратор эксперимента, не навигатор безопасности и не детектор глушения. Проверки не исправляют GPS и могут пропустить правдоподобное смещение. HMM и PDR здесь пока не запущены.")
                        .font(.caption).foregroundStyle(.secondary)
                }.labCard()
            }.padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Запись теста").navigationBarTitleDisplayMode(.inline)
        .alert("Не удалось начать тест", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("Понятно", role: .cancel) { localError = nil }
        } message: { Text(localError ?? "") }
        .confirmationDialog("Закончить текущую сессию?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Завершить и сохранить") { recorder.stop() }
        }
    }

    private func marker(_ title: String, _ kind: String, _ icon: String, _ tint: Color) -> some View {
        Button { saveMarker(kind) } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
        }.buttonStyle(.bordered).tint(tint)
    }
    private func saveMarker(_ kind: String) {
        recorder.mark(kind, note: String(markerNote.prefix(2000))); markerNote = ""
    }
    private func color(_ state: RouteState) -> Color {
        switch state { case .onRoute: .green; case .offRoute: .orange; case .uncertain: .secondary }
    }
    private func duration(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

private struct SessionsScreen: View {
    @ObservedObject var recorder: FieldRecorder
    var body: some View {
        List {
            Section {
                Text("Файлы → На моём iPhone → Walkie Field Lab → Sessions").font(.subheadline)
                Text("Одна папка — одна прогулка. Логи пишутся во время теста. Для передачи завершённой прогулки удобнее сжать её папку в приложении «Файлы».")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Записи на устройстве") {
                if recorder.sessions.isEmpty { Text("Пока нет записей").foregroundStyle(.secondary) }
                ForEach(recorder.sessions, id: \.path) { folder in
                    NavigationLink {
                        SessionDetailScreen(folder: folder, isActive: recorder.isRecording && recorder.currentFolder == folder)
                    } label: {
                        Label {
                            VStack(alignment: .leading) {
                                Text(folder.lastPathComponent).font(.subheadline.monospaced())
                                if recorder.isRecording && recorder.currentFolder == folder { Text("Идёт запись").font(.caption).foregroundStyle(.red) }
                            }
                        } icon: { Image(systemName: "folder") }
                    }
                }
            }
        }
        .navigationTitle("Логи прогулок")
        .toolbar { Button("Обновить", systemImage: "arrow.clockwise") { recorder.refreshSessions() } }
        .onAppear { recorder.refreshSessions() }
    }
}

private struct SessionDetailScreen: View {
    let folder: URL
    let isActive: Bool
    @State private var files: [URL] = []
    @State private var summary: SessionSummary?
    @State private var metadata: SessionInfo?
    @State private var loadError: String?
    @State private var share = false

    var body: some View {
        List {
            if let loadError { Text(loadError).foregroundStyle(.red) }
            if let metadata {
                Section("Сессия") {
                    Text(metadata.name).font(.headline)
                    Text(metadata.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text("Маршрут: \(metadata.route.name)")
                    if !metadata.notes.isEmpty { Text(metadata.notes) }
                    if metadata.interrupted && !isActive {
                        Label("Сессия не была штатно завершена. Сырые логи сохранены; итог и GPX могут отсутствовать.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            if let summary {
                Section("Сводка — без автоматической оценки истинности") {
                    Text("Измерений GPS: \(summary.locationCount) · отметок: \(summary.markerCount)")
                    Text(String(format: "Длительность: %.1f мин", summary.duration / 60))
                    ForEach(summary.algorithms.keys.sorted(), id: \.self) { key in
                        if let item = summary.algorithms[key] {
                            VStack(alignment: .leading) {
                                Text(key).font(.caption.monospaced())
                                Text("Предупреждений: \(item.alerts)")
                                Text(String(format: "Неопределённость: %.0f с", item.uncertainSeconds)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("Файлы") {
                if isActive { Text("Сначала заверши запись для согласованной выгрузки.").foregroundStyle(.orange) }
                ForEach(files, id: \.path) { file in
                    ShareLink(item: file) { Label(file.lastPathComponent, systemImage: "doc") }.disabled(isActive)
                }
                Button("Поделиться всеми файлами", systemImage: "square.and.arrow.up") { share = true }
                    .disabled(isActive || files.isEmpty)
            }
        }
        .navigationTitle("Сессия").navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .sheet(isPresented: $share) { ActivitySheet(items: files) }
    }

    private func load() {
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                .filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            let decoder = FieldLogJSON.decoder()
            if files.contains(where: { $0.lastPathComponent == "meta.json" }) {
                metadata = try decoder.decode(SessionInfo.self, from: Data(contentsOf: folder.appendingPathComponent("meta.json")))
            }
            if files.contains(where: { $0.lastPathComponent == "summary.json" }) {
                summary = try decoder.decode(SessionSummary.self, from: Data(contentsOf: folder.appendingPathComponent("summary.json")))
            }
        } catch { loadError = error.localizedDescription }
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}

private extension View {
    func labCard() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}
