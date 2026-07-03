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
            Divider()
        }
        .background(.bar)
        .animation(.default, value: radio.state)
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
        default:
            Button { radio.toggleListening() } label: {
                Label(radio.isListening ? "Stop" : "Listen",
                      systemImage: radio.isListening ? "stop.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .tint(radio.isListening ? .red : .accentColor)
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
            return "Keying at \(radio.settings.wpm) WPM · receive muted"
        case .listening:
            if !radio.liveText.isEmpty { return radio.liveText }
            if radio.currentWPM > 0, radio.detectedToneHz > 0 {
                // What we're actually copying: decoded speed + AFC-tracked tone.
                return "\(radio.currentWPM) WPM · \(radio.detectedToneHz) Hz"
            }
            return "Waiting for a signal · \(radio.settings.toneHz) Hz"
        }
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
