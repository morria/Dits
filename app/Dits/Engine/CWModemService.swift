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
    /// Clear transient decode state (buffers, half-built characters) while
    /// preserving calibration: noise floor, signal level, tracked speed,
    /// and AFC lock. Used when resuming after our own transmission.
    func resynchronize()
    /// Reduce DSP cost while the app is backgrounded (no-op for the
    /// single decoders; the diversity decoder drops to its classic leg).
    func setLowPower(_ enabled: Bool)
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
    func resynchronize() { demod.resynchronize() }
    func setLowPower(_ enabled: Bool) {}
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
    func resynchronize() { dec.resynchronize() }
    func setLowPower(_ enabled: Bool) {}
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
    func resynchronize() { dec.resynchronize() }
    func setLowPower(_ enabled: Bool) { dec.lowPowerMode = enabled }
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

    /// Secondary skimmer decoders, keyed by tone frequency. Always the
    /// classic backend: cheap, and the primary channel runs the good one.
    private var skimReceivers: [Double: CWReceiving] = [:]

    /// char, decoded WPM, signal strength (0–1), tone Hz. Fired on main.
    var onCharacter: ((Character, Double, Float, Double) -> Void)?
    /// Signal detected/lost. Fired on main.
    var onSignal: ((Bool) -> Void)?
    /// Skimmer copy: char, channel Hz, decoded WPM, signal. Fired on main.
    var onSkimCharacter: ((Character, Double, Double, Float) -> Void)?

    init(settings: StationSettings) {
        receiver = CWModemService.makeReceiver(settings: settings)
        wire(receiver)
    }

    private func wire(_ receiver: CWReceiving) {
        // Capture the receiver weakly (not through self.receiver): after a
        // settings rebuild swaps the receiver, a late character from the old
        // decoder must report the old decoder's WPM/tone, not the new one's.
        receiver.onCharacter = { [weak self, weak receiver] character in
            guard let self, let receiver else { return }
            let wpm = receiver.estimatedWPM
            let signal = receiver.signalStrength
            let tone = receiver.toneFrequency
            DispatchQueue.main.async { self.onCharacter?(character, wpm, signal, tone) }
        }
        receiver.onSignal = { [weak self] detected in
            DispatchQueue.main.async { self?.onSignal?(detected) }
        }
    }

    /// Point-in-time decoder status for the live meters, delivered on main.
    /// The character callback only fires when copy decodes — the meters
    /// need to stay honest between characters too.
    struct ReceiverStatus {
        let wpm: Double
        let signal: Float
        let toneHz: Double
    }

    func pollStatus(_ completion: @escaping (ReceiverStatus) -> Void) {
        queue.async {
            let status = ReceiverStatus(
                wpm: self.receiver.estimatedWPM,
                signal: self.receiver.signalStrength,
                toneHz: self.receiver.toneFrequency
            )
            DispatchQueue.main.async { completion(status) }
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

    private var lowPower = false

    func feed(_ samples: [Float]) {
        queue.async {
            guard !self.muted else { return }
            self.receiver.process(samples)
            if !self.lowPower {
                for skim in self.skimReceivers.values { skim.process(samples) }
            }
        }
    }

    /// Backgrounded: primary channel only, at the diversity decoder's
    /// classic leg — keeps copy alive within the iOS background CPU
    /// budget (the watchdog kills sustained >80% of a core).
    func setLowPower(_ enabled: Bool) {
        queue.async {
            self.lowPower = enabled
            self.receiver.setLowPower(enabled)
        }
    }

    /// Mute RX while transmitting so the app doesn't decode its own sidetone.
    /// On unmute the decoders resynchronize rather than cold-reset: the
    /// noise floor, tracked speed, and AFC lock measured seconds ago are far
    /// better estimates than one re-learned while the counterparty is
    /// already replying.
    func setMuted(_ muted: Bool) {
        queue.async {
            let wasMuted = self.muted
            self.muted = muted
            if !muted && wasMuted {
                self.receiver.resynchronize()
                for skim in self.skimReceivers.values { skim.resynchronize() }
            }
        }
    }

    // MARK: Skimmer channels

    /// Reconcile the set of secondary decoders with the desired channel
    /// frequencies (from spectrum peak scanning). Existing channels keep
    /// their decode state; new ones start classic decoders at that tone.
    func setSkimChannels(_ frequencies: [Double], settings: StationSettings) {
        queue.async {
            for hz in self.skimReceivers.keys where !frequencies.contains(hz) {
                self.skimReceivers.removeValue(forKey: hz)
            }
            for hz in frequencies where self.skimReceivers[hz] == nil {
                var channelSettings = settings
                channelSettings.toneHz = Int(hz)
                channelSettings.decoder = .classic
                let skim = CWModemService.makeReceiver(settings: channelSettings)
                skim.onCharacter = { [weak self, weak skim] character in
                    guard let self, let skim else { return }
                    let wpm = skim.estimatedWPM
                    let signal = skim.signalStrength
                    DispatchQueue.main.async {
                        self.onSkimCharacter?(character, hz, wpm, signal)
                    }
                }
                self.skimReceivers[hz] = skim
            }
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
