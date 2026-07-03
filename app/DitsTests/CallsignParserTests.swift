import XCTest
@testable import Dits

final class CallsignParserTests: XCTestCase {

    func testValidCallsigns() {
        for call in ["W2ASM", "K1ABC", "N0CALL", "VE3XYZ", "G0ABC", "2E0ABC", "4X4AA", "W1AW"] {
            XCTAssertTrue(CallsignParser.isCallsign(call), "\(call) should be valid")
        }
    }

    func testInvalidCallsigns() {
        for token in ["CQ", "DE", "73", "TEST", "HELLO", "QTH", "ABC", "599"] {
            XCTAssertFalse(CallsignParser.isCallsign(token), "\(token) should be invalid")
        }
    }

    func testPortableSuffixesAndPrefixes() {
        XCTAssertTrue(CallsignParser.isCallsign("W2ASM/4"))
        XCTAssertTrue(CallsignParser.isCallsign("DL/W2ASM/P"))
    }

    func testCounterpartyAfterDE() {
        let text = "CQ CQ DE W1AW W1AW K"
        XCTAssertEqual(CallsignParser.counterparty(in: text, myCall: "W2ASM"), "W1AW")
    }

    func testCounterpartyExcludesMyCall() {
        let text = "W2ASM DE K1ABC R UR 599"
        XCTAssertEqual(CallsignParser.counterparty(in: text, myCall: "W2ASM"), "K1ABC")
    }

    func testCounterpartyNilWhenNone() {
        XCTAssertNil(CallsignParser.counterparty(in: "CQ CQ TEST K", myCall: "W2ASM"))
    }

    func testCallsignsInText() {
        let calls = CallsignParser.callsigns(in: "W2ASM de K1ABC tnx 73")
        XCTAssertEqual(calls, ["W2ASM", "K1ABC"])
    }
}
