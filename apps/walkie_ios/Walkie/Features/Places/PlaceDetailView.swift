import MapKit
import SwiftUI
import WalkieCore

struct PlaceDetailView: View {
    let poi: RoutePOI
    @ObservedObject var product: ProductViewModel
    var details: LiveRouteDetails.Stop? = nil
    var pageLabel: String? = nil
    var onPrevious: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil
    @State private var showsMap = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 16) {
                    Text(details?.category ?? poi.displayCategory).wkFont(.captionS, color: WK.C.ink2)
                    Text(poi.name).wkFont(.h1)
                    HStack(spacing: 8) {
                        if let seconds = details?.walkSeconds { WKChip(title: "\(seconds / 60) мин от предыдущей", icon: "steps") }
                        if let rating = details?.rating { WKChip(title: rating.formatted(.number.precision(.fractionLength(1))), icon: "star") }
                    }
                    if let hours = details?.hours {
                        Text(hours).wkFont(.calloutS, color: details?.openNow == false ? WK.C.ink2 : WK.C.mint).padding(12).background(WK.C.mintSoft, in: RoundedRectangle(cornerRadius: 16))
                    }
                    Text(poi.description ?? "Описание места пока не добавлено.").wkFont(.body, color: WK.C.ink2)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) { WKIconBadge(icon: "sparkles", size: 32, radius: 12); Text("Почему в маршруте").wkFont(.bodyS) }
                        let reasons = details?.reasons ?? poi.recommendationReasons
                        if reasons.isEmpty {
                            Text(details?.fallback ?? "Удобная остановка между точками маршрута").wkFont(.callout, color: WK.C.ink2)
                        } else {
                            Text("Совпадает с твоими ответами:").wkFont(.callout, color: WK.C.ink2)
                            ForEach(reasons, id: \.self) { reason in Text(reason).wkFont(.calloutS, color: WK.C.violet).padding(.horizontal, 12).padding(.vertical, 8).background(WK.C.surface, in: Capsule()) }
                        }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(WK.C.violetSoft, in: RoundedRectangle(cornerRadius: 24))
                    if let address = details?.address { Text(address).wkFont(.body, color: WK.C.ink2) }
                    if details == nil { Text("Локальный пример. Часы работы и доступность не проверены.").wkFont(.caption, color: WK.C.ink3) }
                    if let message = product.errorMessage { WKBanner(title: message, icon: "alert", kind: .error) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(WK.C.canvas, in: UnevenRoundedRectangle(topLeadingRadius: 32, topTrailingRadius: 32)).padding(.top, -32)
            }
        }.background(WK.C.canvas).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let pageLabel { ToolbarItem(placement: .principal) { Text(pageLabel).wkFont(.captionS) } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await product.toggleFavorite(poi) } } label: { WKIcon(name: product.isFavorite(id: poi.id) ? "check" : "heart", size: 24) }
                        .disabled(product.isBusy).accessibilityLabel(product.isFavorite(id: poi.id) ? "Убрать из избранного" : "Добавить в избранное").accessibilityIdentifier("place.favorite")
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    if pageLabel != nil { WKCircleButton(icon: "chev-l", accessibilityLabel: "Предыдущее место") { onPrevious?() }.disabled(onPrevious == nil) }
                    WKButton(title: "Открыть на карте", icon: "map") { showsMap = true }.accessibilityIdentifier("place.map")
                    if pageLabel != nil { WKCircleButton(icon: "chev-r", accessibilityLabel: "Следующее место") { onNext?() }.disabled(onNext == nil) }
                }.padding(.horizontal, 20).padding(.vertical, 12).background(WK.C.canvas.opacity(0.95))
            }
            .sheet(isPresented: $showsMap) {
                NavigationStack {
                    Map(initialPosition: .region(.init(center: poi.coordinate.clLocation, span: .init(latitudeDelta: 0.007, longitudeDelta: 0.007)))) {
                        Marker(poi.name, coordinate: poi.coordinate.clLocation).tint(WK.C.violet)
                    }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll)).navigationTitle(poi.name).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { showsMap = false } } }
                }.preferredColorScheme(.light)
            }.tint(WK.C.violet).preferredColorScheme(.light)
    }

    private var hero: some View {
        Group {
            if let url = details?.photoURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                    else { categoryHero }
                }.frame(height: 380).clipped()
            } else { categoryHero.frame(height: 300) }
        }.frame(maxWidth: .infinity)
    }
    private var categoryHero: some View {
        WK.C.violetSoft.overlay {
            VStack(spacing: 16) { WKIcon(name: "pin", size: 92, color: WK.C.violet); Text(details?.category ?? poi.displayCategory).wkFont(.h3, color: WK.C.violet) }
        }
    }
}
