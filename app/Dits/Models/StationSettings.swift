// Operator and operating settings. Persisted as JSON in UserDefaults.

import Foundation

/// Which receive decoder the app runs. The classic Goertzel state-machine
/// is fast and proven; the Bayesian decoder is stronger in noise; the
/// diversity decoder runs both and fuses their output.
enum CWDecoder: String, Codable, CaseIterable, Identifiable {
    case classic
    case bayesian
    case diversity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic:   return "Classic"
        case .bayesian:  return "Bayesian"
        case .diversity: return "Diversity"
        }
    }

    var detail: String {
        switch self {
        case .classic:   return "Fast Goertzel state machine. Great in clean conditions."
        case .bayesian:  return "Probabilistic decoder that holds up deeper into the noise."
        case .diversity: return "Runs both decoders and fuses them. Best overall copy."
        }
    }
}

struct StationSettings: Codable, Equatable {

    // Station identity
    var callsign: String = ""
    var grid: String = ""

    // Transmit
    var wpm: Int = 20                 // keying speed, words per minute
    var toneHz: Int = 600             // sidetone / audio tone
    var txLevel: Double = 0.8         // output gain, 0–1

    // Receive
    var decoder: CWDecoder = .diversity
    var minWPM: Int = 5
    var maxWPM: Int = 45

    // Behaviour
    var keepScreenOn: Bool = false

    /// Whether the operator has entered the minimum needed to transmit.
    var isConfigured: Bool {
        !callsign.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static let toneRange: ClosedRange<Double> = 400...1000
    static let wpmRange: ClosedRange<Double> = 5...50
}
