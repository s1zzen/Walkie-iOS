import MapKit
import SwiftUI
import WalkieCore

struct RouteMapView: View {
    let plan: RoutePlan
    let observation: SensorObservation?
    var visitedPOIIDs: Set<String> = []
    var selectedPOIID: String? = nil
    @State private var position: MapCameraPosition = .automatic
    private let accent = WK.C.violet

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom, .rotate]) {
            ForEach(plan.legs, id: \.id) { leg in
                MapPolyline(coordinates: leg.coordinates.map(\.clCoordinate))
                    .stroke(accent.opacity(0.25), lineWidth: 10)
                MapPolyline(coordinates: leg.coordinates.map(\.clCoordinate))
                    .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(Array(plan.pois.enumerated()), id: \.element.id) { index, poi in
                Annotation(poi.name, coordinate: poi.coordinate.clCoordinate, anchor: .center) {
                    ZStack {
                        Circle().fill(visitedPOIIDs.contains(poi.id) ? WK.C.mint : accent)
                        Circle().strokeBorder(.white, lineWidth: 3)
                        if visitedPOIIDs.contains(poi.id) {
                            Image(systemName: "checkmark").font(.caption.bold())
                        } else {
                            Text("\(index + 1)").font(.caption.bold())
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: selectedPOIID == poi.id ? 40 : 32, height: selectedPOIID == poi.id ? 40 : 32)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    .accessibilityLabel("\(index + 1). \(poi.name)\(visitedPOIIDs.contains(poi.id) ? ", отмечено вами" : "")")
                }
                .annotationTitles(.hidden)
            }
            if let observation, observation.coordinate.isValid,
               observation.accuracy.isFinite, observation.accuracy >= 0,
               Date().timeIntervalSince(observation.observedAt) < 15,
               observation.observedAt.timeIntervalSinceNow < 5 {
                Annotation("Позиция iOS · не проверена", coordinate: observation.coordinate.clCoordinate) {
                    ZStack {
                        Circle().fill(.blue.opacity(0.2)).frame(width: 34, height: 34)
                        Circle().fill(.blue).frame(width: 16, height: 16)
                        Circle().stroke(.white, lineWidth: 3).frame(width: 16, height: 16)
                    }
                    .accessibilityLabel("Последняя позиция iOS, не проверена")
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { MapCompass(); MapScaleView() }
        .environment(\.colorScheme, .light)
        .onAppear { frameRoute() }
        .onChange(of: plan) { _, _ in frameRoute() }
        .accessibilityLabel(plan.isDemo ? "Карта демонстрационного маршрута" : "Карта прогулки")
    }

    private func frameRoute() {
        let coordinates = (plan.legs.flatMap(\.coordinates) + plan.pois.map(\.coordinate)).filter(\.isValid)
        guard let first = coordinates.first else { return }
        let minLat = coordinates.map(\.latitude).min() ?? first.latitude
        let maxLat = coordinates.map(\.latitude).max() ?? first.latitude
        let minLon = coordinates.map(\.longitude).min() ?? first.longitude
        let maxLon = coordinates.map(\.longitude).max() ?? first.longitude
        position = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.006, (maxLat - minLat) * 1.45),
                                   longitudeDelta: max(0.006, (maxLon - minLon) * 1.45))
        ))
    }
}

private extension Coordinate {
    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
