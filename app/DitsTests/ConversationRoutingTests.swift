// Which thread does copied CW land in? CW carries no addressing, so the
// answer is a policy, not a protocol: the newest conversation is the one
// that receives, and starting a new call retires the previous one.

import XCTest
@testable import Dits

@MainActor
final class ConversationRoutingTests: XCTestCase {

    private var radio: RadioController!

    override func setUp() async throws {
        try await super.setUp()
        radio = RadioController()
        // The controller loads whatever the test host last persisted.
        for conversation in radio.conversations {
            radio.deleteConversation(conversation.id)
        }
        radio.settings.callsign = "W2ASM"
        XCTAssertTrue(radio.conversations.isEmpty)
    }

    override func tearDown() async throws {
        for conversation in radio.conversations {
            radio.deleteConversation(conversation.id)
        }
        radio = nil
        try await super.tearDown()
    }

    /// Copy with no "DE <call>" structure, substantial enough to route.
    private func copyOffAir(_ text: String) {
        radio.commitCopy(text, wpm: 18, signal: 70, toneHz: 600)
    }

    private func messages(_ id: UUID) -> [Message] {
        radio.conversation(id: id)?.messages ?? []
    }

    // MARK: Starting a new conversation

    func testNewConversationStartsEmpty() {
        let first = radio.startNewConversation()
        copyOffAir("GM OM TNX FER CALL")
        XCTAssertEqual(messages(first).count, 1)

        let second = radio.startNewConversation()
        XCTAssertNotEqual(first, second, "a new call must be a new thread")
        XCTAssertTrue(messages(second).isEmpty, "the new thread starts empty")
        XCTAssertEqual(messages(first).count, 1, "the old thread keeps its copy")
    }

    func testNewConversationReusesAnUntouchedThread() {
        let first = radio.startNewConversation()
        let second = radio.startNewConversation()
        XCTAssertEqual(first, second, "an empty CQ thread isn't duplicated")
        XCTAssertEqual(radio.conversations.count, 1)
    }

    // MARK: Only the newest thread receives

    func testOldConversationStopsReceiving() {
        let old = radio.startNewConversation()
        copyOffAir("GM OM TNX FER CALL")
        XCTAssertEqual(messages(old).count, 1)

        let new = radio.startNewConversation()
        copyOffAir("UR RST 599 NAME BOB")

        XCTAssertEqual(messages(old).count, 1, "the retired thread gains nothing")
        XCTAssertEqual(messages(new).count, 1, "the new thread receives instead")
        XCTAssertEqual(messages(new).first?.text, "UR RST 599 NAME BOB")
    }

    /// A station that identifies itself owns the copy, and takes over as the
    /// thread that subsequent unaddressed overs route into.
    func testParsedCallsignTakesOverRouting() {
        let cq = radio.startNewConversation()
        copyOffAir("W2ASM DE K1ABC K1ABC K")

        guard let named = radio.conversations.first(where: { $0.counterparty == "K1ABC" }) else {
            return XCTFail("copy with DE K1ABC should open a thread for K1ABC")
        }
        XCTAssertEqual(named.messages.count, 1)

        copyOffAir("UR RST 599 NAME BOB")
        XCTAssertEqual(messages(named.id).count, 2, "the QSO continues in K1ABC's thread")
        XCTAssertEqual(messages(cq).count, 0, "the CQ thread was never keyed, so no echo")
    }

    /// Answering stations arrive at the same callsign twice; copy joins the
    /// newest thread with them, not a stale one.
    func testCopyJoinsNewestThreadWithStation() {
        let stale = radio.openConversation("K1ABC")
        copyOffAir("W2ASM DE K1ABC K")
        XCTAssertEqual(messages(stale).count, 1, "the existing thread receives")
        XCTAssertEqual(radio.conversations.filter { $0.counterparty == "K1ABC" }.count, 1)
    }

    /// Band noise decoded as a lone character never becomes a message.
    func testJunkCopyIsNotRouted() {
        let cq = radio.startNewConversation()
        copyOffAir("E E EE T EI E")
        XCTAssertTrue(messages(cq).isEmpty, "dit-noise stays in the monitor")
        XCTAssertFalse(radio.monitor.isEmpty, "…but the raw monitor still shows it")
    }

    // MARK: Persistence migration

    /// Threads stored before conversations had identity must survive decode.
    func testLegacyConversationDecodesWithIdentity() throws {
        let legacy = """
        [{"counterparty":"K1ABC","messages":[],"lastReadAt":700000000.0}]
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode([Conversation].self, from: legacy)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].counterparty, "K1ABC")
        XCTAssertEqual(decoded[0].createdAt, Date(timeIntervalSinceReferenceDate: 700000000.0),
                       "an empty legacy thread is dated by when it was opened")
    }

    func testConversationRoundTripsThroughJSON() throws {
        let original = Conversation(
            counterparty: "CQ",
            messages: [Message(text: "CQ DE W2ASM K", direction: .transmitted, status: .sent)],
            lastReadAt: Date(timeIntervalSinceReferenceDate: 1000)
        )
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([Conversation].self, from: data)
        XCTAssertEqual(decoded.first?.id, original.id, "identity survives a save/load cycle")
        XCTAssertEqual(decoded.first?.createdAt, original.createdAt)
    }
}
