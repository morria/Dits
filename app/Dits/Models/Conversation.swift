// A thread of messages with one counterparty, keyed by callsign. The
// special counterparty "CQ" collects general / unaddressed calls the
// operator makes when not yet in a QSO.

import Foundation

struct Conversation: Identifiable, Equatable, Codable {

    /// Uppercase callsign, or "CQ" for general calls.
    var counterparty: String
    var messages: [Message]

    /// Everything received at or before this instant is considered read.
    var lastReadAt: Date

    var id: String { counterparty }

    init(counterparty: String, messages: [Message] = [], lastReadAt: Date = .distantPast) {
        self.counterparty = counterparty
        self.messages = messages
        self.lastReadAt = lastReadAt
    }

    var lastMessage: Message? { messages.last }

    var lastActivity: Date { messages.last?.timestamp ?? .distantPast }

    var unreadCount: Int {
        messages.filter { $0.direction == .received && $0.timestamp > lastReadAt }.count
    }

    var isCQ: Bool { counterparty == "CQ" }
}
