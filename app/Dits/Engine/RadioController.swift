// The single source of truth for the app. Owns the audio path and the CW
// decoder/keyer, turns the character stream into conversations and a live
// band monitor, and drives transmit. All published state mutates on the
// main actor; audio and DSP callbacks hop here before touching it.

import Foundation
import SwiftUI
import Combine
import AmateurDigitalCore

@MainActor
final class RadioController: ObservableObject {

    enum RadioState: Equatable {
        case stopped
        case listening
        case paused          // interruption/route change; auto-resume pending
        case transmitting
        case error(String)
    }

    // MARK: Published state

    @Published private(set) var state: RadioState = .stopped
    @Published private(set) var conversations: [Conversation] = []

    /// Committed transmissions heard on the band, oldest first.
    @Published private(set) var monitor: [DecodeEntry] = []
    /// Copy currently being decoded, before it's committed to the monitor.
    @Published private(set) var liveText: String = ""

    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var currentWPM: Int = 0
    @Published private(set) var signalStrength: Float = 0
    @Published private(set) var signalDetected: Bool = false
    /// AFC-tracked tone of the station being copied (0 = none yet).
    @Published private(set) var detectedToneHz: Int = 0
    /// Live 300–1100 Hz band magnitudes (0–1) for the tuning strip.
    @Published private(set) var spectrum: [Float] = []
    /// Off-air recording in progress (field diagnostics).
    @Published private(set) var isRecordingOffAir = false
    @Published private(set) var recordingSeconds = 0

    @Published var settings: StationSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    // MARK: Collaborators

    private let audio = CWAudioController()
    private let modem: CWModemService
    private let location = LocationFetcher()
    private let spectrumAnalyzer = SpectrumAnalyzer()
    private let fieldRecorder = FieldRecorder()
    private var recordingTimer: Timer?
    private var meterTimer: Timer?

    /// Morserino-32 BLE keyer. When connected and ready, outgoing text is
    /// keyed by the Morserino instead of rendered as audio.
    let morserino = MorserinoKeyer()
    private var cancellables: Set<AnyCancellable> = []

    // MARK: RX accumulation

    private var pendingSegment = ""
    private var commitWork: DispatchWorkItem?
    private let maxMonitorEntries = 400
    private let maxMessagesPerConversation = 500

    /// Quiet time after the last decoded character before a transmission is
    /// considered finished. Scales with the speed being copied: a word gap
    /// is 7 dits, so at 5 WPM it lasts 1.68 s (a fixed 2 s would split slow
    /// transmissions mid-message and break callsign routing), while at
    /// 30 WPM it's 0.28 s (a fixed 2 s just adds latency). Human fists also
    /// stretch gaps well beyond 1×, hence the 2.5× margin.
    nonisolated static func commitDelay(forWPM wpm: Int) -> TimeInterval {
        let ditSeconds = 1.2 / Double(max(wpm, 5))
        let wordGap = 7 * ditSeconds
        return min(4.0, max(1.2, wordGap * 2.5))
    }

    // MARK: TX bookkeeping

    private var txToken: UUID?
    private var txConversationID: UUID?
    private var txWatchdog: DispatchWorkItem?
    /// Non-nil while a Morserino keying is in flight (completion timer).
    private var txMorserinoDone: DispatchWorkItem?

    // MARK: Init

