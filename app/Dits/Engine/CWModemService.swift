// Bridges the Core CW library to the app. Receive audio is processed on
// a dedicated DSP queue by one of three interchangeable Core decoders;
// decoded characters and signal transitions are marshalled to the main
// thread. Transmit text is rendered to keyed audio on demand.

import Foundation
import AmateurDigitalCore

// MARK: - Uniform decoder interface

/// A single, uniform surface over the Core library's three CW decoders so
/// the rest of the app doesn't care which one is selected.
protocol CWReceiving: AnyObject {
    func process(_ samples: [Float])
    func reset()
    var estimatedWPM: Double { get }
    var signalStrength: Float { get }
    var toneFrequency: Double { get }
    var onCharacter: ((Character) -> Void)? { get set }
    var onSignal: ((Bool) -> Void)? { get set }
}

/// Classic Goertzel state-machine decoder (`CWDemodulator`).
private final class ClassicReceiver: CWReceiving, CWDemodulatorDelegate {
    private let demod: CWDemodulator
    var onCharacter: ((Character) -> Void)?
    var onSignal: ((Bool) -> Void)?

    init(config: CWConfiguration, minWPM: Double, maxWPM: Double) {
        demod = CWDemodulator(configuration: config)
        demod.minWPM = minWPM
        demod.maxWPM = maxWPM
        demod.delegate = self
    }

    func process(_ samples: [Float]) { demod.process(samples: samples) }
    func reset() { demod.reset() }
    var estimatedWPM: Double { demod.estimatedWPM }
    var signalStrength: Float { demod.signalStrength }
    var toneFrequency: Double { demod.toneFrequency }

    func demodulator(_ demodulator: CWDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        onCharacter?(character)
    }
    func demodulator(_ demodulator: CWDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {
        onSignal?(detected)
    }
}

/// Probabilistic beam-search decoder (`BayesianCWDecoder`).
private final class BayesianReceiver: CWReceiving {
    private let dec: BayesianCWDecoder
    var onCharacter: ((Character) -> Void)?
    var onSignal: ((Bool) -> Void)?

    init(config: CWConfiguration, minWPM: Double, maxWPM: Double) {
        dec = BayesianCWDecoder(configuration: config)
        dec.minWPM = minWPM
        dec.maxWPM = maxWPM
        dec.onCharacterDecoded = { [weak self] character, _ in self?.onCharacter?(character) }
        dec.onSignalDetected = { [weak self] detected, _ in self?.onSignal?(detected) }
    }

    func process(_ samples: [Float]) { dec.process(samples: samples) }
    func reset() { dec.reset() }
    var estimatedWPM: Double { dec.estimatedWPM }
    var signalStrength: Float { dec.signalStrength }
    var toneFrequency: Double { dec.toneFrequency }
}

/// Diversity decoder that fuses both of the above (`DualCWDecoder`).
private final class DiversityReceiver: CWReceiving {
    private let dec: DualCWDecoder
    var onCharacter: ((Character) -> Void)?
    var onSignal: ((Bool) -> Void)?

    init(config: CWConfiguration, minWPM: Double, maxWPM: Double) {
        dec = DualCWDecoder(configuration: config)
        dec.minWPM = minWPM
        dec.maxWPM = maxWPM
        dec.onCharacterDecoded = { [weak self] character, _ in self?.onCharacter?(character) }
        dec.onSignalDetected = { [weak self] detected, _ in self?.onSignal?(detected) }
    }

    func process(_ samples: [Float]) { dec.process(samples: samples) }
    func reset() { dec.reset() }
    var estimatedWPM: Double { dec.estimatedWPM }
    var signalStrength: Float { dec.signalStrength }
    var toneFrequency: Double { dec.toneFrequency }
}

// MARK: - Service

final class CWModemService {

    static let sampleRate: Double = 48_000

    private let queue = DispatchQueue(label: "com.w2asm.dits.dsp", qos: .userInitiated)
    private var receiver: CWReceiving
    private var muted = false

    /// char, decoded WPM, signal strength (0–1), tone Hz. Fired on main.
    var onCharacter: ((Character, Double, Float, Double) -> Void)?
    /// Signal detected/lost. Fired on main.
    var onSignal: ((Bool) -> Void)?

    init(settings: StationSettings) {
        receiver = CWModemService.makeReceiver(settings: settings)
        wire(receiver)
    }

    private func wire(_ receiver: CWReceiving) {
        receiver.onCharacter = { [weak self] character in
            guard let self else { return }
            let wpm = self.receiver.estimatedWPM
            let signal = self.receiver.signalStrength
            let tone = self.receiver.toneFrequency
            DispatchQueue.main.async { self.onCharacter?(character, wpm, signal, tone) }
        }
        receiver.onSignal = { [weak self] detected in
            DispatchQueue.main.async { self?.onSignal?(detected) }
        }
    }

    private static func makeReceiver(settings: StationSettings) -> CWReceiving {
        let config = CWConfiguration(
            toneFrequency: Double(settings.toneHz),
            wpm: Double(settings.wpm),
            sampleRate: sampleRate
        )
        let minW = Double(settings.minWPM)
        let maxW = Double(settings.maxWPM)
        switch settings.decoder {
        case .classic:   return ClassicReceiver(config: config, minWPM: minW, maxWPM: maxW)
        case .bayesian:  return BayesianReceiver(config: config, minWPM: minW, maxWPM: maxW)
        case .diversity: return DiversityReceiver(config: config, minWPM: minW, maxWPM: maxW)
        }
    }

    private var pendingRebuild: DispatchWorkItem?

    /// Rebuild the decoder when tone/speed/decoder settings change.
    /// Debounced: a rebuild resets the noise floor and drops any character
    /// in progress, so dragging a Settings slider must not rebuild per tick.
    func updateSettings(_ settings: StationSettings) {
        pendingRebuild?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                let receiver = CWModemService.makeReceiver(settings: settings)
                self.wire(receiver)
                self.receiver = receiver
            }
        }
        pendingRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func feed(_ samples: [Float]) {
        queue.async {
            guard !self.muted else { return }
            self.receiver.process(samples)
        }
    }

    /// Mute RX while transmitting so the app doesn't decode its own sidetone.
    func setMuted(_ muted: Bool) {
        queue.async {
            self.muted = muted
            if muted { self.receiver.reset() }
        }
    }

    // MARK: Transmit

    /// Render `text` to keyed mono 48 kHz audio in [-1, 1].
    func encode(_ text: String, settings: StationSettings) -> [Float] {
        let config = CWConfiguration(
            toneFrequency: Double(settings.toneHz),
            wpm: Double(settings.wpm),
            sampleRate: CWModemService.sampleRate
        )
        let modem = CWModem(configuration: config)
        // A lead-in of silence lets the receiver settle its noise floor and
        // gives VOX/PTT time to key before the first element.
        return modem.encodeWithEnvelope(text: text.uppercased(), preambleMs: 250, postambleMs: 150)
    }

    /// Render off the main thread (a long over is millions of samples) and
    /// deliver the buffer on main.
    func encodeAsync(_ text: String, settings: StationSettings, completion: @escaping ([Float]) -> Void) {
        queue.async {
            let samples = self.encode(text, settings: settings)
            DispatchQueue.main.async { completion(samples) }
        }
    }
}
