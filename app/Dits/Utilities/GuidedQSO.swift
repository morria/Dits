// Guided QSO: given the conversation so far, which template does the
// standard exchange call for next? Pure suggestion — the chip is floated
// and highlighted, never sent. This is the script prompter that teaches
// a novice the CQ → reply → RST → name → QTH → 73 flow by doing.

import Foundation

enum GuidedQSO {

    /// Label of the template to float first, or nil for no suggestion.
    /// Labels match the QuickMessage defaults; a renamed template simply
    /// drops out of guidance.
    static func suggestion(messages: [Message], counterparty: String,
                           available: [String]) -> String? {
        let received = messages.filter { $0.direction == .received }.map(\.text)
        let sent = messages.filter { $0.direction == .transmitted }.map(\.text)
        let receivedAll = received.joined(separator: " ").uppercased()
        let sentAll = sent.joined(separator: " ").uppercased()

        func offer(_ label: String) -> String? {
            available.contains(label) ? label : nil
        }

        // Nothing yet: open the exchange.
        if messages.isEmpty {
            return counterparty == "CQ" ? offer("CQ") : offer("Reply")
        }

        // They closed — close back.
        if lastContains(received, any: ["73", "<SK>", " SK"]) && !sentAll.contains("73") {
            return offer("73")
        }

        // Haven't answered their call yet.
        if sent.isEmpty {
            return counterparty == "CQ" ? offer("CQ") : offer("Reply")
        }

        // Standard exchange order: report, name, QTH.
        if !containsReport(sentAll) {
            return offer("RST")
        }
        if containsReport(receivedAll), !sentAll.contains(" OP ") && !sentAll.hasPrefix("OP ") {
            return offer("Name")
        }
        if receivedAll.contains(" OP ") || receivedAll.contains("NAME") {
            if !sentAll.contains("QTH") { return offer("QTH") }
        }
        if receivedAll.contains("QTH"), !sentAll.contains("73") {
            return offer("73")
        }
        return nil
    }

    private static func containsReport(_ text: String) -> Bool {
        text.contains("RST") || text.contains("599") || text.contains("5NN")
    }

    private static func lastContains(_ texts: [String], any needles: [String]) -> Bool {
        guard let last = texts.last?.uppercased() else { return false }
        return needles.contains { last.contains($0) }
    }
}
