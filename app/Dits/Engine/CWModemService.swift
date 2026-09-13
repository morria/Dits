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
    /// The app committed the copy so far as a message: no later revision
    /// may straddle this point.
    func markBoundary()
    /// Release held copy and settle every revision (listening stopped).
    func flushPending()
    var estimatedWPM: Double { get }
    var signalStrength: Float { get }
    var toneFrequency: Double { get }
    /// Speed and tone fitted to the whole recent window by the revising
    /// layer, when it has one — steadier than the streaming estimates.
    var fittedWPM: Double? { get }
    var fittedToneFrequency: Double? { get }
    /// Keying the gate accepted since the last character came out, and
    /// how long ago the last element ended — "hearing something" that
    /// isn't (yet) copy.
    var unclaimedKeying: (elements: Int, ageSeconds: Double) { get }
    /// Streaming characters (skimmer channels use this).
    var onCharacter: ((Character) -> Void)? { get set }
    /// Provisional/revised/finalized text (the primary channel uses this).
    var onTextEvent: ((CWTextEvent) -> Void)? { get set }
    var onSignal: ((Bool) -> Void)? { get set }
}

/// Any Core streaming decoder (classic, Bayesian, or diversity) behind
/// the revising layer: characters stream out provisionally and are
/// revised from the retained keying timeline (`RevisingCWDecoder`).
private final class RevisingReceiver: CWReceiving {
    private let revising: RevisingCWDecoder
    private let dual: DualCWDecoder?
    var onCharacter: ((Character) -> Void)?
    var onTextEvent: ((CWTextEvent) -> Void)?
    var onSignal: ((Bool) -> Void)?

    init(base: CWStreamingDecoder, dual: DualCWDecoder?, sampleRate: Double) {
        self.dual = dual
        revising = RevisingCWDecoder(base: base, sampleRate: sampleRate)
        revising.onTextEvent = { [weak self] event in
            self?.onTextEvent?(event)
            if case .character(let c, _) = event { self?.onCharacter?(c) }
        }
        revising.onSignalDetected = { [weak self] detected, _ in self?.onSignal?(detected) }
    }

    static func make(_ decoder: CWDecoder, config: CWConfiguration,
                     minWPM: Double, maxWPM: Double) -> RevisingReceiver {
        switch decoder {
        case .classic:
            let d = CWDemodulator(configuration: config)
            d.minWPM = minWPM; d.maxWPM = maxWPM
            return RevisingReceiver(base: d, dual: nil, sampleRate: config.sampleRate)
        case .bayesian:
            let d = BayesianCWDecoder(configuration: config)
            d.minWPM = minWPM; d.maxWPM = maxWPM
            return RevisingReceiver(base: d, dual: nil, sampleRate: config.sampleRate)
        case .diversity:
            let d = DualCWDecoder(configuration: config)
            d.minWPM = minWPM; d.maxWPM = maxWPM
            return RevisingReceiver(base: d, dual: d, sampleRate: config.sampleRate)
        }
    }

    func process(_ samples: [Float]) { revising.process(samples: samples) }
    func resynchronize() { revising.resynchronize() }
    func setLowPower(_ enabled: Bool) { dual?.lowPowerMode = enabled }
    func markBoundary() { revising.markBoundary() }
    func flushPending() { revising.flushPending() }
    var estimatedWPM: Double { revising.estimatedWPM }
    var signalStrength: Float { revising.signalStrength }
    var toneFrequency: Double { revising.toneFrequency }
    var fittedWPM: Double? { revising.fittedWPM }
    var fittedToneFrequency: Double? { revising.fittedFrequency }
    var unclaimedKeying: (elements: Int, ageSeconds: Double) {
        guard let last = revising.lastElementSample else { return (0, .infinity) }
        let age = Double(revising.base.sampleClock - last) / CWModemService.sampleRate
        return (revising.elementsSinceLastCharacter, age)
    }
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
    /// Primary-channel text events (provisional characters, revisions,
    /// finalizations) with the decoder's WPM/signal/tone at the time.
    /// Fired on main, in order.
    var onTextEvent: ((CWTextEvent, Double, Float, Double) -> Void)?
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
        receiver.onTextEvent = { [weak self, weak receiver] event in
            guard let self, let receiver else { return }
            let wpm = receiver.fittedWPM ?? receiver.estimatedWPM
            let signal = receiver.signalStrength
            let tone = receiver.fittedToneFrequency ?? receiver.toneFrequency
            DispatchQueue.main.async { self.onTextEvent?(event, wpm, signal, tone) }
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
        /// Keying heard in the last couple of seconds that produced no
        /// copy: held by emission probation or dropped as junk.
        let hearingKeying: Bool
    }

    func pollStatus(_ completion: @escaping (ReceiverStatus) -> Void) {
        queue.async {
            let keying = self.receiver.unclaimedKeying
            let status = ReceiverStatus(
                wpm: self.receiver.fittedWPM ?? self.receiver.estimatedWPM,
                signal: self.receiver.signalStrength,
                toneHz: self.receiver.fittedToneFrequency ?? self.receiver.toneFrequency,
                hearingKeying: keying.elements >= 3 && keying.ageSeconds < 2.0
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
        return RevisingReceiver.make(settings.decoder, config: config,
                                     minWPM: Double(settings.minWPM), maxWPM: Double(settings.maxWPM))
    }

    /// The app committed the copy so far as a message.
    func markBoundary() {
        queue.async { self.receiver.markBoundary() }
    }

    /// Listening stopped: settle every provisional segment now.
    func flushPending() {
        queue.async { self.receiver.flushPending() }
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
                // Copy shown from the old decoder can't be revised by the
                // new one — settle it so nothing stays gray forever.
                self.receiver.flushPending()
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
                // Skimmer copy only feeds the monitor; ignore its revisions.
                skim.onTextEvent = nil
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
