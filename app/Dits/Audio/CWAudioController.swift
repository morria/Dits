// Audio plumbing between the radio (via a wired audio interface) and the
// CW decoder/keyer.
//
// Receive: the hardware input is tapped at its native format and
// converted to mono 48 kHz float, which the Core decoders consume.
//
// Transmit: keyed audio is rendered up front and played through an
// AVAudioPlayerNode that drives the radio's audio input (VOX/PTT). The
// session uses `.measurement` mode to disable voice processing so weak
// CW is copied cleanly and the keyed tone goes out flat.
//
// Resilience: interruptions (calls, Siri), route changes (interface
// plugged/unplugged), engine configuration changes, and media-services
// resets all tear down a live AVAudioEngine — some of them silently. This
// controller observes all of them and restarts itself while the app still
// *wants* to be listening (`desiredRunning`), and a watchdog restarts the
// path if input buffers stop arriving. The UI is kept honest through
// `onRuntimeEvent`.

import AVFoundation
import Accelerate
import Foundation

final class CWAudioController {

    enum AudioError: LocalizedError {
        case inputNotReady
        case converterUnavailable
        case session(Error)

        var errorDescription: String? {
            switch self {
            case .inputNotReady:      return "Audio input isn't ready yet. Try again in a moment."
            case .converterUnavailable: return "Couldn't set up audio conversion."
            case .session(let e):     return "Audio session error: \(e.localizedDescription)"
            }
        }
    }

    /// Runtime events the app layer should surface. All delivered on main.
    enum RuntimeEvent {
        case interrupted            // call/Siri took the session; auto-resume will follow
        case resumed                // recovered after interruption/route change/watchdog
        case died(String)           // gave up; user action needed
    }

    static let sampleRate: Double = 48_000

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var converter: AVAudioConverter?
    private var monoFormat: AVAudioFormat?
    private var playerAttached = false

    private var observers: [NSObjectProtocol] = []
    private var restartWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var watchdogStrikes = 0

    /// User intent: true between start() and stop(). Recovery paths only
    /// run while this is set.
    private(set) var desiredRunning = false

    /// Mono 48 kHz float frames from the radio. Called on the audio thread.
    var onInput: (([Float]) -> Void)?
    /// Input RMS level in [0, 1]. Called on the audio thread.
    var onLevel: ((Float) -> Void)?
    /// Lifecycle events outside start()/stop(). Called on main.
    var onRuntimeEvent: ((RuntimeEvent) -> Void)?

    private let inputTimeLock = NSLock()
    private var lastInputAtValue: Date?
    private var lastInputAt: Date? {
        inputTimeLock.lock(); defer { inputTimeLock.unlock() }
        return lastInputAtValue
    }
    private func touchInput() {
        inputTimeLock.lock()
        lastInputAtValue = Date()
        inputTimeLock.unlock()
    }

    var isRunning: Bool { engine.isRunning }

    // MARK: - Start / stop

    func start() throws {
        desiredRunning = true
        installObservers()
        try bringUp()
        startWatchdog()
    }