    init() {
        let loaded = Persistence.loadSettings()
        self.settings = loaded
        self.modem = CWModemService(settings: loaded)
        // Messages persisted mid-transmit (app killed while keying) would
        // show an animated "Sending…" forever — no code path advances them.
        self.conversations = RadioController.sanitized(Persistence.loadConversations())
        sortConversations()
        // Threads stored before conversations had identity get a fresh id on
        // every decode; write them back once so the ids stop moving.
        Persistence.saveConversations(conversations)

        audio.onInput = { [modem, spectrumAnalyzer, fieldRecorder] samples in
            modem.feed(samples)
            spectrumAnalyzer?.feed(samples)
            fieldRecorder.append(samples)
        }
        fieldRecorder.onAutoStop = { [weak self] in
            self?.stopOffAirRecording()
        }
        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.inputLevel = level }
        }
        spectrumAnalyzer?.onFrame = { [weak self] frame in
            guard let self, self.isListening else { return }
            self.spectrum = frame.normalized
            self.skim(frame)
        }
        startMeterPolling()

        // Background CPU budget: iOS kills apps holding >80% of a core for
        // 60 s (seen as cpu_resource_fatal). While backgrounded, drop to
        // the classic decoder leg and stop skimmer + spectrum work.
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                       object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.modem.setLowPower(true)
            self.spectrumAnalyzer?.setPaused(true)
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification,
                       object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.modem.setLowPower(false)
            self.spectrumAnalyzer?.setPaused(false)
        }

        // Nested ObservableObject: republish the keyer's changes so views
        // observing the radio see connection state move.
        morserino.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        morserino.onDisconnect = { [weak self] in
            guard let self else { return }
            // Link dropped mid-keying: the rest of the message never went
            // out — report it failed, same contract as the audio path.
            if self.txMorserinoDone != nil { self.cancelTransmit() }
        }
        audio.onRuntimeEvent = { [weak self] event in
            self?.handleAudioRuntimeEvent(event)
        }
        modem.onCharacter = { [weak self] character, wpm, signal, tone in
            self?.handleCharacter(character, wpm: wpm, signal: signal, tone: tone)
        }
        modem.onSignal = { [weak self] detected in
            self?.signalDetected = detected
        }
        modem.onSkimCharacter = { [weak self] character, channelHz, wpm, signal in
            self?.handleSkimCharacter(character, channelHz: channelHz, wpm: wpm, signal: signal)
        }

        #if DEBUG
        if ProcessInfo.processInfo.environment["DITS_DEMO"] == "1" { seedDemo() }
        #endif
    }

    #if DEBUG
    /// Seeds illustrative content for screenshots. Only ever runs when the
    /// app is launched with `--demo`; compiled out of Release builds.
    private func seedDemo() {
        if settings.callsign.isEmpty { settings.callsign = "W2ASM"; settings.grid = "FN31" }
        let now = Date()
        var k1 = Conversation(counterparty: "K1ABC", lastReadAt: .distantPast)
        k1.messages = [
            Message(text: "CQ CQ DE K1ABC K1ABC K", timestamp: now.addingTimeInterval(-640),
                    direction: .received, status: .received, callsign: "K1ABC", wpm: 22, toneHz: 600, signal: 78),
            Message(text: "K1ABC DE W2ASM W2ASM", timestamp: now.addingTimeInterval(-600),
                    direction: .transmitted, status: .sent, callsign: "K1ABC", wpm: 20, toneHz: 600),
            Message(text: "W2ASM DE K1ABC = GE TNX CALL UR 599 599 = NAME TOM QTH BOSTON = HW? K",
                    timestamp: now.addingTimeInterval(-560),
                    direction: .received, status: .received, callsign: "K1ABC", wpm: 23, toneHz: 600, signal: 64),
            Message(text: "K1ABC DE W2ASM = R FB TOM UR 579 = NAME ANDY QTH NJ = 73 SK",
                    timestamp: now.addingTimeInterval(-520),
                    direction: .transmitted, status: .sent, callsign: "K1ABC", wpm: 20, toneHz: 600),
        ]
        var dl = Conversation(counterparty: "DL1ABC", lastReadAt: .distantPast)
        dl.messages = [
            Message(text: "CQ DX CQ DX DE DL1ABC K", timestamp: now.addingTimeInterval(-200),
                    direction: .received, status: .received, callsign: "DL1ABC", wpm: 26, toneHz: 600, signal: 52),
        ]
        conversations = [k1, dl]
        sortConversations()
        monitor = [
            DecodeEntry(text: "CQ DX DE DL1ABC DL1ABC K", timestamp: now.addingTimeInterval(-90),
                        wpm: 26, signal: 52, toneHz: 600, callsign: "DL1ABC"),
            DecodeEntry(text: "W2ASM DE K1ABC R FB", timestamp: now.addingTimeInterval(-45),
                        wpm: 23, signal: 72, toneHz: 600, callsign: "K1ABC"),
            DecodeEntry(text: "QRL? DE N0CALL", timestamp: now.addingTimeInterval(-12),
                        wpm: 18, signal: 28, toneHz: 600, callsign: "N0CALL"),
        ]
        currentWPM = 23
        state = .listening   // show a live-looking status without opening the mic
    }
    #endif

    // MARK: Listening control

    var isListening: Bool {
        switch state {
        case .listening, .paused, .transmitting: return true
        case .stopped, .error: return false
        }
    }

    /// Set when the operator explicitly stops listening. Foregrounding
    /// (scenePhase → startIfNeeded) must not override an explicit Stop —
    /// restarting behind the operator's back reads as "the Stop button
    /// doesn't work."
    private var userStopped = false

    func startIfNeeded() {
        // Quiet zero-tap reconnect to a previously used Morserino.
        morserino.reconnectIfRemembered()
        guard !userStopped else { return }
        // Base the decision on the actual audio path, not our own state —
        // after a failure `state` can claim listening over a dead engine.
        guard !audio.desiredRunning || !audio.isRunning else { return }
        start()
    }

    func start(retrying: Bool = true) {
        userStopped = false
        do {
            try audio.start()
            state = .listening
            applyScreenPolicy()
        } catch {
            if retrying {
                // Cold launch / interface still enumerating — retry once,
                // unless something else already got the audio running.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, !self.audio.isRunning else { return }
                    self.start(retrying: false)
                }
            } else {
                state = .error((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func stop() {
        userStopped = true
        stopOffAirRecording()
        audio.stop()
        state = .stopped
        signalDetected = false
        inputLevel = 0
        commitSegment()
        teardownSkimmer()
        spectrum = []
        applyScreenPolicy()
    }

    /// Interruptions, route changes, and engine death reported by the audio
    /// layer — keep the UI honest and recover the TX state machine.
    private func handleAudioRuntimeEvent(_ event: CWAudioController.RuntimeEvent) {
        switch event {
        case .interrupted:
            if state == .transmitting { cancelTransmit() }
            if state != .stopped { state = .paused }
            signalDetected = false
            inputLevel = 0
        case .resumed:
            if state == .paused || state == .listening { state = .listening }
        case .died(let message):
            if state == .transmitting { cancelTransmit() }
            state = .error(message)
            signalDetected = false
            inputLevel = 0
        }
        applyScreenPolicy()
    }

    func toggleListening() {
        if isListening { stop() } else { start() }
    }

    func applyScreenPolicy() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenOn && isListening
    }

    // MARK: Live meters

    /// The character callback only fires when copy decodes; between
    /// characters the meters would freeze exactly when the operator is
    /// wondering whether anything is being received. Poll the decoder for
    /// honest speed/signal/tone a few times a second while listening.
    private func startMeterPolling() {
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func pollMeters() {
        guard state == .listening else { return }
        modem.pollStatus { [weak self] status in
            guard let self, self.state == .listening else { return }
            self.signalStrength = status.signal
            if self.signalDetected {
                if status.wpm.isFinite, status.wpm > 0 { self.currentWPM = Int(status.wpm.rounded()) }
                if status.toneHz.isFinite, status.toneHz > 0 { self.detectedToneHz = Int(status.toneHz.rounded()) }
            }
        }
    }

    // MARK: Off-air recording

    /// Record exactly what the decoder hears to a WAV in Documents
    /// (Files app → Dits). Auto-stops at the length cap; capped so a
    /// forgotten recording can't fill the phone.
    func toggleOffAirRecording() {
        if isRecordingOffAir {
            stopOffAirRecording()
        } else {
            guard isListening, fieldRecorder.start() != nil else { return }
            isRecordingOffAir = true
            recordingSeconds = 0
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isRecordingOffAir else { return }
                    self.recordingSeconds = self.fieldRecorder.seconds
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            recordingTimer = timer
        }
    }

    func stopOffAirRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        guard isRecordingOffAir else { return }
        fieldRecorder.stop()
        isRecordingOffAir = false
    }

    // MARK: Tuning

    /// Retune the decoder (spectrum strip tap). Snapped to 10 Hz and clamped
    /// to the supported tone range; flows through the normal debounced
    /// settings rebuild.
    func setToneFrequency(_ hz: Double) {
        let snapped = (hz / 10).rounded() * 10
        let clamped = min(max(snapped, StationSettings.toneRange.lowerBound),
                          StationSettings.toneRange.upperBound)
        settings.toneHz = Int(clamped)
    }

    // MARK: Receive pipeline

    private func handleCharacter(_ character: Character, wpm: Double, signal: Float, tone: Double) {
        // Characters still in flight on the DSP queue arrive after an
        // explicit Stop; showing them makes Stop look broken.
        guard state == .listening else { return }
        if wpm.isFinite, wpm > 0 { currentWPM = Int(wpm.rounded()) }
        signalStrength = signal
        if tone.isFinite, tone > 0 { detectedToneHz = Int(tone.rounded()) }

        pendingSegment.append(character)
        liveText = pendingSegment.trimmingCharacters(in: .whitespaces)
        scheduleCommit()
    }

    private func scheduleCommit() {
        commitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitSegment() }
        commitWork = work
        let delay = RadioController.commitDelay(forWPM: currentWPM > 0 ? currentWPM : settings.wpm)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func commitSegment() {
        commitWork?.cancel()
        commitWork = nil
        let text = pendingSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingSegment = ""
        liveText = ""
        commitCopy(text,
                   wpm: max(currentWPM, 1),
                   signal: Int((signalStrength * 100).rounded()),
                   toneHz: detectedToneHz)
    }

    /// Shared commit path for the primary channel and skimmer channels:
    /// monitor entry, callsign routing, persistence. Internal rather than
    /// private so tests can exercise routing without an audio path.
    func commitCopy(_ text: String, wpm: Int, signal: Int, toneHz: Int) {
        guard text.count >= 2 else { return }

        let call = CallsignParser.counterparty(in: text, myCall: settings.callsign)
        let entry = DecodeEntry(
            text: text,
            wpm: wpm,
            signal: signal,
            toneHz: toneHz,
            callsign: call
        )
        monitor.append(entry)
        if monitor.count > maxMonitorEntries {
            monitor.removeFirst(monitor.count - maxMonitorEntries)
        }

        func received(callsign: String?) -> Message {
            Message(
                text: text,
                direction: .received,
                status: .received,
                callsign: callsign,
                wpm: entry.wpm,
                toneHz: entry.toneHz,
                signal: entry.signal
            )
        }

        // Answers to a CQ also land in the thread that called it: the
        // operator is sitting there waiting, and a reply whose callsign
        // didn't parse would otherwise vanish into the monitor. Only the
        // thread the call went out from — an older CQ never collects copy.
        let cqEcho: UUID? = {
            guard let cq = cqConversationID,
                  Date().timeIntervalSince(lastCQActivity) < cqReplyWindow,
                  call != nil || isSubstantialCopy(text),
                  conversation(id: cq) != nil else { return nil }
            return cq
        }()

        if let call {
            // A station identified itself: its newest thread owns this copy,
            // and becomes the one subsequent unaddressed overs route into.
            // Copy arriving in a thread the operator hasn't opened is unread.
            let id = conversationID(with: call, lastReadAt: .distantPast)
            appendMessage(received(callsign: call), to: id)
            if let cq = cqEcho, cq != id {
                appendMessage(received(callsign: call), to: cq)
            }
            activate(id)
        } else if let active = activeConversationID,
                  Date().timeIntervalSince(lastQSOActivity) < qsoReplyWindow,
                  isSubstantialCopy(text),
                  conversation(id: active) != nil {
            // Mid-QSO overs drop the "DE <call>" after the first exchange.
            appendMessage(received(callsign: nil), to: active)
            lastQSOActivity = Date()
        } else if let cq = cqEcho {
            appendMessage(received(callsign: nil), to: cq)
        }
        persistConversations()
    }

    /// Copy worth routing into a thread without a parsed callsign: long
    /// enough to be deliberate, and not dominated by the all-dit chatter
    /// (E/I/S/H/5 runs, lone Ts) a noisy idle channel produces. Junk still
    /// shows in the raw Band Monitor feed; it just doesn't become a
    /// message bubble.
    private func isSubstantialCopy(_ text: String) -> Bool {
        let chars = text.filter { !$0.isWhitespace }
        guard chars.count >= 4 else { return false }
        let junk = chars.filter { "EISH5T".contains($0) }.count
        return Double(junk) < Double(chars.count) * 0.7
    }

    // MARK: Skimmer (secondary decode channels feeding the Band Monitor)

    private struct SkimChannel {
        var pending = ""
        var wpm: Int = 0
        var signal: Float = 0
        var lastHeard = Date()
        var commitWork: DispatchWorkItem?
    }

    /// Active skimmer channels keyed by tone frequency in Hz.
    private var skimChannels: [Int: SkimChannel] = [:]
    private var lastSkimScan = Date.distantPast
    private let maxSkimChannels = 2

    /// Every spectrum frame: (re)assign skimmer channels to the strongest
    /// tones away from the primary channel. Peaks are scanned at most once
    /// a second; channels persist while their peak persists or copy is
    /// still arriving, so a keyed signal's gaps don't churn decoders.
    private func skim(_ frame: SpectrumAnalyzer.Frame) {
        guard settings.skimmerEnabled, state == .listening else {
            if !skimChannels.isEmpty { teardownSkimmer() }
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastSkimScan) >= 1.0 else { return }
        lastSkimScan = now

        let peaks = skimPeaks(in: frame)

        var keep: [Int] = skimChannels.compactMap { hz, channel in
            let active = now.timeIntervalSince(channel.lastHeard) < 10
                || peaks.contains { abs($0 - Double(hz)) < 40 }
            return active ? hz : nil
        }
        for hz in skimChannels.keys where !keep.contains(hz) {
            commitSkimChannel(hz)
            skimChannels.removeValue(forKey: hz)
        }
        for peak in peaks where keep.count < maxSkimChannels {
            let hz = Int((peak / 10).rounded() * 10)
            guard !keep.contains(where: { abs($0 - hz) < 40 }) else { continue }
            keep.append(hz)
            skimChannels[hz] = SkimChannel()
        }
        modem.setSkimChannels(keep.map(Double.init), settings: settings)
    }

    /// Local maxima well above the band's median power, excluding the
    /// primary channel's neighborhood (the main decoder owns ±60 Hz).
    private func skimPeaks(in frame: SpectrumAnalyzer.Frame) -> [Double] {
        let power = frame.power
        guard power.count > 8 else { return [] }
        let median = Double(power.sorted()[power.count / 2])
        let floor = max(median, 1e-12)

        var peaks: [(hz: Double, p: Double)] = []
        for i in 2..<(power.count - 2) {
            let p = Double(power[i])
            guard p > floor * 12,
                  power[i] >= power[i - 1], power[i] >= power[i + 1],
                  power[i] > power[i - 2], power[i] > power[i + 2] else { continue }
            let hz = frame.frequency(ofBin: i)
            if abs(hz - Double(settings.toneHz)) < 60 { continue }
            if detectedToneHz > 0 && abs(hz - Double(detectedToneHz)) < 60 { continue }
            peaks.append((hz, p))
        }
        return Array(peaks.sorted { $0.p > $1.p }.prefix(3).map(\.hz))
    }

    private func handleSkimCharacter(_ character: Character, channelHz: Double, wpm: Double, signal: Float) {
        guard state == .listening else { return }
        let hz = Int(channelHz)
        guard var channel = skimChannels[hz] else { return }
        channel.pending.append(character)
        channel.lastHeard = Date()
        if wpm.isFinite, wpm > 0 { channel.wpm = Int(wpm.rounded()) }
        channel.signal = signal
        channel.commitWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.commitSkimChannel(hz) }
        channel.commitWork = work
        skimChannels[hz] = channel
        let delay = RadioController.commitDelay(forWPM: channel.wpm > 0 ? channel.wpm : settings.wpm)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func commitSkimChannel(_ hz: Int) {
        guard var channel = skimChannels[hz] else { return }
        channel.commitWork?.cancel()
        channel.commitWork = nil
        let text = channel.pending.trimmingCharacters(in: .whitespacesAndNewlines)
        channel.pending = ""
        skimChannels[hz] = channel
        commitCopy(text,
                   wpm: max(channel.wpm, 1),
                   signal: Int((channel.signal * 100).rounded()),
                   toneHz: hz)
    }

    private func teardownSkimmer() {
        for hz in skimChannels.keys { commitSkimChannel(hz) }
        skimChannels.removeAll()
        modem.setSkimChannels([], settings: settings)
    }

    // MARK: Transmit

    /// True when the operator has set at least a callsign.
    var canTransmit: Bool { settings.isConfigured }

    /// Play the draft locally through the built-in speaker so the
    /// operator can hear the timing before keying anything on the air.
    func previewDraft(_ text: String) {
        guard state != .transmitting, !text.isEmpty else { return }
        if !audio.isRunning { start(retrying: false) }
        guard audio.isRunning else { return }
        modem.setMuted(true)   // don't decode our own preview sidetone
        modem.encodeAsync(text, settings: settings) { [weak self] samples in
            guard let self, self.state != .transmitting else {
                self?.modem.setMuted(false)
                return
            }
            self.audio.preview(samples, gain: 0.25) { _ in
                DispatchQueue.main.async { self.modem.setMuted(false) }
            }
        }
    }

    /// The CQ thread the operator last keyed in, and when. Answers arriving
    /// inside the reply window are echoed into it — the operator is sitting
    /// there waiting. Only the thread that was called from, never an older one.
    private var cqConversationID: UUID?
    private var lastCQActivity: Date = .distantPast
    private let cqReplyWindow: TimeInterval = 180

    /// The thread being worked right now: the last one the operator keyed in,
    /// started, or that a parsed callsign routed copy into. While the window
    /// is open, substantial copy that fails callsign parsing lands here —
    /// mid-QSO overs drop the "DE <call>" after the first exchange, and that
    /// copy would otherwise vanish into the monitor exactly when the operator
    /// is deepest in a conversation. Starting a new conversation moves this,
    /// so an old thread never quietly keeps collecting copy.
    private var activeConversationID: UUID?
    private var lastQSOActivity: Date = .distantPast
    private let qsoReplyWindow: TimeInterval = 300

    @discardableResult
    func send(_ raw: String, in id: UUID) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canTransmit,
              let conversation = conversation(id: id) else { return false }
        activate(id)
        if conversation.isCQ {
            cqConversationID = id
            lastCQActivity = Date()
        }

        let message = Message(
            text: text.uppercased(),
            direction: .transmitted,
            status: .queued,
            callsign: conversation.isCQ ? nil : conversation.counterparty,
            wpm: settings.wpm,
            toneHz: settings.toneHz
        )
        appendMessage(message, to: id)
        transmit(message, in: id)
        return true
    }

    /// Re-key an existing message (failed send, or repeat an exchange).
    func resend(_ messageID: UUID, in id: UUID) {
        guard canTransmit, state != .transmitting,
              let conversation = conversation(id: id),
              let message = conversation.messages.first(where: { $0.id == messageID }),
              message.direction == .transmitted else { return }
        setStatus(.queued, messageID: messageID, in: id)
        transmit(message, in: id)
    }

    private func transmit(_ message: Message, in id: UUID) {
        // Connected Morserino keys the message; no audio path involved.
        if morserino.isReady {
            transmitViaMorserino(message, in: id)
            return
        }
        // Morserino link is mid-reconnect: failing honestly beats silently
        // keying audio out of the phone instead of the radio.
        if morserino.connectionState == .reconnecting {
            setStatus(.failed, messageID: message.id, in: id)
            return
        }

        // Need a running engine to play. Bring it up if listening is off.
        if !audio.isRunning { start(retrying: false) }
        guard audio.isRunning else {
            setStatus(.failed, messageID: message.id, in: id)
            return
        }

        state = .transmitting
        txToken = message.id
        txConversationID = id
        setStatus(.sending, messageID: message.id, in: id)
        modem.setMuted(true)
        Haptics.impact(.rigid)

        // Rendering a long over is millions of samples — keep it off main.
        modem.encodeAsync(message.text, settings: settings) { [weak self] samples in
            guard let self, self.txToken == message.id else { return }
            let gain = Float(max(0.05, min(1.0, self.settings.txLevel)))

            self.audio.play(samples, gain: gain) { played in
                DispatchQueue.main.async {
                    guard self.txToken == message.id else { return }
                    // `played == false` means the engine died mid-keying —
                    // a half-sent message must be shown as failed, not sent.
                    self.setStatus(played ? .sent : .failed, messageID: message.id, in: id)
                    self.finishTransmit()
                }
            }

            let timeout = CWAudioController.duration(ofSampleCount: samples.count) + 8
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, self.txToken == message.id else { return }
                self.setStatus(.failed, messageID: message.id, in: id)
                self.audio.cancelPlayback()
                self.finishTransmit()
            }
            self.txWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        }
    }

    /// Key via the Morserino. Completion is time-based: the device keys
    /// autonomously at the speed we push, so on-air duration is exact
    /// Morse timing plus a safety margin; disconnect mid-keying fails the
    /// message via onDisconnect.
    private func transmitViaMorserino(_ message: Message, in id: UUID) {
        state = .transmitting
        txToken = message.id
        txConversationID = id
        setStatus(.sending, messageID: message.id, in: id)
        // The rig's sidetone is audible to the mic — mute RX like the
        // audio path so we never decode our own keying.
        modem.setMuted(true)
        Haptics.impact(.rigid)

        morserino.setSpeed(settings.wpm)

        // cw/play is a no-op outside the device's CW Keyer menu — switch
        // first and give the menu change a beat to land.
        let keyDelay: TimeInterval
        if morserino.inKeyerMode {
            keyDelay = 0
        } else {
            morserino.startKeyerMode()
            keyDelay = 0.8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + keyDelay) { [weak self] in
            guard let self, self.txToken == message.id else { return }
            self.morserino.sendKeying(message.text)
        }

        let units = MorseCodec.encodeToTimings(message.text.uppercased())
            .reduce(0) { $0 + abs($1) }
        let duration = Double(units) * (1.2 / Double(max(settings.wpm, 5)))
        let done = DispatchWorkItem { [weak self] in
            guard let self, self.txToken == message.id else { return }
            self.setStatus(.sent, messageID: message.id, in: id)
            self.finishTransmit()
        }
        txMorserinoDone = done
        DispatchQueue.main.asyncAfter(deadline: .now() + keyDelay + duration + 1.5, execute: done)
    }

    func cancelTransmit() {
        guard let messageID = txToken, let conversationID = txConversationID else { return }
        if txMorserinoDone != nil {
            morserino.stopKeying()
        } else {
            audio.cancelPlayback()
        }
        setStatus(.failed, messageID: messageID, in: conversationID)
        finishTransmit()
    }

    private func finishTransmit() {
        txWatchdog?.cancel(); txWatchdog = nil
        txMorserinoDone?.cancel(); txMorserinoDone = nil
        txToken = nil
        txConversationID = nil
        modem.setMuted(false)
        state = audio.isRunning ? .listening : .stopped
        applyScreenPolicy()
    }

    // MARK: Conversations

    func conversation(id: UUID) -> Conversation? {
        conversations.first { $0.id == id }
    }

    /// The most recent thread with this station, if any. Callsigns aren't
    /// unique across threads (you can work the same operator twice), so
    /// incoming copy joins their newest conversation.
    private func newestConversation(with counterparty: String) -> Conversation? {
        conversations
            .filter { $0.counterparty == counterparty }
            .max { $0.lastActivity < $1.lastActivity }
    }

    /// Ensures a thread with this station exists and returns its id. Used
    /// when the operator taps a callsign in the Band Monitor — opening a
    /// thread yourself marks it read.
    @discardableResult
    func openConversation(_ counterparty: String) -> UUID {
        conversationID(with: counterparty.uppercased(), lastReadAt: Date())
    }

    private func conversationID(with counterparty: String, lastReadAt: Date) -> UUID {
        if let existing = newestConversation(with: counterparty) { return existing.id }
        let conversation = Conversation(counterparty: counterparty, lastReadAt: lastReadAt)
        conversations.append(conversation)
        sortConversations()
        persistConversations()
        return conversation.id
    }

    /// Begin a fresh general call. Always lands the operator in an empty
    /// thread — the previous CQ (and whatever QSO grew out of it) stops
    /// receiving, because a new call is a new conversation. An untouched CQ
    /// thread is reused rather than piling up duplicates.
    @discardableResult
    func startNewConversation() -> UUID {
        let id: UUID
        if let idle = conversations.first(where: { $0.isCQ && $0.messages.isEmpty }) {
            id = idle.id
        } else {
            let conversation = Conversation(counterparty: "CQ", lastReadAt: Date())
            conversations.append(conversation)
            sortConversations()
            persistConversations()
            id = conversation.id
        }
        // The previous CQ call is abandoned: its answer window closes with
        // it, or replies would keep echoing into a thread the operator has
        // moved on from.
        cqConversationID = nil
        lastCQActivity = .distantPast
        activate(id)
        return id
    }

    /// Point unaddressed copy at this thread, and only this thread.
    private func activate(_ id: UUID) {
        activeConversationID = id
        lastQSOActivity = Date()
    }

    func markRead(_ id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].lastReadAt = Date()
        persistConversations()
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if activeConversationID == id { activeConversationID = nil }
        if cqConversationID == id { cqConversationID = nil }
        persistConversations()
    }

    func clearMonitor() { monitor.removeAll() }

    private func appendMessage(_ message: Message, to id: UUID) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].messages.append(message)
        // Cap per-conversation history so long-running QSO threads don't
        // grow the persisted blob (re-encoded on save) without bound.
        if conversations[i].messages.count > maxMessagesPerConversation {
            conversations[i].messages.removeFirst(conversations[i].messages.count - maxMessagesPerConversation)
        }
        sortConversations()
    }

    /// Messages persisted while queued/sending can never advance after a
    /// relaunch — mark them failed so the UI tells the truth.
    nonisolated static func sanitized(_ conversations: [Conversation]) -> [Conversation] {
        conversations.map { conversation in
            var c = conversation
            c.messages = c.messages.map { message in
                var m = message
                if m.status == .queued || m.status == .sending { m.status = .failed }
                return m
            }
            return c
        }
    }

    private func setStatus(_ status: Message.Status, messageID: UUID, in id: UUID) {
        guard let ci = conversations.firstIndex(where: { $0.id == id }),
              let mi = conversations[ci].messages.firstIndex(where: { $0.id == messageID }) else { return }
        conversations[ci].messages[mi].status = status
        persistConversations()
    }

    private func sortConversations() {
        conversations.sort { $0.lastActivity > $1.lastActivity }
    }

    private var persistWork: DispatchWorkItem?

    /// Coalesce saves: one send hops queued→sending→sent and would re-encode
    /// the whole history three times in a row otherwise.
    private func persistConversations() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Persistence.saveConversations(self.conversations)
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: Settings

    private func settingsChanged(from old: StationSettings) {
        Persistence.saveSettings(settings)
        if old.toneHz != settings.toneHz
            || old.wpm != settings.wpm
            || old.decoder != settings.decoder
            || old.minWPM != settings.minWPM
            || old.maxWPM != settings.maxWPM {
            modem.updateSettings(settings)
        }
        if old.wpm != settings.wpm, morserino.isReady {
            morserino.setSpeed(settings.wpm)
        }
        if old.keepScreenOn != settings.keepScreenOn {
            applyScreenPolicy()
        }
    }

    /// Fill the grid square from a one-shot GPS lookup.
    func fetchGrid(_ completion: @escaping (Bool) -> Void) {
        location.fetchGrid { [weak self] grid in
            guard let self, let grid else { completion(false); return }
            self.settings.grid = grid
            completion(true)
        }
    }
}
