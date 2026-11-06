import Foundation
import XCTest
@testable import FieldLabCore

final class RouteImportTests: XCTestCase {
    private func parse(_ xml: String) throws -> TestRoute {
        try RouteImport.gpx(data: Data(xml.utf8), name: "Тест")
    }

    func testTrackSegmentsStaySeparate() throws {
        let route = try parse("""
        <gpx version="1.1" xmlns="http://www.topografix.com/GPX/1/1"><trk>
        <trkseg><trkpt lat="55.1" lon="37.1"/><trkpt lat="55.2" lon="37.2"/></trkseg>
        <trkseg><trkpt lat="56.1" lon="38.1"/><trkpt lat="56.2" lon="38.2"/></trkseg>
        </trk></gpx>
        """)
        XCTAssertEqual(route.segments.map(\.count), [2, 2])
        XCTAssertEqual(route.segments[1][0].latitude, 56.1)
        XCTAssertTrue(route.isValid)
    }

    func testRoutePointsAndNamespacedGPX() throws {
        let route = try parse("""
        <g:gpx xmlns:g="http://www.topografix.com/GPX/1/1"><g:rte><g:name>Example</g:name>
        <g:rtept lat="55.1" lon="37.1"/><g:rtept lat="55.2" lon="37.2"/>
        </g:rte></g:gpx>
        """)
        XCTAssertEqual(route.points.count, 2)
        XCTAssertEqual(route.name, "Тест")
    }

    func testMalformedXMLAndWrongRootFail() {
        XCTAssertThrowsError(try parse("<gpx><trk>"))
        XCTAssertThrowsError(try parse("<html/>"))
        XCTAssertThrowsError(try parse(""))
    }

    func testStandaloneWaypointIsNotARoute() {
        XCTAssertThrowsError(try parse("<gpx><wpt lat='55' lon='37'/></gpx>"))
    }

    func testInvalidCoordinatesAreNotSilentlySkipped() {
        for attributes in ["lat='91' lon='37'", "lat='55' lon='181'", "lat='nan' lon='37'", "lat='inf' lon='37'", "lat='no' lon='37'", "lat='55'", "lon='37'"] {
            XCTAssertThrowsError(try parse("<gpx><rte><rtept lat='55' lon='37'/><rtept \(attributes)/><rtept lat='56' lon='38'/></rte></gpx>"), attributes)
        }
    }

    func testEmptyAndSinglePointSegmentsFail() {
        XCTAssertThrowsError(try parse("<gpx><trk><trkseg/></trk></gpx>"))
        XCTAssertThrowsError(try parse("<gpx><rte><rtept lat='55' lon='37'/></rte></gpx>"))
        XCTAssertThrowsError(try parse("<gpx><trk><trkseg/><trkseg><trkpt lat='55' lon='37'/><trkpt lat='56' lon='38'/></trkseg></trk></gpx>"))
    }

    func testWrongPointContainerFails() {
        XCTAssertThrowsError(try parse("<gpx><trk><trkpt lat='55' lon='37'/><trkpt lat='56' lon='38'/></trk></gpx>"))
        XCTAssertThrowsError(try parse("<gpx><rte><trkpt lat='55' lon='37'/><trkpt lat='56' lon='38'/></rte></gpx>"))
    }

    func testPointLimit() {
        let points = String(repeating: "<rtept lat='55' lon='37'/>", count: RouteImport.maximumPoints + 1)
        XCTAssertThrowsError(try parse("<gpx><rte>\(points)</rte></gpx>"))
    }

    func testFileSizeLimit() {
        XCTAssertThrowsError(try RouteImport.gpx(data: Data(repeating: 32, count: RouteImport.maximumFileBytes + 1), name: "Большой"))
    }

    func testInternalAndExternalEntityDeclarationsFail() {
        let suffix = "<gpx><rte><rtept lat='55' lon='37'/><rtept lat='56' lon='38'/></rte></gpx>"
        XCTAssertThrowsError(try parse("<!DOCTYPE gpx [<!ENTITY custom 'hello'>]>" + suffix))
        XCTAssertThrowsError(try parse("<!DOCTYPE gpx [<!ENTITY custom SYSTEM 'file:///does-not-exist'>]>" + suffix))
        XCTAssertThrowsError(try parse("<!DOCTYPE gpx SYSTEM 'https://example.invalid/gpx.dtd'>" + suffix))
        let utf16 = ("<?xml version='1.0' encoding='UTF-16'?><!DOCTYPE gpx [<!ENTITY custom 'hello'>]>" + suffix).data(using: .utf16)!
        XCTAssertThrowsError(try RouteImport.gpx(data: utf16, name: "UTF16"))
    }
}
