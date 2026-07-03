import XCTest
@testable import Dits

final class CWMacrosTests: XCTestCase {

    func testCQCall() {
        XCTAssertEqual(CWMacros.cqCall(callsign: "W2ASM"), "CQ CQ CQ DE W2ASM W2ASM K")
        XCTAssertEqual(CWMacros.cqCall(callsign: ""), "CQ CQ CQ K")
    }

    func testReplyOpener() {
        XCTAssertEqual(CWMacros.reply(to: "K1ABC", callsign: "W2ASM"), "K1ABC DE W2ASM ")
        XCTAssertEqual(CWMacros.reply(to: "k1abc", callsign: ""), "K1ABC DE ")
    }

    func testChipsIncludeMyCallAndCounterparty() {
        let chips = CWMacros.chips(callsign: "W2ASM", counterparty: "K1ABC")
        let labels = chips.map(\.label)
        XCTAssertTrue(labels.contains("DE W2ASM"))
        XCTAssertTrue(labels.contains("K1ABC"))
        XCTAssertTrue(labels.contains("73"))
    }
}
