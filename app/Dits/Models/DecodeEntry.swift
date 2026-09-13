// One committed transmission in the live band monitor — a chunk of copy
// bounded by a gap in the signal, tagged with the speed and strength it
// was decoded at. This is the raw, unfiltered feed of everything heard.

import Foundation

struct DecodeEntry: Identifiable, Equatable {
    let id: UUID
    var text: String
    var timestamp: Date
    var wpm: Int
    var signal: Int          // 0–100
    var toneHz: Int
    var callsign: String?
    /// The decoder may still revise this copy.
    var isProvisional: Bool
    /// Copied by a skimmer channel, off the tuned frequency.
    var isSkimmed: Bool
    /// Landed in at least one conversation. Copy that stays monitor-only
    /// is shown as such, so "thrown away" is never silent.
    var routed: Bool
    /// A lone character — what band noise decodes as. Shown faint.
    var isNoise: Bool

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        wpm: Int,
        signal: Int,
        toneHz: Int,
        callsign: String? = nil,
        isProvisional: Bool = false,
        isSkimmed: Bool = false,
        routed: Bool = false,
        isNoise: Bool = false
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.wpm = wpm
        self.signal = signal
        self.toneHz = toneHz
        self.callsign = callsign
        self.isProvisional = isProvisional
        self.isSkimmed = isSkimmed
        self.routed = routed
        self.isNoise = isNoise
    }
}
