// Plain-English translations of the CW abbreviations that carry most
// real traffic. Powers the "Explain" action on received messages and
// the glossary in Settings — the learning aid a novice needs to read
// their first QSOs.

import Foundation

enum CWAbbreviations {

    /// Abbreviation → plain English. Uppercase keys.
    static let table: [String: String] = [
        "CQ": "calling any station",
        "DE": "from (this is)",
        "K": "over — go ahead",
        "KN": "over — named station only",
        "R": "received / roger",
        "RST": "signal report (readability, strength, tone)",
        "599": "perfect signal report",
        "5NN": "perfect signal report (contest shorthand)",
        "UR": "your / you're",
        "ES": "and",
        "DX": "long-distance station",
        "OM": "old man (fellow operator)",
        "YL": "young lady (female operator)",
        "XYL": "wife",
        "OP": "operator name",
        "QTH": "my location is",
        "QRL": "is this frequency in use?",
        "QRM": "interference from other signals",
        "QRN": "static / atmospheric noise",
        "QRP": "low power",
        "QRS": "please send slower",
        "QRQ": "please send faster",
        "QRT": "shutting down / stopping",
        "QRZ": "who is calling me?",
        "QSB": "your signal is fading",
        "QSL": "I confirm receipt",
        "QSO": "a contact / conversation",
        "QSY": "changing frequency",
        "QRX": "wait / stand by",
        "WX": "weather",
        "TEMP": "temperature",
        "RIG": "radio equipment",
        "ANT": "antenna",
        "PWR": "power",
        "FB": "fine business (excellent)",
        "HI": "laughter",
        "HW": "how do you copy?",
        "CPY": "copy",
        "CPI": "copy",
        "TNX": "thanks",
        "TU": "thank you",
        "PSE": "please",
        "AGN": "again",
        "NR": "number / near",
        "ABT": "about",
        "HR": "here",
        "VY": "very",
        "GM": "good morning",
        "GA": "good afternoon",
        "GE": "good evening",
        "GN": "good night",
        "GL": "good luck",
        "73": "best regards",
        "88": "love and kisses",
        "BK": "back to you (break)",
        "BT": "pause / new section",
        "AR": "end of message",
        "SK": "end of contact",
        "<SK>": "end of contact",
        "<CT>": "starting transmission",
        "<SOS>": "distress call",
        "<SN>": "understood",
        "CL": "closing station",
        "SRI": "sorry",
        "CUL": "see you later",
        "CUAGN": "see you again",
        "GUD": "good",
        "NW": "now",
        "TT": "that",
        "B4": "before",
        "RPT": "repeat",
        "TEST": "contest / test transmission",
    ]

    /// Sorted entries for the glossary screen.
    static let glossary: [(term: String, meaning: String)] = table
        .map { ($0.key, $0.value) }
        .sorted { $0.0 < $1.0 }

    /// Translate the recognizable abbreviations in a message, in the order
    /// they appear (deduplicated). Empty when nothing is recognized.
    static func explain(_ text: String) -> [(term: String, meaning: String)] {
        var seen = Set<String>()
        var result: [(String, String)] = []
        for word in text.uppercased().split(separator: " ") {
            let token = String(word)
            guard !seen.contains(token), let meaning = table[token] else { continue }
            seen.insert(token)
            result.append((token, meaning))
        }
        return result
    }
}
