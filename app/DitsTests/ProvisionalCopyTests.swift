// Provisional copy: the decoder streams characters immediately, may
// revise a segment as a whole from its retained keying timeline, and
// finalizes it once the horizon passes. The app shows the copy gray
// until then, wherever it has landed — pending, or already a message.

import XCTest
import AmateurDigitalCore
@testable import Dits

@MainActor
final class ProvisionalCopyTests: XCTestCase {

    private var radio: RadioController!

    override func setUp() async throws {
        try await super.setUp()
        radio = RadioController()
        for conversation in radio.conversations { radio.deleteConversation(conversation.id) }
        radio.settings.callsign = "W2ASM"
    }

    override func tearDown() async throws {
        for conversation in radio.conversations { radio.deleteConversation(conversation.id) }
        radio = nil
        try await super.tearDown()
    }

    private func type(_ text: String, segment: Int) {
        for c in text { radio.applyTextEvent(.character(c, segmentID: segment)) }
    }

    private func message(in id: UUID) -> Dits.Message? { radio.conversation(id: id)?.messages.last }

    func testCharactersAccumulateAsLiveText() {
        type("CQ CQ", segment: 0)
        XCTAssertEqual(radio.liveText, "CQ CQ")
        type("DE W1AW", segment: 1)
        XCTAssertEqual(radio.liveText, "CQ CQ DE W1AW", "segments join on a word gap")
    }

    func testRevisionBeforeCommitRewritesLiveText() {
        type("CQ CO", segment: 0)
        radio.applyTextEvent(.revise(segmentID: 0, text: "CQ CQ"))
        XCTAssertEqual(radio.liveText, "CQ CQ")
    }

    func testCommittedMessageIsProvisionalUntilFinalized() {
        let thread = radio.openConversation("K1ABC")
        radio.setVisibleConversation(thread)
        type("UR RST 5NN", segment: 3)
        radio.commitSegment()

        guard let committed = message(in: thread) else { return XCTFail("copy should have landed in the thread") }
        XCTAssertEqual(committed.text, "UR RST 5NN")
        XCTAssertEqual(committed.provisionalFrom, 0, "nothing is final yet")
        XCTAssertTrue(radio.monitor.last?.isProvisional ?? false)

        radio.applyTextEvent(.revise(segmentID: 3, text: "UR RST 599"))
        XCTAssertEqual(message(in: thread)?.text, "UR RST 599", "a revision edits the committed bubble in place")
        XCTAssertEqual(radio.monitor.last?.text, "UR RST 599")

        radio.applyTextEvent(.finalize(segmentID: 3))
        XCTAssertNil(message(in: thread)?.provisionalFrom, "finalized copy turns black")
        XCTAssertFalse(radio.monitor.last?.isProvisional ?? true)

        radio.applyTextEvent(.revise(segmentID: 3, text: "GARBAGE"))
        XCTAssertEqual(message(in: thread)?.text, "UR RST 599", "no revision after finalize")
    }

    func testFinalPrefixIsBlackAndTailGray() {
        let thread = radio.openConversation("K1ABC")
        radio.setVisibleConversation(thread)
        type("CQ CQ", segment: 0)
        radio.applyTextEvent(.finalize(segmentID: 0))
        type("DE W1AW", segment: 1)
        radio.commitSegment()

        let committed = message(in: thread)
        XCTAssertEqual(committed?.text, "CQ CQ DE W1AW")
        XCTAssertEqual(committed?.provisionalFrom, "CQ CQ ".count, "only the unfinalized segment is gray")

        radio.applyTextEvent(.finalize(segmentID: 1))
        XCTAssertNil(message(in: thread)?.provisionalFrom)
    }

    func testRevisionUpdatesCallsignOnEveryCopy() {
        let cq = radio.startNewConversation()
        radio.setVisibleConversation(cq)
        type("W2ASM DE K1ABX K", segment: 5)
        radio.commitSegment()

        let wrong = radio.conversations.first { $0.counterparty == "K1ABX" }
        XCTAssertNotNil(wrong, "the provisional callsign opened a thread")
        radio.applyTextEvent(.revise(segmentID: 5, text: "W2ASM DE K1ABC K"))

        XCTAssertEqual(message(in: cq)?.text, "W2ASM DE K1ABC K")
        XCTAssertEqual(message(in: cq)?.callsign, "K1ABC")
        XCTAssertEqual(message(in: wrong!.id)?.callsign, "K1ABC", "the copy in the misfiled thread is corrected too")
        XCTAssertEqual(radio.monitor.last?.callsign, "K1ABC")
    }

    func testLateCharacterForCommittedSegmentJoinsItsMessage() {
        let thread = radio.openConversation("K1ABC")
        radio.setVisibleConversation(thread)
        type("73 S", segment: 8)
        radio.commitSegment()
        radio.applyTextEvent(.character("K", segmentID: 8))
        XCTAssertEqual(message(in: thread)?.text, "73 SK")
        XCTAssertEqual(radio.liveText, "", "a straggler never starts a new pending segment")
    }

    func testSanitizedMessagesLoseProvisionalMarks() {
        let conversation = Conversation(counterparty: "K1ABC", messages: [
            Dits.Message(text: "CQ", direction: .received, status: .received, provisionalFrom: 0)
        ])
        let sanitized = RadioController.sanitized([conversation])
        XCTAssertNil(sanitized.first?.messages.first?.provisionalFrom)
    }

    func testProvisionalOffsetSkipsFinalPrefix() {
        typealias S = RadioController.CopySegment
        XCTAssertNil(RadioController.provisionalOffset([S(id: 0, text: "A", isFinal: true)]))
        XCTAssertEqual(RadioController.provisionalOffset([S(id: 0, text: "AB", isFinal: true),
                                                          S(id: 1, text: "", isFinal: false),
                                                          S(id: 2, text: "CD", isFinal: false)]), 3)
        XCTAssertEqual(RadioController.provisionalOffset([S(id: 0, text: "AB", isFinal: false)]), 0)
    }
}