    func stop() {
        desiredRunning = false
        restartWork?.cancel(); restartWork = nil
        watchdog?.invalidate(); watchdog = nil
        watchdogStrikes = 0
        tearDown()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// The engine bring-up itself, callable from start() and recovery paths.
    private func bringUp() throws {
        try configureSession()

        // Idempotent: a failed prior attempt may have left a tap installed;
        // installing twice raises an uncatchable NSException.
        engine.inputNode.removeTap(onBus: 0)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioError.inputNotReady
        }

        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: Self.sampleRate,
                                       channels: 1,
                                       interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: mono) else {
            throw AudioError.converterUnavailable
        }
        converter.primeMethod = .none   // no resampler priming glitch at stream start
        self.converter = converter
        self.monoFormat = mono

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.processInput(buffer)
        }

        if !playerAttached {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: mono)
            playerAttached = true
        }

        engine.prepare()
        try engine.start()
        touchInput()   // fresh grace period for the watchdog
    }

    private func tearDown() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
    }

    // MARK: - Recovery

    private func installObservers() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification,
                                        object: session, queue: .main) { [weak self] note in
            self?.handleInterruption(note)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                                        object: session, queue: .main) { [weak self] note in
            self?.handleRouteChange(note)
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                        object: session, queue: .main) { [weak self] _ in
            self?.handleMediaServicesReset()
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange,
                                        object: nil, queue: .main) { [weak self] note in
            guard let self, (note.object as? AVAudioEngine) === self.engine else { return }
            self.scheduleRestart(after: 0.2)
        })
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }

        switch type {
        case .began:
            guard desiredRunning else { return }
            onRuntimeEvent?(.interrupted)
        case .ended:
            guard desiredRunning else { return }
            let optsRaw = (info[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let opts = AVAudioSession.InterruptionOptions(rawValue: optsRaw)
            // Restart even without .shouldResume — for a listening utility
            // the user's intent (Listen pressed) outranks the hint.
            scheduleRestart(after: opts.contains(.shouldResume) ? 0.3 : 1.0)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        guard desiredRunning,
              let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .override:
            // Input format likely changed (USB interface plugged/unplugged);
            // the old tap keeps the stale format, so rebuild the whole path.
            scheduleRestart(after: 0.3)
        default:
            break
        }
    }

    private func handleMediaServicesReset() {
        // Everything owned by the old media services daemon is invalid.
        observersStayButEngineDies()
        if desiredRunning { scheduleRestart(after: 0.5) }
    }

    private func observersStayButEngineDies() {
        playerAttached = false
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        converter = nil
        monoFormat = nil
    }

    /// Coalesced restart. Tears down and brings the path back up; one retry
    /// on failure, then reports death.
    private func scheduleRestart(after delay: TimeInterval, isRetry: Bool = false) {
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.desiredRunning else { return }
            self.tearDown()
            do {
                try self.bringUp()
                self.onRuntimeEvent?(.resumed)
            } catch {
                if isRetry {
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.onRuntimeEvent?(.died(message))
                } else {
                    self.scheduleRestart(after: 1.0, isRetry: true)
                }
            }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        watchdog?.invalidate()
        watchdogStrikes = 0
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.watchdogTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func watchdogTick() {
        guard desiredRunning else { return }
        guard let last = lastInputAt else { return }
        let silentFor = Date().timeIntervalSince(last)
        guard silentFor > 3.0 else {
            watchdogStrikes = 0
            return
        }

        watchdogStrikes += 1
        if watchdogStrikes >= 4 {
            // Repeated restarts aren't producing input — mic permission
            // denied or the interface is genuinely gone. Stop thrashing.
            watchdog?.invalidate(); watchdog = nil
            onRuntimeEvent?(.died("No audio is arriving. Check the microphone permission and your audio interface."))
        } else {
            scheduleRestart(after: 0)
        }
    }

    // MARK: - Transmit

    /// Play keyed mono samples, applying `gain`. `completion(played)` fires
    /// on a background thread; `played` is false when the engine died or
    /// playback was cancelled before the buffer finished.
    func play(_ samples: [Float], gain: Float, completion: @escaping (Bool) -> Void) {
        guard let mono = monoFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(samples.count)) else {
            completion(false); return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            var g = gain
            samples.withUnsafeBufferPointer { src in
                vDSP_vsmul(src.baseAddress!, 1, &g, channel, 1, vDSP_Length(samples.count))
            }
        }

        if !engine.isRunning {
            do { try engine.start() } catch { completion(false); return }
        }
        player.stop()
        // .dataPlayedBack: fires when the audio actually finished rendering
        // (or the player stopped). Verify the engine is still alive to
        // distinguish "played to the end" from "engine died mid-keying" —
        // a half-sent message must not be reported as sent.
        player.scheduleBuffer(buffer, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            let played = self?.engine.isRunning ?? false
            completion(played)
        }
        player.play()
    }

    func cancelPlayback() {
        player.stop()
    }

    /// Play keyed audio through the BUILT-IN SPEAKER only — never the
    /// connected audio interface, where it would key the radio via VOX.
    /// If the route override fails, nothing plays: silence is safer than
    /// an accidental transmission.
    func preview(_ samples: [Float], gain: Float, completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            completion(false)
            return
        }
        play(samples, gain: gain) { played in
            DispatchQueue.main.async {
                try? session.overrideOutputAudioPort(.none)
                completion(played)
            }
        }
    }

    /// Estimated playback duration of a rendered buffer, in seconds.
    static func duration(ofSampleCount count: Int) -> Double {
        Double(count) / sampleRate
    }

    // MARK: - Internals

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .measurement,
                                    options: [.allowBluetoothA2DP, .defaultToSpeaker])
            try session.setPreferredSampleRate(Self.sampleRate)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true)
        } catch {
            throw AudioError.session(error)
        }
    }

    private func processInput(_ buffer: AVAudioPCMBuffer) {
        touchInput()
        guard let converter, let monoFormat else { return }

        if let channel = buffer.floatChannelData?[0] {
            let frames = Int(buffer.frameLength)
            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(frames))
            onLevel?(min(1.0, rms * 6))
        }

        let ratio = monoFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        guard error == nil, output.frameLength > 0,
              let mono = output.floatChannelData?[0] else { return }
        onInput?(Array(UnsafeBufferPointer(start: mono, count: Int(output.frameLength))))
    }
}
