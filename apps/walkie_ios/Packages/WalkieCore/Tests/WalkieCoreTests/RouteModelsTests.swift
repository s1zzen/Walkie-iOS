import Foundation
import XCTest
@testable import WalkieCore

final class RouteModelsTests: XCTestCase {
    func testDemoIsExplicitlyIllustrativeAndRoundTrips() throws {
        let plan = RoutePlan.demo
        try plan.validate()
        XCTAssertTrue(plan.isDemo)
        XCTAssertEqual(plan.pois.count, 3)
        XCTAssertTrue(plan.title.contains("не навигация"))
        XCTAssertEqual(try JSONDecoder().decode(RoutePlan.self, from: JSONEncoder().encode(plan)), plan)
    }

    func testCoordinateBoundsAndNonFiniteValues() {
        XCTAssertTrue(Coordinate(latitude: -90, longitude: 180).isValid)
        XCTAssertTrue(Coordinate(latitude: 90, longitude: -180).isValid)
        for coordinate in [Coordinate(latitude: 90.001, longitude: 0),
                           Coordinate(latitude: 0, longitude: -180.001),
                           Coordinate(latitude: .nan, longitude: 37),
                           Coordinate(latitude: 55, longitude: .infinity)] {
            XCTAssertFalse(coordinate.isValid)
            XCTAssertThrowsError(try makePlan(coordinate: coordinate).validate()) {
                XCTAssertEqual($0 as? RouteValidationError, .invalidCoordinate)
            }
        }
    }

    func testEmptyRouteIsRejected() {
        let route = RoutePlan(id: "v", routeID: "r", title: "Пустой", pois: [], legs: [], isDemo: false)
        XCTAssertThrowsError(try route.validate()) {
            XCTAssertEqual($0 as? RouteValidationError, .emptyRoute)
        }
    }

    func testSinglePointGeometryIsRejected() {
        let point = Coordinate(latitude: 55, longitude: 37)
        let route = RoutePlan(id: "v", routeID: "r", title: "Тест",
                              pois: [RoutePOI(id: "p", name: "Место", coordinate: point)],
                              legs: [RouteLeg(id: "l", coordinates: [point])], isDemo: false)
        XCTAssertThrowsError(try route.validate()) {
            XCTAssertEqual($0 as? RouteValidationError, .insufficientGeometry)
        }
    }

    func testDuplicatePOIIDsAreRejected() {
        let poi = RoutePlan.demo.pois[0]
        let route = RoutePlan(id: "v", routeID: "r", title: "Тест", pois: [poi, poi],
                              legs: RoutePlan.demo.legs, isDemo: true)
        XCTAssertThrowsError(try route.validate()) {
            XCTAssertEqual($0 as? RouteValidationError, .duplicateIdentifier)
        }
    }

    func testActualContractWithNullableAndMissingOptionalPlaceFields() throws {
        let route = try RouteVersionDecoder.decode(contractData(), title: "Проверочный маршрут")
        XCTAssertEqual(route.id, "de305d54-75b4-431b-adb2-eb6b9e546014")
        XCTAssertEqual(route.routeID, "de305d54-75b4-431b-adb2-eb6b9e546015")
        XCTAssertEqual(route.title, "Проверочный маршрут")
        XCTAssertEqual(route.pois.map(\.id), ["place:1", "place:2", "place:3"])
        XCTAssertNil(route.pois[0].description)
        XCTAssertNil(route.pois[1].description)
        XCTAssertEqual(route.pois[2].description, "Описание")
        XCTAssertEqual(route.pois[0].visitRadiusMeters, 40)
        XCTAssertEqual(route.pois[0].minimumDwellSeconds, 30)
        XCTAssertEqual(route.completionWindowSeconds, 5400)
        XCTAssertEqual(route.legs.count, 3)
        XCTAssertFalse(route.isDemo)
        XCTAssertEqual(route.start, Coordinate(latitude: 55.76, longitude: 37.60))
    }

