// The CW compose bar: a row of one-tap operating macros above a
// character-only text field, with a send/stop button and an on-air time
// estimate computed from the real Morse timing.

import SwiftUI
import AmateurDigitalCore

struct ComposeBar: View {
    @EnvironmentObject private var radio: RadioController
    let counterparty: String
    @Binding var draft: String
    @FocusState.Binding var composing: Bool
    var onSent: () -> Void

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isTransmitting: Bool { radio.state == .transmitting }
    private var canSend: Bool { !trimmed.isEmpty && radio.canTransmit }

    var body: some View {
        VStack(spacing: 6) {
            if !radio.canTransmit {
                notice("Set your callsign in Settings to transmit.")
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
                Text("≈ \(onAirSeconds, format: .number.precision(.fractionLength(0)))s on air at \(radio.settings.wpm) WPM")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 7)
        .background(.bar)
    }

    // MARK: Macros

    private var macroBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                if trimmed.isEmpty {
                    chip("Call CQ", systemImage: "megaphone") {
                        draft = CWMacros.cqCall(callsign: radio.settings.callsign)
                    }
                }
                ForEach(CWMacros.chips(callsign: radio.settings.callsign, counterparty: counterparty)) { macro in
                    chip(macro.label) { insert(macro) }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    private func chip(_ label: String, systemImage: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            if let systemImage {
                Label(label, systemImage: systemImage)
            } else {
                Text(label)
            }
        }
        .font(.footnote.weight(.medium))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.small)
        .tint(label == "Call CQ" ? .accentColor : .secondary)
    }

    private func insert(_ macro: CWMacro) {
        if macro.prependSpace, !draft.isEmpty, !draft.hasSuffix(" ") {
            draft += " "
        }
        draft += macro.insert
        draft += " "
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
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 27))
                    .foregroundStyle(canSend ? Color.accentColor : Color(.systemGray3))
            }
            .disabled(!canSend)
        }
    }

    private func send() {
        guard canSend else { return }
        if radio.send(draft, to: counterparty) {
            draft = ""
            onSent()
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
