import SwiftUI
import UIKit
import WalkieCore

struct HistoryView: View {
    @ObservedObject var model: HistoryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("Ваши прогулки остаются на этом iPhone", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 4)
                    if let error = model.errorMessage {
                        Text(error).font(.subheadline).foregroundStyle(.orange)
                    }
                    if model.sessions.isEmpty {
                        ContentUnavailableView("Первый маршрут впереди", systemImage: "figure.walk", description: Text("Начните прогулку — здесь появятся маршрут и отмеченные вами места."))
                            .padding(.top, 60)
                    }
                    ForEach(model.sessions) { session in
                        NavigationLink {
                            WalkHistoryDetailView(session: session, model: model)
                        } label: {
                            sessionCard(session)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("history.session")
                    }
                }
                .padding(20)
            }
            .background(HistoryPalette.background)
            .navigationTitle("Мои прогулки")
            .task { await model.refresh() }
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("Обновить историю")
                }
            }
        }
    }

    private func sessionCard(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(session.startedAt, format: .dateTime.day().month(.wide).hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(session.state.displayName).font(.caption2.weight(.semibold))
                    .foregroundStyle(HistoryPalette.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(HistoryPalette.accent.opacity(0.1), in: Capsule())
            }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "map.fill")
                    .font(.title2).foregroundStyle(HistoryPalette.accent)
                    .frame(width: 46, height: 46)
                    .background(HistoryPalette.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.route.title).font(.headline).foregroundStyle(.primary)
                    Text("Посещено \(session.visitedPOIIDs.count) из \(session.route.pois.count) мест")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 14)
            }
        }
        .padding(18).background(HistoryPalette.card, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct WalkHistoryDetailView: View {
    let session: SessionRecord
    @ObservedObject var model: HistoryViewModel
    @State private var showsExportConfirmation = false
    @State private var showsDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                RouteMapView(plan: session.route, observation: nil, visitedPOIIDs: Set(session.visitedPOIIDs))
                    .frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 24))
                Text(session.route.title).font(.title2.bold())
                VStack(spacing: 14) {
                    LabeledContent("Дата", value: session.startedAt.formatted(.dateTime.day().month().year()))
                    LabeledContent("Состояние", value: session.state.displayName)
                    if let endedAt = session.endedAt {
                        LabeledContent("Время с паузами", value: duration(until: endedAt))
                    }
                    LabeledContent("Посещено", value: "\(session.visitedPOIIDs.count) из \(session.route.pois.count)")
                }
                .font(.subheadline).padding(18)
                .background(HistoryPalette.card, in: RoundedRectangle(cornerRadius: 20))
                VStack(alignment: .leading, spacing: 16) {
                    Text("Места прогулки").font(.headline)
                    ForEach(session.route.pois) { place in
                        Label(place.name, systemImage: session.visitedPOIIDs.contains(place.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(session.visitedPOIIDs.contains(place.id) ? HistoryPalette.accent : .secondary)
                            .font(.subheadline)
                    }
                    Text("Ручных отметок: \(session.manualVisitedPOIIDs.count), автоматических: \(session.autoVisitedPOIIDs?.count ?? 0). Завершение прогулки само по себе не подтверждает прохождение всех мест.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Button { withAnimation { showsDiagnostics.toggle() } } label: {
                        HStack {
                            Label("Данные для исследования", systemImage: "doc.text.magnifyingglass")
                            Spacer()
                            Image(systemName: showsDiagnostics ? "chevron.up" : "chevron.down")
                        }.font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("history.diagnostics")
                    .accessibilityValue(showsDiagnostics ? "Развёрнуто" : "Свёрнуто")
                    if showsDiagnostics {
                        VStack(alignment: .leading, spacing: 14) {
                        LabeledContent("Измерений iOS", value: "\(session.observationCount)")
                            .font(.subheadline)
                        Text("Локальные журналы можно сохранить в «Файлы → На моём iPhone → Walkie → Exports». В них содержатся точные координаты и ручные отметки.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { showsExportConfirmation = true } label: {
                            Label("Экспортировать журналы", systemImage: "square.and.arrow.up")
                        }
                        .font(.subheadline.weight(.semibold))
                        .disabled(model.isBusy || !session.state.isClosed)
                        .accessibilityIdentifier("history.export")
                        if !session.state.isClosed {
                            Text("Экспорт станет доступен после завершения прогулки.").font(.caption).foregroundStyle(.secondary)
                        }
                        }.padding(.top, 4)
                    }
                }
                .padding(18).background(HistoryPalette.card, in: RoundedRectangle(cornerRadius: 20))
                if let error = model.errorMessage {
                    Text(error).font(.subheadline).foregroundStyle(.orange)
                }
            }
            .padding(20)
        }
        .background(HistoryPalette.background)
        .navigationTitle("Прогулка")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $model.showsShare) { ShareSheet(urls: model.exportFiles) }
        .confirmationDialog("Создать копию с координатами?", isPresented: $showsExportConfirmation, titleVisibility: .visible) {
            Button("Создать экспорт") { Task { await model.export(session) } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Данные не отправятся автоматически. Вы сами выбираете, кому передать файлы с геопозицией.")
        }
    }

    private func duration(until end: Date) -> String {
        let minutes = max(0, Int(end.timeIntervalSince(session.startedAt) / 60))
        if minutes == 0 { return "Меньше минуты" }
        if minutes < 60 { return "\(minutes) мин" }
        return "\(minutes / 60) ч \(minutes % 60) мин"
    }
}

private enum HistoryPalette {
    static let background = WTheme.background
    static let card = WTheme.card
    static let accent = WTheme.accent
}

private struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