    func testServerVersionWithInvalidCoordinatesIsRejected() throws {
        let invalid = String(decoding: contractData(), as: UTF8.self)
            .replacingOccurrences(of: "55.76", with: "155.76")
        XCTAssertThrowsError(try RouteVersionDecoder.decode(Data(invalid.utf8))) {
            XCTAssertEqual($0 as? RouteValidationError, .invalidCoordinate)
        }
    }

    func testRequiredFieldCannotBeNull() throws {
        let invalid = String(decoding: contractData(), as: UTF8.self)
            .replacingOccurrences(of: "\"completion_window_s\": 5400", with: "\"completion_window_s\": null")
        XCTAssertThrowsError(try RouteVersionDecoder.decode(Data(invalid.utf8)))
    }

    func testServerSchemaCountersAreValidated() throws {
        let invalid = String(decoding: contractData(), as: UTF8.self)
            .replacingOccurrences(of: "\"stops_count\": 3", with: "\"stops_count\": 5")
        XCTAssertThrowsError(try RouteVersionDecoder.decode(Data(invalid.utf8))) {
            XCTAssertEqual($0 as? RouteValidationError, .invalidServerVersion)
        }
    }

    private func makePlan(coordinate: Coordinate) -> RoutePlan {
        RoutePlan(id: "v", routeID: "r", title: "Тест",
                  pois: [RoutePOI(id: "p", name: "Место", coordinate: coordinate)],
                  legs: [RouteLeg(id: "l", coordinates: [coordinate, Coordinate(latitude: 55, longitude: 37)])],
                  isDemo: false)
    }

    /// Синтетическое тело ответа, не результат обращения к серверу.
    private func contractData() -> Data {
        Data("""
        {
          "id": "de305d54-75b4-431b-adb2-eb6b9e546014",
          "route_id": "de305d54-75b4-431b-adb2-eb6b9e546015",
          "number": 1, "kind": "initial", "created_at": "2026-09-28T12:00:00Z",
          "summary": {"distance_m": 1200, "duration_s": 3600, "walking_s": 1200, "stops_count": 3},
          "start": {"lat": 55.76, "lon": 37.60}, "end": {"lat": 55.77, "lon": 37.62},
          "stops": [
            {"order": 1, "place": {"id": "place:1", "name": "Место 1", "interest": "parks_nature",
              "categories": ["Парк"], "location": {"lat": 55.76, "lon": 37.61}, "description": null,
              "rating": null, "photo_url": null},
              "arrival_offset_s": 100, "visit_s": 600, "walk_from_previous_s": 100,
              "distance_from_start_m": 100, "visit_radius_m": 40, "min_dwell_s": 30, "reasons": ["Парки"]},
            {"order": 2, "place": {"id": "place:2", "name": "Место 2", "interest": "architecture_history",
              "categories": [], "location": {"lat": 55.765, "lon": 37.615}},
              "arrival_offset_s": 900, "visit_s": 600, "walk_from_previous_s": 200,
              "distance_from_start_m": 600, "visit_radius_m": 40, "min_dwell_s": 30, "reasons": ["История"]},
            {"order": 3, "place": {"id": "place:3", "name": "Место 3", "interest": "museums_exhibitions",
              "categories": [], "location": {"lat": 55.77, "lon": 37.62}, "description": "Описание"},
              "arrival_offset_s": 1800, "visit_s": 600, "walk_from_previous_s": 300,
              "distance_from_start_m": 1200, "visit_radius_m": 40, "min_dwell_s": 30, "reasons": ["Музеи"]}
          ],
          "legs": [
            {"from_order": 0, "to_order": 1, "distance_m": 100, "duration_s": 100,
              "points": [{"lat": 55.76, "lon": 37.60}, {"lat": 55.76, "lon": 37.61}]},
            {"from_order": 1, "to_order": 2, "distance_m": 500, "duration_s": 200,
              "points": [{"lat": 55.76, "lon": 37.61}, {"lat": 55.765, "lon": 37.615}]},
            {"from_order": 2, "to_order": 3, "distance_m": 600, "duration_s": 300,
              "points": [{"lat": 55.765, "lon": 37.615}, {"lat": 55.77, "lon": 37.62}]}
          ],
          "completion_window_s": 5400, "rebuilds_left": 3
        }
        """.utf8)
    }
}
