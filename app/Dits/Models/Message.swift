// A single CW message — either copied off the air (received) or keyed
// out by the operator (transmitted). Mirrors the Messages-app model: a
// direction plus a delivery status that drives the bubble's appearance.

import Foundation

struct Message: Identifiable, Equatable, Codable {

    enum Direction: String, Codable {
        case received
        case transmitted
    }

    /// Lifecycle of an outgoing message. Received messages are always
    /// `.received`.
    enum Status: String, Codable {
        case received   // copied off the air
        case queued     // waiting to key
        case sending    // audio is keying now
        case sent       // finished keying
        case failed     // cancelled or errored
    }

    let id: UUID
    var text: String
    var timestamp: Date
    var direction: Direction
    var status: Status

    /// Counterparty callsign: parsed from the copy for received messages,
    /// the addressed station for transmitted ones. `nil` when unknown.
    var callsign: String?

    /// Decoded (RX) or configured (TX) speed in words per minute.
    var wpm: Int?

    /// Audio tone in Hz the message was copied or sent on.
    var toneHz: Int?

    /// Relative signal strength at decode time, 0–100. RX only.
    var signal: Int?

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Date = Date(),
        direction: Direction,
        status: Status,
        callsign: String? = nil,
        wpm: Int? = nil,
        toneHz: Int? = nil,
        signal: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.direction = direction
        self.status = status
        self.callsign = callsign
        self.wpm = wpm
        self.toneHz = toneHz
        self.signal = signal
    }
}
