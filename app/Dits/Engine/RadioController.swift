// The single source of truth for the app. Owns the audio path and the CW
// decoder/keyer, turns the character stream into conversations and a live
// band monitor, and drives transmit. All published state mutates on the
// main actor; audio and DSP callbacks hop here before touching it.

import Foundation
import SwiftUI
import Combine

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

    @Published var settings: StationSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    // MARK: Collaborators

    private let audio = CWAudioController()
    private let modem: CWModemService
    private let location = LocationFetcher()

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
    private var txCounterparty: String?
    private var txWatchdog: DispatchWorkItem?

    // MARK: Init

    init() {
        let loaded = Persistence.loadSettings()
        self.settings = loaded
        self.modem = CWModemService(settings: loaded)
        // Messages persisted mid-transmit (app killed while keying) would
        // show an animated "Sending…" forever — no code path advances them.
        self.conversations = RadioController.sanitized(Persistence.loadConversations())
        sortConversations()

        audio.onInput = { [modem] samples in modem.feed(samples) }
        audio.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.inputLevel = level }
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

    func startIfNeeded() {
        // Base the decision on the actual audio path, not our own state —
        // after a failure `state` can claim listening over a dead engine.
        guard !audio.desiredRunning || !audio.isRunning else { return }
        start()
    }

    func start(retrying: Bool = true) {
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
        audio.stop()
        state = .stopped
        signalDetected = false
        inputLevel = 0
        commitSegment()
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

    // MARK: Receive pipeline

    private func handleCharacter(_ character: Character, wpm: Double, signal: Float, tone: Double) {
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
        guard text.count >= 2 else { return }

        let call = CallsignParser.counterparty(in: text, myCall: settings.callsign)
        let entry = DecodeEntry(
            text: text,
            wpm: max(currentWPM, 1),
            signal: Int((signalStrength * 100).rounded()),
            toneHz: detectedToneHz,
            callsign: call
        )
        monitor.append(entry)
        if monitor.count > maxMonitorEntries {
            monitor.removeFirst(monitor.count - maxMonitorEntries)
        }

        if let call {
            let message = Message(
                text: text,
                direction: .received,
                status: .received,
                callsign: call,
                wpm: entry.wpm,
                toneHz: entry.toneHz,
                signal: entry.signal
            )
            appendMessage(message, to: call)
        }
        persistConversations()
    }

    // MARK: Transmit

    /// True when the operator has set at least a callsign.
    var canTransmit: Bool { settings.isConfigured }

    @discardableResult
    func send(_ raw: String, to counterparty: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canTransmit else { return false }

        let message = Message(
            text: text.uppercased(),
            direction: .transmitted,
            status: .queued,
            callsign: counterparty == "CQ" ? nil : counterparty,
            wpm: settings.wpm,
            toneHz: settings.toneHz
        )
        appendMessage(message, to: counterparty)
        transmit(message, to: counterparty)
        return true
    }

    func callCQ() {
        _ = send(CWMacros.cqCall(callsign: settings.callsign), to: "CQ")
    }

    private func transmit(_ message: Message, to counterparty: String) {
        // Need a running engine to play. Bring it up if listening is off.
        if !audio.isRunning { start(retrying: false) }
        guard audio.isRunning else {
            setStatus(.failed, messageID: message.id, in: counterparty)
            return
        }

        state = .transmitting
        txToken = message.id
        txCounterparty = counterparty
        setStatus(.sending, messageID: message.id, in: counterparty)
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
                    self.setStatus(played ? .sent : .failed, messageID: message.id, in: counterparty)
                    self.finishTransmit()
                }
            }

            let timeout = CWAudioController.duration(ofSampleCount: samples.count) + 8
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self, self.txToken == message.id else { return }
                self.setStatus(.failed, messageID: message.id, in: counterparty)
                self.audio.cancelPlayback()
                self.finishTransmit()
            }
            self.txWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: watchdog)
        }
    }

    func cancelTransmit() {
        guard let id = txToken, let counterparty = txCounterparty else { return }
        audio.cancelPlayback()
        setStatus(.failed, messageID: id, in: counterparty)
        finishTransmit()
    }

    private func finishTransmit() {
        txWatchdog?.cancel(); txWatchdog = nil
        txToken = nil
        txCounterparty = nil
        modem.setMuted(false)
        state = audio.isRunning ? .listening : .stopped
        applyScreenPolicy()
    }

    // MARK: Conversations

    func conversation(for counterparty: String) -> Conversation? {
        conversations.first { $0.counterparty == counterparty }
    }

    /// Ensures a conversation exists and returns its key (for navigation).
    @discardableResult
    func openConversation(_ counterparty: String) -> String {
        let key = counterparty.uppercased()
        if !conversations.contains(where: { $0.counterparty == key }) {
            conversations.append(Conversation(counterparty: key, messages: [], lastReadAt: Date()))
            sortConversations()
            persistConversations()
        }
        return key
    }

    func markRead(_ counterparty: String) {
        guard let i = conversations.firstIndex(where: { $0.counterparty == counterparty }) else { return }
        conversations[i].lastReadAt = Date()
        persistConversations()
    }

    func deleteConversation(_ counterparty: String) {
        conversations.removeAll { $0.counterparty == counterparty }
        persistConversations()
    }

    func clearMonitor() { monitor.removeAll() }

    private func appendMessage(_ message: Message, to counterparty: String) {
        if let i = conversations.firstIndex(where: { $0.counterparty == counterparty }) {
            conversations[i].messages.append(message)
            // Cap per-conversation history so long-running QSO threads don't
            // grow the persisted blob (re-encoded on save) without bound.
            if conversations[i].messages.count > maxMessagesPerConversation {
                conversations[i].messages.removeFirst(conversations[i].messages.count - maxMessagesPerConversation)
            }
        } else {
            conversations.append(Conversation(counterparty: counterparty, messages: [message], lastReadAt: .distantPast))
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

    private func setStatus(_ status: Message.Status, messageID: UUID, in counterparty: String) {
        guard let ci = conversations.firstIndex(where: { $0.counterparty == counterparty }),
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
