// Template messages (ported from Morserino-iOS): one-tap operating
// messages with {TOKEN} placeholders filled from station settings and
// the open conversation. Chips render above the compose field and
// populate it — they never send directly.

import Foundation

struct QuickMessage: Codable, Equatable, Identifiable {
    var id = UUID()
    var label: String
    var text: String

    static let defaults: [QuickMessage] = [
        QuickMessage(label: "CQ", text: "CQ CQ CQ DE {CALL} {CALL} K"),
        QuickMessage(label: "Reply", text: "{THEIRCALL} DE {CALL} {CALL} K"),
        QuickMessage(label: "RST", text: "UR RST 599 599"),
        QuickMessage(label: "Name", text: "OP {NAME} {NAME}"),
        QuickMessage(label: "QTH", text: "QTH {QTH} {QTH}"),
        QuickMessage(label: "Grid", text: "GRID {GRID} {GRID}"),
        QuickMessage(label: "73", text: "73 TU DE {CALL} SK"),
    ]
}

struct ExpandedTemplate {
    let text: String
    /// Tokens whose backing field is empty — the caller should point the
    /// operator at Settings rather than key an incomplete message.
    let missing: [String]
}

extension StationSettings {

    /// Placeholder tokens, matched case-insensitively as {TOKEN}.
    func templatePlaceholders(theirCall: String?) -> [(token: String, value: String)] {
        [
            ("CALL", callsign),
            ("NAME", operatorName),
            ("QTH", qth),
            ("GRID", grid),
            ("THEIRCALL", theirCall ?? ""),
        ]
    }

    func expand(_ template: String, theirCall: String? = nil) -> ExpandedTemplate {
        var text = template
        var missing: [String] = []
        for (token, value) in templatePlaceholders(theirCall: theirCall) {
            let pattern = "{\(token)}"
            guard text.range(of: pattern, options: .caseInsensitive) != nil else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { missing.append(token) }
            while let range = text.range(of: pattern, options: .caseInsensitive) {
                text.replaceSubrange(range, with: trimmed)
            }
        }
        return ExpandedTemplate(text: text, missing: missing)
    }
}
