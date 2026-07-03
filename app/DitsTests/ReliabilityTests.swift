import XCTest
@testable import Dits

final class ReliabilityTests: XCTestCase {

    // MARK: Segment commit delay scales with copied speed

    func testCommitDelayScalesWithWPM() {
        // Slow CW has long word gaps — a fixed 2 s delay would split
        // transmissions. 5 WPM word gap = 1.68 s → delay must exceed it.
        XCTAssertEqual(RadioController.commitDelay(forWPM: 5), 4.0, accuracy: 0.01)   // capped
        XCTAssertGreaterThan(RadioController.commitDelay(forWPM: 8), 7 * 1.2 / 8)
        // Fast CW commits promptly instead of waiting a fixed 2 s.
        XCTAssertEqual(RadioController.commitDelay(forWPM: 30), 1.2, accuracy: 0.01)  // floor
        XCTAssertEqual(RadioController.commitDelay(forWPM: 40), 1.2, accuracy: 0.01)
        // Mid speeds sit between.
        let mid = RadioController.commitDelay(forWPM: 12)
        XCTAssertGreaterThan(mid, 1.2)
        XCTAssertLessThan(mid, 4.0)
    }

    // MARK: Stuck outgoing messages are failed on load

    func testSanitizeMarksInFlightMessagesFailed() {
        var conversation = Conversation(counterparty: "K1ABC")
        conversation.messages = [
            Message(text: "A", direction: .transmitted, status: .queued),
            Message(text: "B", direction: .transmitted, status: .sending),
            Message(text: "C", direction: .transmitted, status: .sent),
            Message(text: "D", direction: .received, status: .received),
        ]
        let out = RadioController.sanitized([conversation])[0].messages
        XCTAssertEqual(out[0].status, .failed, "queued must not survive relaunch")
        XCTAssertEqual(out[1].status, .failed, "sending must not survive relaunch")
        XCTAssertEqual(out[2].status, .sent)
        XCTAssertEqual(out[3].status, .received)
    }

    // MARK: Macro identity is stable across recomputation

    func testMacroIdentityStable() {
        let a = CWMacros.chips(callsign: "W2ASM", counterparty: "K1ABC")
        let b = CWMacros.chips(callsign: "W2ASM", counterparty: "K1ABC")
        XCTAssertEqual(a.map(\.id), b.map(\.id), "ids must not change between body evaluations")
        XCTAssertEqual(Set(a.map(\.id)).count, a.count, "ids must be unique within a row")
    }

    // MARK: Maidenhead domain edges

    func testMaidenheadDomainEdges() {
        // Exactly lat 90 / lon 180 must clamp into the valid field range.
        let northPole = Maidenhead.grid(latitude: 90, longitude: 180)
        XCTAssertTrue(northPole.first.map { ("A"..."R").contains(String($0)) } ?? false,
                      "field letter out of range: \(northPole)")
        XCTAssertTrue(Maidenhead.isValid(String(northPole.prefix(4))))
    }
}
