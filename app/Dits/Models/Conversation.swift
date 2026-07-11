// A thread of messages with one counterparty, keyed by callsign. The
// special counterparty "CQ" collects general / unaddressed calls the
// operator makes when not yet in a QSO.
//
// Threads carry their own identity rather than being keyed by callsign:
// an operator calls CQ many times over an evening, and each call is its
// own conversation. Only one thread at a time is the *active* one that
// unaddressed copy routes into (see RadioController).

import Foundation

struct Conversation: Identifiable, Equatable, Codable {

    let id: UUID

    /// Uppercase callsign, or "CQ" for general calls. Not unique: several
    /// CQ threads can exist, and a station can be worked more than once.
    var counterparty: String
    var messages: [Message]

    /// Everything received at or before this instant is considered read.
    var lastReadAt: Date

    /// Orders an empty thread — a CQ you've just started, before the first
    /// character is keyed — above stale ones in the conversation list.
    let createdAt: Date

    init(
        id: UUID = UUID(),
        counterparty: String,
        messages: [Message] = [],
        lastReadAt: Date = .distantPast,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.counterparty = counterparty
        self.messages = messages
        self.lastReadAt = lastReadAt
        self.createdAt = createdAt
    }

    /// Threads persisted before conversations had identity are keyed only by
    /// callsign; mint an id and date them by their last message so the
    /// operator's history survives the upgrade in the right order.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counterparty = try c.decode(String.self, forKey: .counterparty)
        messages = (try? c.decode([Message].self, forKey: .messages)) ?? []
        lastReadAt = (try? c.decode(Date.self, forKey: .lastReadAt)) ?? .distantPast
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        // An untouched legacy thread has no message to date it by; it was
        // stamped read when the operator opened it, which is when it began.
        createdAt = (try? c.decode(Date.self, forKey: .createdAt))
            ?? messages.first?.timestamp
            ?? lastReadAt
    }

    var lastMessage: Message? { messages.last }

    var lastActivity: Date { messages.last?.timestamp ?? createdAt }

    var unreadCount: Int {
        messages.filter { $0.direction == .received && $0.timestamp > lastReadAt }.count
    }

    var isCQ: Bool { counterparty == "CQ" }
}
