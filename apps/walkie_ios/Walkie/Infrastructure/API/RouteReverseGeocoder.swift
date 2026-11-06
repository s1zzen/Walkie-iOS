import CoreLocation
import Foundation
import WalkieCore

@MainActor
protocol RouteReverseGeocoding {
    func address(for coordinate: Coordinate) async throws -> String?
}

/// Temporary Apple adapter while the Yandex SDK/key is not configured. A map
/// selection is reverse-geocoded; this adapter has no access to a GPS track.
@MainActor
final class AppleRouteReverseGeocoder: RouteReverseGeocoding {
    func address(for coordinate: Coordinate) async throws -> String? {
        let geocoder = CLGeocoder()
        let places = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), preferredLocale: Locale(identifier: "ru_RU"))
        guard let place = places.first else { return nil }
        let street = [place.thoroughfare, place.subThoroughfare].compactMap { $0 }.joined(separator: ", ")
        if !street.isEmpty { return street }
        return place.name ?? place.locality
    }
}
