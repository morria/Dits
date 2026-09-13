// The keyer must never reach for a Bluetooth device on its own unless
// it says it's a Morserino: the Nordic UART Service it scans for is a
// generic serial profile, and connecting to a stranger's gadget raises
// an iPadOS pairing sheet the operator can't make go away.

import XCTest
@testable import Dits

final class MorserinoIdentityTests: XCTestCase {
    func testOnlyMorserinoNamesQualifyForAutoConnect() {
        XCTAssertTrue(MorserinoKeyer.looksLikeMorserino("Morserino-32"))
        XCTAssertTrue(MorserinoKeyer.looksLikeMorserino("morserino"))
        XCTAssertTrue(MorserinoKeyer.looksLikeMorserino("M32-1A2B"))
        XCTAssertFalse(MorserinoKeyer.looksLikeMorserino("Adafruit Bluefruit LE"))
        XCTAssertFalse(MorserinoKeyer.looksLikeMorserino("Unnamed device"))
        XCTAssertFalse(MorserinoKeyer.looksLikeMorserino(nil))
    }
}
