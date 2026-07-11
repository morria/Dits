// The CW compose bar: a row of one-tap operating macros above a
// character-only text field, with a send/stop button and an on-air time
// estimate computed from the real Morse timing.

import SwiftUI
import AmateurDigitalCore

struct ComposeBar: View {
    @EnvironmentObject private var radio: RadioController
    let conversationID: UUID
    @Binding var draft: String
    @FocusState.Binding var composing: Bool
    var onSent: () -> Void

    @State private var missingFields: [String] = []
    /// Latched reply-speed suggestion. Held steady once detected so it
    /// doesn't flicker with signal detection between characters, and shown
    /// on its own row so it never reflows the template chips.
    @State private var replyWPM: Int?

    private var conversation: Conversation? { radio.conversation(id: conversationID) }
    private var counterparty: String { conversation?.counterparty ?? "CQ" }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isTransmitting: Bool { radio.state == .transmitting }
    private var canSend: Bool { !trimmed.isEmpty && radio.canTransmit }

    /// Last successfully sent message in this conversation — an empty
    /// compose field turns the send button into "repeat last message"
    /// (ported from Morserino-iOS, where repeats are the workhorse of
    /// calling CQ and re-sending exchanges).
    private var lastSentText: String? {
        conversation?.messages.last {
            $0.direction == .transmitted && $0.status == .sent
        }?.text
    }

    private var canRepeat: Bool {
        trimmed.isEmpty && lastSentText != nil && radio.canTransmit
    }

