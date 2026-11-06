import SwiftUI
import WalkieCore

/// No GPS or algorithm decision is displayed on the observer's labeling surface.
struct ResearchObserverView: View {
    @ObservedObject var coordinator: WalkSessionCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var geometry = ResearchGeometry.unknown
    @State private var intent = ResearchIntent.unknown
    @State private var note = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Размечайте по местности и паспорту маршрута. Не используйте карту или GPS этого iPhone как истину. Метка действует с нажатия до следующей метки.")
                    Text("Решения A и B1 скрыты. Неизвестное положение не угадывайте.")
                }.font(.footnote)
                Section("Фактическая геометрия") {
                    Picker("Положение", selection: $geometry) {
                        Text("В допустимой области маршрута").tag(ResearchGeometry.onRoute)
                        Text("За пределами допустимой области").tag(ResearchGeometry.offRoute)
                        Text("Неизвестно / нет разметки").tag(ResearchGeometry.unknown)
                    }.pickerStyle(.inline)
                }
                Section("Намерение — отдельная метка") {
                    Picker("Намерение", selection: $intent) {
                        Text("Намеренный уход").tag(ResearchIntent.deliberate)
                        Text("Имитация ошибочного поворота").tag(ResearchIntent.scriptedUnintended)
                        Text("Естественный ошибочный поворот").tag(ResearchIntent.naturalUnintended)
                        Text("Неизвестно").tag(ResearchIntent.unknown)
                    }.pickerStyle(.inline)
                    TextField("Ориентир / комментарий", text: $note, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    Button(saved ? "Метка сохранена ✓" : "Зафиксировать сейчас") {
                        Task {
                            await coordinator.labelResearch(geometry: geometry, intent: intent, note: note)
                            saved = true
                        }
                    }.disabled(coordinator.isBusy).accessibilityIdentifier("research.mark")
                    Text("Всего меток: \(coordinator.researchMarkerCount)").font(.caption)
                }
            }.navigationTitle("Разметка наблюдателя").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
                .onChange(of: geometry) { _, _ in saved = false }
                .onChange(of: intent) { _, _ in saved = false }
                .onChange(of: note) { _, _ in saved = false }
        }
    }
}
