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

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        wpm: Int,
        signal: Int,
        toneHz: Int,
        callsign: String? = nil
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.wpm = wpm
        self.signal = signal
        self.toneHz = toneHz
        self.callsign = callsign
    }
}
