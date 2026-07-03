import XCTest
import AmateurDigitalCore
@testable import Dits

/// Decode-quality gates for the decoder configuration the app actually
/// ships (Diversity/DualCWDecoder by default): realistic messages, multiple
/// speeds, and additive noise, streamed in app-sized chunks.
final class CWDecodeQualityTests: XCTestCase {

    private struct SeededNoise {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 1 : seed }
        mutating func nextGaussian() -> Double {
            func next() -> Double {
                state ^= state >> 12
                state ^= state << 25
                state ^= state >> 27
                return Double(state &* 0x2545F4914F6CDD1D) / Double(UInt64.max)
            }
            let u1 = max(next(), 1e-10)
            let u2 = next()
            return (-2.0 * log(u1)).squareRoot() * cos(2.0 * .pi * u2)
        }
    }

    private func addNoise(_ signal: [Float], snrDB: Float, seed: UInt64) -> [Float] {
        let power = signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count))
        let rms = power.squareRoot()
        guard rms > 0 else { return signal }
        let noiseRMS = rms / pow(10.0, snrDB / 20.0)
        var rng = SeededNoise(seed: seed)
        return signal.map { $0 + Float(rng.nextGaussian()) * noiseRMS }
    }

    /// Encode with the app's TX path, decode with DualCWDecoder streamed in
    /// ~85 ms chunks (matching real audio callbacks), and return the text.
    private func roundtrip(_ text: String, wpm: Int, snrDB: Float?, seed: UInt64 = 7) -> String {
        var settings = StationSettings()
        settings.wpm = wpm
        settings.toneHz = 600
        let service = CWModemService(settings: settings)
        var samples = service.encode(text, settings: settings)
        if let snrDB { samples = addNoise(samples, snrDB: snrDB, seed: seed) }
        samples.append(contentsOf: [Float](repeating: 0, count: 48_000))  // trailing silence

        let config = CWConfiguration(toneFrequency: 600, wpm: Double(wpm), sampleRate: 48_000)
        let decoder = DualCWDecoder(configuration: config)
        var decoded = ""
        decoder.onCharacterDecoded = { char, _ in decoded.append(char) }

        let chunk = 4096
        var i = 0
        while i < samples.count {
            let end = min(i + chunk, samples.count)
            decoder.process(samples: Array(samples[i..<end]))
            i = end
        }
        decoder.flush()
        return decoded.trimmingCharacters(in: .whitespaces)
    }

    func testCleanRoundtripAcrossSpeeds() {
        for wpm in [12, 20, 28] {
            let text = "CQ CQ DE W2ASM W2ASM K"
            let decoded = roundtrip(text, wpm: wpm, snrDB: nil)
            XCTAssertEqual(decoded, text, "clean copy must be perfect at \(wpm) WPM, got «\(decoded)»")
        }
    }

    func testNoisyRoundtripAt20WPM() {
        let text = "CQ CQ DE W2ASM W2ASM K"
        for snr in [Float(12), 6] {
            let decoded = roundtrip(text, wpm: 20, snrDB: snr)
            XCTAssertTrue(decoded.contains("W2ASM"),
                          "callsign must survive \(snr) dB SNR, got «\(decoded)»")
        }
    }

    func testQSOExchangeRoundtrip() {
        let text = "K1ABC DE W2ASM = R UR 599 599 = NAME ANDY = 73 SK"
        let decoded = roundtrip(text, wpm: 20, snrDB: 15)
        XCTAssertTrue(decoded.contains("599"), "got «\(decoded)»")
        XCTAssertTrue(decoded.contains("ANDY"), "got «\(decoded)»")
        XCTAssertTrue(decoded.contains("73"), "got «\(decoded)»")
    }
}
