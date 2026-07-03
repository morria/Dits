import XCTest
import CoreLocation
@testable import Dits

final class MaidenheadTests: XCTestCase {

    func testKnownGrids() {
        // Newington, CT (ARRL HQ) ≈ FN31
        let fn31 = Maidenhead.grid(latitude: 41.714, longitude: -72.727)
        XCTAssertTrue(fn31.hasPrefix("FN31"), "got \(fn31)")

        // London ≈ IO91
        let io91 = Maidenhead.grid(latitude: 51.5, longitude: -0.1)
        XCTAssertTrue(io91.hasPrefix("IO91"), "got \(io91)")
    }

    func testRoundTripCoordinate() {
        let grid = Maidenhead.grid(latitude: 40.0, longitude: -75.0)
        guard let coord = Maidenhead.coordinate(of: grid) else {
            return XCTFail("no coordinate")
        }
        XCTAssertEqual(coord.latitude, 40.0, accuracy: 0.5)
        XCTAssertEqual(coord.longitude, -75.0, accuracy: 0.5)
    }

    func testDistance() {
        // FN31 (CT) to IO91 (London) is roughly 5500 km.
        let km = Maidenhead.distanceKm(from: "FN31pr", to: "IO91wm")
        XCTAssertNotNil(km)
        XCTAssertEqual(km!, 5500, accuracy: 600)
    }

    func testValidity() {
        XCTAssertTrue(Maidenhead.isValid("FN31"))
        XCTAssertTrue(Maidenhead.isValid("FN31pr"))
        XCTAssertFalse(Maidenhead.isValid("3131"))
        XCTAssertFalse(Maidenhead.isValid("FN"))
    }
}