    var body: some View {
        VStack(spacing: 6) {
            if !radio.canTransmit {
                notice("Set your callsign in Settings to transmit.")
            }
            if !missingFields.isEmpty {
                notice("Fill in \(missingFieldNames) in Settings to use this template.")
            }
            if let wpm = replyWPM {
                speedBanner(wpm)
            }

            macroBar

            HStack(alignment: .bottom, spacing: 6) {
                TextField("Message · \(radio.settings.wpm) WPM", text: $draft, axis: .vertical)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .focused($composing)
                    .lineLimit(1...5)
                    .padding(.leading, 12)
                    .padding(.trailing, 38)
                    .padding(.vertical, 7)
                    .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(.quaternary, lineWidth: 1)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        sendButton.padding(3)
                    }
            }

            if !trimmed.isEmpty, onAirSeconds > 0 {
                HStack(spacing: 10) {
                    Spacer()
                    // Key-fright reducer: hear the message before keying it.
                    Button {
                        radio.previewDraft(trimmed)
                    } label: {
                        Label("Preview", systemImage: "speaker.wave.2")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .disabled(isTransmitting)
                    Text("≈ \(onAirSeconds, format: .number.precision(.fractionLength(0)))s on air at \(radio.settings.wpm) WPM")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(.bar)
        // Latch a reply-speed suggestion once, then hold it steady.
        .onChange(of: radio.currentWPM) { _, wpm in
            guard radio.signalDetected, wpm > 0,
                  abs(wpm - radio.settings.wpm) > 3 else { return }
            replyWPM = wpm
        }
        .onChange(of: radio.settings.wpm) { _, tx in
            // Applied or manually matched — clear the suggestion.
            if let r = replyWPM, abs(r - tx) <= 3 { replyWPM = nil }
        }
    }

    // MARK: Reply-speed suggestion

    /// A dedicated, dismissible row (not a chip in the scrolling row) so it
    /// never shifts the template chips underneath it. Tap the text to
    /// match speed; tap the ✕ to dismiss.
    private func speedBanner(_ wpm: Int) -> some View {
        HStack(spacing: 8) {
            Button {
                Haptics.selection()
                radio.settings.wpm = wpm   // onChange clears replyWPM
            } label: {
                Label("Reply at \(wpm) WPM", systemImage: "speedometer")
                    .font(.footnote.weight(.medium))
            }
            Spacer(minLength: 0)
            Button {
                replyWPM = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Dismiss speed suggestion")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Template messages

    /// Template chips fill the compose field with the expanded message —
    /// they never send directly. Templates referencing {THEIRCALL} are
    /// hidden when there's no counterparty to fill them with.
    private var macroBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                // Callsigns heard in the copy — one tap addresses a reply
                // to that station. Derived from committed messages, so the
                // set is stable (it doesn't flicker like live signal state).
                ForEach(detectedCallsigns, id: \.self) { call in
                    callsignChip(call)
                }
                ForEach(orderedTemplates) { template in
                    chip(template.label,
                         highlighted: template.label == suggestedLabel) { apply(template) }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    // MARK: Callsign chips

    /// Callsigns copied in this thread (most recent first), excluding my
    /// own and — in a named QSO — the counterparty itself (the Reply
    /// template already addresses them). In the CQ thread this surfaces
    /// answering stations as one-tap replies.
    private var detectedCallsigns: [String] {
        let mine = CallsignParser.normalized(radio.settings.callsign)
        let named = counterparty == "CQ" ? nil : CallsignParser.normalized(counterparty)
        var seen = Set<String>()
        var result: [String] = []
        let messages = conversation?.messages ?? []
        for message in messages.reversed() where message.direction == .received {
            for call in CallsignParser.callsigns(in: message.text) {
                let norm = CallsignParser.normalized(call)
                guard norm != mine, norm != named, seen.insert(norm).inserted else { continue }
                result.append(norm)
                if result.count >= 3 { return result }
            }
        }
        return result
    }

    private func callsignChip(_ call: String) -> some View {
        Button {
            Haptics.selection()
            replyTo(call)
        } label: {
            Label(call, systemImage: "antenna.radiowaves.left.and.right")
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
    }

    /// Address a reply to a specific heard station: <theirs> DE <mine>.
    /// Reuses the operator's "Reply" template if they have one so any
    /// customization carries over; otherwise a standard call.
    private func replyTo(_ call: String) {
        missingFields = []
        if let reply = radio.settings.quickMessages.first(where: { $0.label == "Reply" }) {
            let expanded = radio.settings.expand(reply.text, theirCall: call)
            if expanded.missing.isEmpty {
                draft = expanded.text.uppercased()
                return
            }
        }
        draft = "\(call) DE \(radio.settings.callsign) K".uppercased()
    }

    private var visibleTemplates: [QuickMessage] {
        radio.settings.quickMessages.filter { template in
            if counterparty == "CQ",
               template.text.range(of: "{THEIRCALL}", options: .caseInsensitive) != nil {
                return false
            }
            return true
        }
    }

    /// Guided QSO: float the template the standard exchange calls for
    /// next. Suggestion only — nothing ever sends itself.
    private var suggestedLabel: String? {
        guard radio.settings.guidedQSO else { return nil }
        return GuidedQSO.suggestion(
            messages: conversation?.messages ?? [],
            counterparty: counterparty,
            available: visibleTemplates.map(\.label)
        )
    }

    private var orderedTemplates: [QuickMessage] {
        guard let suggested = suggestedLabel,
              let index = visibleTemplates.firstIndex(where: { $0.label == suggested }),
              index > 0 else { return visibleTemplates }
        var ordered = visibleTemplates
        let template = ordered.remove(at: index)
        ordered.insert(template, at: 0)
        return ordered
    }

    private func apply(_ template: QuickMessage) {
        let expanded = radio.settings.expand(
            template.text,
            theirCall: counterparty == "CQ" ? nil : counterparty
        )
        guard expanded.missing.isEmpty else {
            missingFields = expanded.missing
            return
        }
        missingFields = []
        draft = expanded.text.uppercased()
    }

    private var missingFieldNames: String {
        missingFields.map { token in
            switch token {
            case "CALL": return "your callsign"
            case "NAME": return "your name"
            case "QTH": return "your location"
            case "GRID": return "your grid square"
            default: return token.lowercased()
            }
        }.joined(separator: ", ")
    }

    private func chip(_ label: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(label)
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(highlighted ? .accentColor : .secondary)
    }

    // MARK: Send button

    @ViewBuilder
    private var sendButton: some View {
        if isTransmitting {
            Button {
                radio.cancelTransmit()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(.red)
            }
        } else {
            Button(action: send) {
                Image(systemName: canRepeat ? "repeat.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 27))
                    .foregroundStyle((canSend || canRepeat) ? Color.accentColor : Color(.systemGray3))
            }
            .disabled(!canSend && !canRepeat)
            .accessibilityLabel(canRepeat ? "Repeat last message" : "Send")
            .accessibilityHint(canRepeat ? (lastSentText ?? "") : "")
        }
    }

    private func send() {
        missingFields = []
        if canSend {
            if radio.send(draft, in: conversationID) {
                draft = ""
                onSent()
            }
        } else if canRepeat, let last = lastSentText {
            if radio.send(last, in: conversationID) {
                onSent()
            }
        }
    }

    // MARK: Helpers

    private func notice(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(text)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Exact on-air duration from the Core Morse timing model.
    private var onAirSeconds: Double {
        let units = MorseCodec.encodeToTimings(trimmed.uppercased())
            .reduce(0) { $0 + abs($1) }
        let ditSeconds = 1.2 / Double(max(1, radio.settings.wpm))
        return Double(units) * ditSeconds
    }
}
