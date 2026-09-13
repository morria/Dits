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
        XCTAssertEqual(radio.monitor.last?.routed, false, "…and the monitor says it went nowhere")
    }

    /// A lone character never becomes a message on its own, even with a
    /// CQ answer window open.
    func testLoneCharacterNeverRoutesOutsideTheVisibleThread() {
        let cq = radio.startNewConversation()
        radio.send("CQ CQ DE W2ASM K", in: cq)
        copyOffAir("E")
        XCTAssertEqual(radio.monitor.last?.isNoise, true)
        XCTAssertEqual(radio.monitor.last?.routed, false)
        XCTAssertFalse(messages(cq).contains { $0.direction == .received })
    }

    func testSkimmerCopyIsMarkedInTheMonitor() {
        radio.commitCopy("CQ DE W1XYZ", wpm: 20, signal: 40, toneHz: 850, channel: .skimmer)
        XCTAssertEqual(radio.monitor.last?.isSkimmed, true)
        XCTAssertEqual(radio.monitor.last?.routed, true, "an identified station is filed under its callsign")
    }

    // MARK: The thread on screen always receives

    /// Opening a thread and watching it is the whole point: whatever the
    /// radio hears on the primary channel lands there, callsign or not,
    /// even a lone "R" the junk gate would otherwise drop.
    func testVisibleThreadReceivesEverythingOnThePrimaryChannel() {
        let thread = radio.openConversation("K1ABC")
        radio.setVisibleConversation(thread)

        copyOffAir("R")
        copyOffAir("TU 73")
        copyOffAir("E E EE T EI E")

        XCTAssertEqual(messages(thread).map(\.text), ["R", "TU 73", "E E EE T EI E"])
        let lone = radio.monitor.first { $0.text == "R" }
        XCTAssertEqual(lone?.isNoise, true, "a lone character shows in the monitor, flagged as probable noise")
        XCTAssertEqual(lone?.routed, true, "…and says where it went")
    }

    /// Skimmer copy is off-frequency: it never lands in the thread on
    /// screen, only in the monitor (and a named thread if it identifies).
    func testSkimmerCopyStaysOutOfTheVisibleThread() {
        let thread = radio.openConversation("K1ABC")
        radio.setVisibleConversation(thread)

        radio.commitCopy("CQ CQ DE W1XYZ K", wpm: 20, signal: 40, toneHz: 800, channel: .skimmer)

        XCTAssertTrue(messages(thread).isEmpty)
        XCTAssertNotNil(radio.conversations.first { $0.counterparty == "W1XYZ" })
        XCTAssertEqual(radio.monitor.count, 1)
    }

    /// Another station identifying itself while a thread is open shows up
    /// where the operator is looking *and* in that station's own thread.
    func testVisibleThreadAlsoShowsOtherStationsCopy() {
        let cq = radio.startNewConversation()
        radio.setVisibleConversation(cq)

        copyOffAir("W2ASM DE K1ABC K1ABC K")

        guard let named = radio.conversations.first(where: { $0.counterparty == "K1ABC" }) else {
            return XCTFail("DE K1ABC should still open a thread for K1ABC")
        }
        XCTAssertEqual(messages(cq).map(\.text), ["W2ASM DE K1ABC K1ABC K"])
        XCTAssertEqual(messages(named.id).map(\.text), ["W2ASM DE K1ABC K1ABC K"])
    }

    /// Copy is never duplicated into the thread on screen when it is the
    /// station's own thread.
    func testVisibleNamedThreadGetsOneCopy() {
        let thread = radio.openConversation("K1ABC")
        radio.setVisibleConversation(thread)
        copyOffAir("W2ASM DE K1ABC K")
        XCTAssertEqual(messages(thread).count, 1)
    }

    /// Leaving the thread restores the normal rules: it stays active for
    /// the QSO window, so substantial overs still land, but junk doesn't.
    func testLeavingThreadRestoresNormalRouting() {
        let thread = radio.openConversation("K1ABC")
        radio.setVisibleConversation(thread)
        radio.clearVisibleConversation(thread)

        copyOffAir("UR RST 599 NAME BOB")
        copyOffAir("E E EE T EI E")

        XCTAssertEqual(messages(thread).map(\.text), ["UR RST 599 NAME BOB"])
    }

    /// Only the thread that is actually on screen may be cleared — the
    /// appear/disappear ordering of a push can report the old thread's
    /// disappearance after the new one appeared.
    func testClearingAnotherThreadIsIgnored() {
        let a = radio.openConversation("K1ABC")
        let b = radio.openConversation("W1XYZ")
        radio.setVisibleConversation(b)
        radio.clearVisibleConversation(a)

        copyOffAir("R")
        XCTAssertEqual(messages(b).count, 1, "b is still the thread on screen")
        XCTAssertTrue(messages(a).isEmpty)
    }

    /// The provisional bubble must appear in the same thread the final
    /// message lands in.
    func testLiveDestinationMatchesCommitDestination() {
        let cq = radio.startNewConversation()
        XCTAssertEqual(radio.liveDestination(for: "UR RST 599"), cq,
                       "unaddressed copy heads for the active thread")
        XCTAssertNil(radio.liveDestination(for: "E E"), "junk heads nowhere")

        let named = radio.openConversation("K1ABC")
        XCTAssertEqual(radio.liveDestination(for: "W2ASM DE K1ABC"), named)

        radio.setVisibleConversation(cq)
        XCTAssertEqual(radio.liveDestination(for: "E E"), cq,
                       "the thread on screen takes everything")
        XCTAssertEqual(radio.liveDestination(for: "W2ASM DE K1ABC"), cq)
    }

    func testDeletingTheVisibleThreadStopsRouting() {
        let thread = radio.openConversation("K1ABC")
        radio.setVisibleConversation(thread)
        radio.deleteConversation(thread)
        copyOffAir("R")
        XCTAssertTrue(radio.conversations.isEmpty, "no thread is resurrected")
    }

    // MARK: Being called

    func testCopyAddressedToMeRaisesAnIncomingCall() {
        copyOffAir("W2ASM DE K1ABC K")
        XCTAssertEqual(radio.incomingCall?.callsign, "K1ABC")
        XCTAssertEqual(radio.incomingCall?.conversationID,
                       radio.conversations.first { $0.counterparty == "K1ABC" }?.id)
    }

    func testGeneralCallIsNotAnIncomingCall() {
        copyOffAir("CQ CQ DE K1ABC K")
        XCTAssertNil(radio.incomingCall, "a CQ addresses nobody")
        copyOffAir("W1XYZ DE K1ABC K")
        XCTAssertNil(radio.incomingCall, "a call to someone else isn't mine")
    }

    func testOpeningTheThreadClearsTheIncomingCall() {
        copyOffAir("W2ASM DE K1ABC K")
        guard let id = radio.incomingCall?.conversationID else { return XCTFail("expected a call") }
        radio.setVisibleConversation(id)
        XCTAssertNil(radio.incomingCall)
        copyOffAir("W2ASM DE K1ABC R R")
        XCTAssertNil(radio.incomingCall, "being called in the thread I'm already in isn't news")
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
