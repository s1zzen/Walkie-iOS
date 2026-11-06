import XCTest
@testable import FieldLabCore

final class FieldLogJSONTests: XCTestCase {
    func testDatesWithAndWithoutFractionalSeconds() throws {
        struct Wrapper: Decodable { let at: Date }
        let decoder = FieldLogJSON.decoder()
        let fractional = try decoder.decode(Wrapper.self, from: Data("{\"at\":\"2026-09-14T18:20:01.123Z\"}".utf8))
        let whole = try decoder.decode(Wrapper.self, from: Data("{\"at\":\"2026-09-14T18:20:01Z\"}".utf8))
        XCTAssertEqual(fractional.at.timeIntervalSince(whole.at), 0.123, accuracy: 0.001)
        XCTAssertThrowsError(try decoder.decode(Wrapper.self, from: Data("{\"at\":\"bad\"}".utf8)))
    }
}
