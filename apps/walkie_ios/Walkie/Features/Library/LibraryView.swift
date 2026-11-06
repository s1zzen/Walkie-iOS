import SwiftUI
import WalkieCore

struct LibraryView: View {
    @ObservedObject var model: ProductViewModel
    let onSelectRoute: (RoutePlan) -> Void
    let onSelectPlace: (RoutePOI) -> Void
    @State private var selection = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Места, в которые хочется вернуться.")
                        .font(.title3).foregroundStyle(.secondary)
                    Picker("Коллекция", selection: $selection) {
                        Text("Места · \(model.favoritePlaces.count)").tag(0).accessibilityIdentifier("library.favorites")
                        Text("Маршруты · \(model.savedRoutes.count)").tag(1).accessibilityIdentifier("library.saved")
                    }
                    .pickerStyle(.segmented).accessibilityIdentifier("library.segment")
                    if let error = model.errorMessage { ProductErrorBanner(message: error) }
                    if selection == 0 { places } else { routes }
                }.padding(20)
            }
            .background(ProductPalette.background)
            .navigationTitle("Избранное")
        }
        .tint(ProductPalette.accent)
    }

    @ViewBuilder
    private var places: some View {
        if model.favoritePlaces.isEmpty {
            emptyState("Здесь будут любимые места", subtitle: "Нажмите на сердечко в карточке места. Оно останется в вашей коллекции.", icon: "heart")
        } else {
            ForEach(model.favoritePlaces) { poi in
                HStack(alignment: .top, spacing: 14) {
                    Button { onSelectPlace(poi) } label: {
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.title2).foregroundStyle(ProductPalette.accent)
                                .frame(width: 54, height: 60)
                                .background(ProductPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(poi.name).font(.headline).foregroundStyle(.primary)
                                Text(poi.description ?? "Место сохранено в вашей коллекции")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("library.place.\(poi.id)")
                    Button { Task { await model.toggleFavorite(poi) } } label: {
                        Image(systemName: "heart.fill").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(ProductPalette.accent)
                    .disabled(model.isBusy)
                    .accessibilityLabel("Удалить \(poi.name) из избранного")
                }
                .padding(16).background(ProductPalette.card, in: RoundedRectangle(cornerRadius: 22))
            }
        }
    }

    @ViewBuilder
    private var routes: some View {
        if model.savedRoutes.isEmpty {
            emptyState("Сохраните прогулку на потом", subtitle: "Откройте готовый маршрут и нажмите «Сохранить». Он будет доступен здесь после перезапуска.", icon: "bookmark")
        } else {
            ForEach(model.savedRoutes) { route in
                VStack(alignment: .leading, spacing: 15) {
                    HStack {
                        Label("\(route.pois.count) мест", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.caption.weight(.medium)).foregroundStyle(ProductPalette.accent)
                        Spacer()
                        Button { Task { await model.toggleSavedRoute(route) } } label: {
                            Image(systemName: "bookmark.fill").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(ProductPalette.accent)
                        .disabled(model.isBusy)
                        .accessibilityLabel("Удалить маршрут из сохранённых")
                    }
                    Text(route.title).font(.title3.bold())
                    Text(route.pois.map(\.name).joined(separator: " → "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    if route.isDemo {
                        Text("Демонстрационный маршрут").font(.caption2).foregroundStyle(.secondary)
                    }
                    Button { onSelectRoute(route) } label: {
                        HStack {
                            Text("Открыть маршрут").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(ProductPalette.accent)
                    .accessibilityIdentifier("library.route.\(route.id)")
                }
                .padding(20).background(ProductPalette.card, in: RoundedRectangle(cornerRadius: 22))
            }
        }
    }

    private func emptyState(_ title: String, subtitle: String, icon: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon).font(.system(size: 43, weight: .light))
                .foregroundStyle(ProductPalette.accent).padding(.bottom, 2)
            Text(title).font(.title3.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.horizontal, 18).padding(.vertical, 65)
    }
}
