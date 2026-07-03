// One-tap operating shortcuts shown above the keyboard. CW QSOs are
// built from a small, stable vocabulary of prosigns and abbreviations —
// surfacing them as chips is what makes sending fast and beginner-proof.

import Foundation

struct CWMacro: Identifiable, Equatable {
    let label: String        // shown on the chip
    let insert: String       // text inserted into the draft
    var prependSpace: Bool = true

    /// Stable identity: labels are unique within a chip row. A fresh UUID
    /// per body evaluation would make SwiftUI tear down and rebuild every
    /// chip on each render.
    var id: String { label }
}

enum CWMacros {

    /// Quick chips. `callsign` personalises the DE and CQ macros.
    static func chips(callsign: String, counterparty: String?) -> [CWMacro] {
        let me = callsign.uppercased()
        var chips: [CWMacro] = []

        if !me.isEmpty {
            chips.append(CWMacro(label: "DE \(me)", insert: "DE \(me)"))
        }
        if let other = counterparty, other != "CQ", !other.isEmpty {
            chips.append(CWMacro(label: other, insert: other))
        }
        chips.append(contentsOf: [
            CWMacro(label: "RST 599", insert: "RST 599 599"),
            CWMacro(label: "=", insert: "="),          // BT — break / new line
            CWMacro(label: "R", insert: "R"),          // received
            CWMacro(label: "K", insert: "K"),          // over (go ahead)
            CWMacro(label: "KN", insert: "KN"),        // over, named station only
            CWMacro(label: "73", insert: "73"),
            CWMacro(label: "TU", insert: "TU"),        // thank you
            CWMacro(label: "AGN?", insert: "AGN?"),    // again?
            CWMacro(label: "QTH", insert: "QTH"),
            CWMacro(label: "NAME", insert: "NAME"),
            CWMacro(label: "SK", insert: "SK"),        // end of contact
        ])
        return chips
    }

    /// A ready-made CQ call, e.g. "CQ CQ CQ DE W2ASM W2ASM K".
    static func cqCall(callsign: String) -> String {
        let me = callsign.uppercased()
        guard !me.isEmpty else { return "CQ CQ CQ K" }
        return "CQ CQ CQ DE \(me) \(me) K"
    }

    /// A reply opener when starting a QSO with a specific station.
    static func reply(to counterparty: String, callsign: String) -> String {
        let me = callsign.uppercased()
        let other = counterparty.uppercased()
        if me.isEmpty { return "\(other) DE " }
        return "\(other) DE \(me) "
    }
}
