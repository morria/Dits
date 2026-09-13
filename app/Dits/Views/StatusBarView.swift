// The always-visible radio status strip pinned under the navigation bar:
// receive state, live speed/tone, a peek at the copy in progress, the
// input meter, and the start/stop control.

import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var radio: RadioController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                stateDot
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(subline)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.head)
                        .contentTransition(.opacity)
                }

                Spacer(minLength: 8)

                if radio.isListening {
                    LevelMeter(level: radio.inputLevel)
                }
                controlButton
            }
            .padding(.horizontal)
            .padding(.vertical, 7)
            // Below the status row, not above it: content directly under
            // the translucent navigation bar tints the whole header.
            if let call = radio.incomingCall {
                callingBanner(call)
            }
            Divider()
        }
        .background(.bar)
        .animation(.default, value: radio.state)
        .animation(.snappy, value: radio.incomingCall)
        .onTapGesture {
            // Permission errors are only fixable in Settings — take the
            // operator straight there instead of describing the journey.
            if case .error(let message) = radio.state,
               message.localizedCaseInsensitiveContains("permission"),
               let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        }
    }

    /// "K1ABC is calling you" — one tap opens the thread. A NavigationLink
    /// so it works from every screen inside the stack.
    private func callingBanner(_ call: RadioController.IncomingCall) -> some View {
        NavigationLink(value: RootView.Route.conversation(call.conversationID)) {
            HStack(spacing: 8) {
                Image(systemName: "phone.arrow.down.left.fill")
                    .symbolEffect(.pulse, options: .repeating)
                Text("\(call.callsign) is calling you")
                    .font(.footnote.weight(.semibold))
                Spacer()
                Text("Open")
                    .font(.footnote.weight(.semibold))
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.green.gradient)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(call.callsign) is calling you. Opens the conversation.")
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var stateDot: some View {
        ZStack {
            Circle().fill(dotColor.opacity(0.18)).frame(width: 26, height: 26)
            Image(systemName: dotSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(dotColor)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: radio.state == .transmitting)
        }
    }

    @ViewBuilder
    private var controlButton: some View {
        switch radio.state {
        case .transmitting:
            Button(role: .destructive) { radio.cancelTransmit() } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.red)
            .accessibilityLabel("Stop transmitting")
        case .error:
            Button { radio.start() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .accessibilityLabel("Retry audio")
        default:
            // Neutral tint: stopping the receiver is pause semantics, not
            // destruction — red stays reserved for aborting a transmission.
            Button { radio.toggleListening() } label: {
                Label(radio.isListening ? "Stop" : "Listen",
                      systemImage: radio.isListening ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(.accentColor)
            .accessibilityLabel(radio.isListening ? "Stop listening" : "Start listening")
        }
    }

    // MARK: Text

    private var headline: String {
        switch radio.state {
        case .stopped:      return "Not Listening"
        case .listening:    return radio.signalDetected ? "Copying" : "Listening"
        case .paused:       return "Paused"
        case .transmitting: return "Sending"
        case .error:        return "Audio Error"
        }
    }

    private var subline: String {
        switch radio.state {
        case .error(let message):
            return message
        case .stopped:
            return "Tap Listen to start decoding"
        case .paused:
            return "Audio interrupted — resuming automatically"
        case .transmitting:
            return radio.morserino.isReady
                ? "Keying via Morserino at \(radio.settings.wpm) WPM"
                : "Keying at \(radio.settings.wpm) WPM · receive muted"
        case .listening:
            if !radio.liveText.isEmpty { return radio.liveText }
            if radio.hearingKeying { return "Hearing keying · waiting for clean CW" }
            if let peak = radio.offTunePeakHz {
                return "Strong signal at \(peak) Hz · tuned to \(radio.settings.toneHz) Hz"
            }
            if radio.signalDetected, radio.currentWPM > 0, radio.detectedToneHz > 0 {
                // Speed, tone, and a plain-language read on conditions.
                return "\(radio.currentWPM) WPM · \(radio.detectedToneHz) Hz · \(copyQuality)"
            }
            return "Waiting for a signal · tuned to \(radio.settings.toneHz) Hz"
        }
    }

    /// Conditions in words a novice can act on, not S-units.
    private var copyQuality: String {
        if radio.signalStrength > 0.66 { return "strong copy" }
        if radio.signalStrength > 0.33 { return "workable" }
        return "weak copy"
    }

    private var dotColor: Color {
        switch radio.state {
        case .stopped:      return .secondary
        case .listening:    return radio.signalDetected ? .green : .accentColor
        case .paused:       return .orange
        case .transmitting: return .red
        case .error:        return .orange
        }
    }

    private var dotSymbol: String {
        switch radio.state {
        case .stopped:      return "pause.fill"
        case .listening:    return "antenna.radiowaves.left.and.right"
        case .paused:       return "pause.circle.fill"
        case .transmitting: return "dot.radiowaves.right"
        case .error:        return "exclamationmark.triangle.fill"
        }
    }
}
