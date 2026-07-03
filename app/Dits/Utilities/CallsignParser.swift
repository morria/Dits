// Lightweight amateur-callsign detection used to route copied CW into
// per-station conversations. CW carries no addressing of its own, so we
// lean on operating convention: the call after "DE" is the sender; a
// "CQ" with no other call is a general call.

import Foundation

enum CallsignParser {

    /// Core ITU shape: a 1–2 char prefix (letters, or letter+digit /
    /// digit+letter), a single call-area digit, then a 1–4 letter suffix.
    /// Anchored; apply to an already-tokenised, slash-stripped word.
    private static let core = try! NSRegularExpression(
        pattern: "^(?:[A-Z]{1,2}|[A-Z][0-9]|[0-9][A-Z])[0-9][A-Z]{1,4}$"
    )

    /// True if `token` looks like a valid callsign once portable
    /// prefixes/suffixes (e.g. "W2ASM/4", "DL/W2ASM/P") are stripped.
    static func isCallsign(_ token: String) -> Bool {
        let core = strippedCore(token)
        guard core.count >= 3 else { return false }
        let range = NSRange(core.startIndex..., in: core)
        return Self.core.firstMatch(in: core, range: range) != nil
    }

    /// Drops a leading "XX/" and a trailing "/Y" (portable / mobile /
    /// QRP markers) and returns the longest segment that parses as a call.
    static func strippedCore(_ token: String) -> String {
        let parts = token.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return token }
        // The real call is usually the longest segment.
        return parts.max(by: { $0.count < $1.count }) ?? token
    }

    /// All callsign-shaped tokens in `text`, uppercased, in order.
    static func callsigns(in text: String) -> [String] {
        let words = text.uppercased().split { !($0.isLetter || $0.isNumber || $0 == "/") }
        return words.map(String.init).filter { isCallsign($0) }
    }

    /// The counterparty in a copied transmission, or nil. Deliberately
    /// conservative: it requires real QSO structure ("DE <call>") so that
    /// noise decoded into a lone callsign-shaped token never spawns a junk
    /// conversation. The call right after "DE" is the sending station.
    static func counterparty(in text: String, myCall: String) -> String? {
        let mine = normalized(myCall)
        let tokens = text.uppercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "/") }
            .map(String.init)

        guard let deIndex = tokens.firstIndex(of: "DE"), deIndex + 1 < tokens.count else {
            return nil
        }
        let deCall = tokens[deIndex + 1]
        guard isCallsign(deCall) else { return nil }

        if normalized(deCall) != mine { return normalized(deCall) }

        // The sender is us (we're reading back our own exchange) — the
        // counterparty is the other callsign addressed in the transmission.
        for token in tokens where isCallsign(token) && normalized(token) != mine {
            return normalized(token)
        }
        return nil
    }

    /// Uppercased, with portable markers preserved for display but
    /// compared on the core call.
    static func normalized(_ call: String) -> String {
        call.uppercased()
    }
}
