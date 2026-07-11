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
    var operatorName: String = ""
    var qth: String = ""

    // Template messages shown above the compose field
    var quickMessages: [QuickMessage] = QuickMessage.defaults

    // Transmit
    var wpm: Int = 20                 // keying speed, words per minute
    var toneHz: Int = 600             // sidetone / audio tone
    var txLevel: Double = 0.8         // output gain, 0–1

    // Receive
    var decoder: CWDecoder = .diversity
    var minWPM: Int = 5
    var maxWPM: Int = 45
    /// Also decode the strongest off-channel signals into the Band Monitor
    /// (skimmer). The primary conversation channel is unaffected.
    var skimmerEnabled: Bool = false

    /// Float the template the standard QSO exchange calls for next.
    var guidedQSO: Bool = true

    // Behaviour
    var keepScreenOn: Bool = false

    init() {}

    /// Every field decodes with a fallback so adding a setting never
    /// invalidates a stored blob (which would silently reset the station).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        callsign = (try? c.decode(String.self, forKey: .callsign)) ?? ""
        grid = (try? c.decode(String.self, forKey: .grid)) ?? ""
        operatorName = (try? c.decode(String.self, forKey: .operatorName)) ?? ""
        qth = (try? c.decode(String.self, forKey: .qth)) ?? ""
        quickMessages = (try? c.decode([QuickMessage].self, forKey: .quickMessages)) ?? QuickMessage.defaults
        wpm = (try? c.decode(Int.self, forKey: .wpm)) ?? 20
        toneHz = (try? c.decode(Int.self, forKey: .toneHz)) ?? 600
        txLevel = (try? c.decode(Double.self, forKey: .txLevel)) ?? 0.8
        self.decoder = (try? c.decode(CWDecoder.self, forKey: .decoder)) ?? .diversity
        minWPM = (try? c.decode(Int.self, forKey: .minWPM)) ?? 5
        maxWPM = (try? c.decode(Int.self, forKey: .maxWPM)) ?? 45
        skimmerEnabled = (try? c.decode(Bool.self, forKey: .skimmerEnabled)) ?? false
        guidedQSO = (try? c.decode(Bool.self, forKey: .guidedQSO)) ?? true
        keepScreenOn = (try? c.decode(Bool.self, forKey: .keepScreenOn)) ?? false
    }

    /// Whether the operator has entered the minimum needed to transmit.
    var isConfigured: Bool {
        !callsign.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static let toneRange: ClosedRange<Double> = 400...1000
    static let wpmRange: ClosedRange<Double> = 5...50
}
