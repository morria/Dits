import XCTest
import AmateurDigitalCore
@testable import Dits

/// End-to-end check of the capability the whole app rests on: text the
/// service keys out is recovered by the Core decoder. Runs the real
/// modulator and demodulator over clean synthetic audio.
final class CWRoundtripTests: XCTestCase {

    private final class Collector: CWModemDelegate {
        var text = ""
        func modem(_ modem: CWModem, didDecode character: Character, atFrequency frequency: Double) {
            text.append(character)
        }
        func modem(_ modem: CWModem, signalDetected detected: Bool, atFrequency frequency: Double) {}
    }

    func testEncodeProducesAudio() {
        var settings = StationSettings()
        settings.wpm = 20
        settings.toneHz = 600
        let service = CWModemService(settings: settings)
        let samples = service.encode("PARIS", settings: settings)
        XCTAssertGreaterThan(samples.count, 0)
        // Every sample must be within the normalized range.
        XCTAssertLessThanOrEqual(samples.map { abs($0) }.max() ?? 0, 1.0001)
    }

    func testRoundTripRecoversText() {
        var settings = StationSettings()
        settings.callsign = "W2ASM"
        settings.wpm = 22
        settings.toneHz = 600

        let service = CWModemService(settings: settings)
        let message = "CQ TEST DE W2ASM W2ASM K"
        let samples = service.encode(message, settings: settings)
        XCTAssertGreaterThan(samples.count, 48000)   // at least ~1s of audio

        let decoder = CWModem(configuration: CWConfiguration(
            toneFrequency: 600, wpm: 22, sampleRate: 48000))
        let collector = Collector()
        decoder.delegate = collector

        // Mirror the real app, which decodes a continuous audio stream:
        // feed half a second of ambient silence first so the decoder
        // establishes its noise floor before the signal arrives.
        decoder.process(samples: [Float](repeating: 0, count: 24000))

        var i = 0
        let chunk = 2048
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            decoder.process(samples: Array(samples[i..<end]))
            i = end
        }
        // Trailing silence flushes the final character.
        decoder.process(samples: [Float](repeating: 0, count: 24000))

        let decoded = collector.text.uppercased()
        XCTAssertTrue(decoded.contains("W2ASM"), "decoded: «\(decoded)»")
        XCTAssertTrue(decoded.contains("TEST"), "decoded: «\(decoded)»")
        XCTAssertTrue(decoded.contains("CQ"), "decoded: «\(decoded)»")
    }
}
