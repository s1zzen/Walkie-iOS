import Foundation
import MapKit

@MainActor
final class RouteService {
    /// Apple MapKit строит пеший путь между выбранными точками.
    /// При недоступности сервиса не подменяем маршрут прямой линией.
    func walkingRoute(through points: [GeoPoint], name: String) async throws -> TestRoute {
        guard (2...8).contains(points.count), points.allSatisfy(\.isValid) else {
            throw FieldLabError.message("Для построения нужны от 2 до 8 корректных точек.")
        }
        var segments: [[GeoPoint]] = []
        var totalPoints = 0
        for index in 0..<(points.count - 1) {
            try Task.checkCancellation()
            let request = MKDirections.Request()
            request.source = mapItem(for: points[index])
            request.destination = mapItem(for: points[index + 1])
            request.transportType = .walking
            request.requestsAlternateRoutes = false
            let directions = MKDirections(request: request)
            let response: MKDirections.Response
            do {
                response = try await withTaskCancellationHandler {
                    try await directions.calculate()
                } onCancel: {
                    Task { @MainActor in directions.cancel() }
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw FieldLabError.message("Apple Maps не смог построить пеший участок \(index + 1). Нужен интернет и поддержка маршрутизации в этом месте. Можно импортировать GPX или явно выбрать ручной маршрут. \(error.localizedDescription)")
            }
            try Task.checkCancellation()
            guard let route = response.routes.first, route.polyline.pointCount >= 2 else {
                throw FieldLabError.message("Apple Maps не вернул пеший маршрут для участка \(index + 1).")
            }
            totalPoints += route.polyline.pointCount
            guard totalPoints <= RouteImport.maximumPoints else {
                throw FieldLabError.message("Маршрут содержит больше 10 000 точек. Выберите более короткую прогулку.")
            }
            var coordinates = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: route.polyline.pointCount)
            route.polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: coordinates.count))
            let segment = coordinates.map { GeoPoint(latitude: $0.latitude, longitude: $0.longitude) }
            guard segment.allSatisfy(\.isValid) else {
                throw FieldLabError.message("Apple Maps вернул некорректные координаты.")
            }
            segments.append(segment)
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return TestRoute(name: title.isEmpty ? "Пеший маршрут" : title, source: "Apple MapKit — пешеходная маршрутизация", segments: segments)
    }

    private func mapItem(for point: GeoPoint) -> MKMapItem {
        MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)))
    }

    static func loadSavedRoutes() throws -> [TestRoute] {
        let directory = try routesDirectory()
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var routes: [TestRoute] = []
        for url in urls where url.pathExtension.lowercased() == "json" {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            guard (values.fileSize ?? Int.max) <= RouteImport.maximumFileBytes else {
                throw FieldLabError.message("Сохранённый маршрут \(url.lastPathComponent) превышает 5 МБ.")
            }
            let route: TestRoute
            do { route = try decoder.decode(TestRoute.self, from: Data(contentsOf: url)) }
            catch { throw FieldLabError.message("Не удалось прочитать сохранённый маршрут \(url.lastPathComponent): \(error.localizedDescription)") }
            guard route.isValid, route.points.count <= RouteImport.maximumPoints else {
                throw FieldLabError.message("Некорректный сохранённый маршрут: \(url.lastPathComponent).")
            }
            routes.append(route)
        }
        return routes.sorted { $0.createdAt > $1.createdAt }
    }

    static func save(_ route: TestRoute) throws {
        guard route.isValid, route.points.count <= RouteImport.maximumPoints else {
            throw FieldLabError.message("Нельзя сохранить некорректный или слишком большой маршрут.")
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(route)
        guard data.count <= RouteImport.maximumFileBytes else { throw FieldLabError.message("Маршрут превышает 5 МБ.") }
        let url = try routesDirectory().appendingPathComponent(route.id.uuidString).appendingPathExtension("json")
        try data.write(to: url, options: [.atomic])
    }

    private static func routesDirectory() throws -> URL {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            throw FieldLabError.message("Папка Documents недоступна.")
        }
        let directory = documents.appendingPathComponent("Routes", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
