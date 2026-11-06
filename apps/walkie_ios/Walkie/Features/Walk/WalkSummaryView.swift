import SwiftUI
import WalkieCore

/// S-24. Closing a recording is not an automatic statement of route completion.
struct WalkSummaryView: View {
    let record: SessionRecord
    @ObservedObject var model: WalkViewModel
    var onDone: () -> Void
    @State private var rating = 0
    @State private var comment = ""
    @State private var saved = false

    private var allVisited: Bool { record.visitedPOIIDs.count == record.route.pois.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 10) {
                    WKIconBadge(icon: "trophy", bg: WK.C.lime, fg: WK.C.ink, size: 72, radius: 26)
                    Text(record.state == .interrupted ? "Прогулка прервана" : allVisited ? "Все места отмечены!"
                        : model.coordinator.productFinishMethod == "finish_last_point" ? "Прогулка завершена" : "Хорошая прогулка")
                        .wkFont(.display, color: .white).multilineTextAlignment(.center)
                    Text("\(record.visitedPOIIDs.count) из \(record.route.pois.count) мест · \(record.route.title)")
                        .wkFont(.body, color: .white.opacity(0.85)).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24).padding(.top, 32).padding(.bottom, 56).frame(maxWidth: .infinity)
                .background(alignment: .center) { Image("summary-confetti").resizable().scaledToFit().frame(width: 305, height: 159) }
                .background(WK.C.violet, in: UnevenRoundedRectangle(bottomLeadingRadius: 40, bottomTrailingRadius: 40))
                VStack(spacing: 16) {
                    HStack(spacing: 8) {
                        stat("pin", "\(record.visitedPOIIDs.count)/\(record.route.pois.count)", "мест")
                        stat("route", model.coordinator.distanceEstimateMeters.map { String(format: "%.1f км", $0 / 1_000) } ?? "—", "оценка GPS")
                        stat("clock", model.elapsedText, "с паузами")
                        stat("steps", model.coordinator.latestMotion.map { "\($0.steps)" } ?? "—", "шагов¹")
                    }.padding(12).background(WK.C.surface, in: RoundedRectangle(cornerRadius: 28)).wkElevated()
                    VStack(spacing: 12) {
                        Text(saved ? "Спасибо за оценку!" : "Как тебе маршрут?").wkFont(.h3)
                        HStack(spacing: 10) {
                            ForEach(1...5, id: \.self) { value in
                                Button { rating = value; saved = false } label: {
                                    Image("rating-star").renderingMode(.template).resizable().scaledToFit()
                                        .frame(width: 40, height: 40).foregroundStyle(value <= rating ? WK.C.sun : WK.C.line)
                                }.accessibilityLabel("Оценить на \(value)").accessibilityAddTraits(value == rating ? .isSelected : [])
                            }
                        }
                        HStack(spacing: 8) {
                            WKIcon(name: "message", size: 18, color: WK.C.ink3)
                            TextField("Комментарий (необязательно)", text: $comment, axis: .vertical).wkFont(.callout).lineLimit(1...4)
                        }.padding(14).background(WK.C.canvas, in: RoundedRectangle(cornerRadius: 20))
                    }.padding(20).background(WK.C.surface, in: RoundedRectangle(cornerRadius: 28)).wkCardShadow()
                    Text("Ручных отметок: \(record.manualVisitedPOIIDs.count), автоматических: \(record.autoVisitedPOIIDs?.count ?? 0). Автоотметки — оценка по GPS, а не независимая истина исследования. ¹ Шаги с последнего старта датчика.")
                        .wkFont(.caption, color: WK.C.ink2)
                    if model.coordinator.researchMetrics != nil {
                        WKBanner(title: "Пилот исследования сохранён", message: "A и B1 обработали одинаковую запись. Разметка и метрики входят в экспорт. Это ещё не результат проверки гипотезы.", kind: .info)
                    }
                    if let error = model.coordinator.errorMessage { WKBanner(title: "Не удалось сохранить", message: error, kind: .error) }
                    if let status = model.coordinator.syncStatus { WKBanner(title: "Синхронизация", message: status, kind: .info) }
                    if let state = model.synchronization {
                        if let problem = state.problem { WKBanner(title: state.phase == .requiresDistance ? "Нужно решение по данным" : "Ожидает синхронизации", message: problem, kind: .warning) }
                        if state.phase == .queued || state.phase == .requiresDistance {
                            Button("Проверить журнал и повторить синхронизацию") { Task { await model.retrySynchronization() } }
                                .wkFont(.captionS, color: WK.C.violet).accessibilityIdentifier("walk.retrySync")
                        } else if state.phase == .acknowledged { Text("Итог подтверждён сервером").wkFont(.caption, color: WK.C.ink2) }
                    }
                    WKButton(title: saved ? "Готово" : "Сохранить оценку") {
                        if saved { onDone() }
                        else { Task { saved = await model.saveRating(rating, comment: comment); if saved { onDone() } } }
                    }.disabled(rating == 0 || model.isBusy).opacity(rating == 0 ? 0.4 : 1)
                    Button("Пропустить") { Task { if await model.skipRating() { onDone() } } }.wkFont(.calloutS, color: WK.C.ink3)
                        .accessibilityIdentifier("walk.skipRating")
                    Button("Закрыть") { Task { if await model.skipRating() { onDone() } } }.wkFont(.caption, color: WK.C.ink3)
                    Button { model.showsExportConfirmation = true } label: {
                        Label("Сохранить логи в «Файлы»", systemImage: "square.and.arrow.up")
                    }.wkFont(.captionS, color: WK.C.violet).disabled(model.isBusy)
                        .accessibilityIdentifier("walk.export")
                }.padding(.horizontal, 20).padding(.top, -32).padding(.bottom, 24)
            }
        }.background(WK.C.canvas).scrollDismissesKeyboard(.interactively)
            .task(id: record.id) {
                while !Task.isCancelled {
                    await model.refreshSynchronization()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
            .confirmationDialog("Экспорт локальных данных", isPresented: $model.showsExportConfirmation, titleVisibility: .visible) {
                Button("Экспортировать") { Task { await model.export() } }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Файлы содержат точный GPS-трек и отметки. Экспортируйте с согласия участника. Автоматической отправки нет.") }
    }

    private func stat(_ icon: String, _ value: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            WKIcon(name: icon, size: 18, color: WK.C.violet)
            Text(value).wkFont(.bodyS).lineLimit(1).minimumScaleFactor(0.65)
            Text(title).wkFont(.micro, color: WK.C.ink2)
        }.frame(maxWidth: .infinity).padding(.vertical, 6)
    }
}
