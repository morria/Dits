// Setup ready-check: answers "why does it decode nothing?" in one
// screen, in plain language — the question every novice hits first.
// Three audio states (no input / input but no tone / copying) plus the
// Morserino link, with a safe keyed test.

import SwiftUI

struct SetupCheckView: View {
    @EnvironmentObject private var radio: RadioController
    @State private var sentTest = false

    var body: some View {
        List {
            audioSection
            morserinoSection
        }
        .navigationTitle("Setup Check")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { radio.startIfNeeded() }
    }

    // MARK: Radio audio

    private var audioSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: audioSymbol)
                    .font(.title3)
                    .foregroundStyle(audioTint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(audioHeadline).font(.body.weight(.medium))
                    Text(audioDetail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            if radio.isListening {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Input Level")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ProgressView(value: Double(min(radio.inputLevel, 1)))
                        .tint(radio.inputLevel > 0.02 ? .green : .secondary)
                        .accessibilityLabel("Input level")
                        .accessibilityValue("\(Int(radio.inputLevel * 100)) percent")
                }
                SpectrumStripView()
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            } else {
                Button("Start Listening") { radio.start() }
            }
        } header: {
            Text("Radio Audio")
        } footer: {
            Text("Connect your radio's audio output to the iPhone with a wired interface. A CW tone shows as a peak in the spectrum — tap it to tune the decoder.")
        }
    }

    private var audioState: Int {
        guard radio.isListening else { return 0 }
        if radio.signalDetected || !radio.liveText.isEmpty { return 3 }
        if radio.inputLevel > 0.02 { return 2 }
        return 1
    }

    private var audioSymbol: String {
        ["pause.circle", "mic.slash", "waveform.badge.magnifyingglass", "checkmark.circle.fill"][audioState]
    }

    private var audioTint: Color {
        [.secondary, .orange, .orange, .green][audioState]
    }

    private var audioHeadline: String {
        switch audioState {
        case 0: return "Not listening"
        case 1: return "No audio coming in"
        case 2: return "Audio present — no CW tone yet"
        default: return radio.liveText.isEmpty ? "Copying CW" : "Copying: \(radio.liveText)"
        }
    }

    private var audioDetail: String {
        switch audioState {
        case 0: return "Start listening to test the audio path"
        case 1: return "Check the cable, interface, and radio volume"
        case 2: return "Tune the radio to a CW signal, or check the tone control"
        default: return "The audio path is working"
        }
    }

    // MARK: Morserino

    private var morserinoSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: radio.morserino.isReady
                      ? "checkmark.circle.fill" : "dot.radiowaves.up.forward")
                    .font(.title3)
                    .foregroundStyle(radio.morserino.isReady ? .green : .secondary)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(radio.morserino.isReady
                         ? (radio.morserino.deviceName ?? "Morserino")
                         : "Not connected")
                        .font(.body.weight(.medium))
                    Text(radio.morserino.isReady
                         ? "Messages will be keyed by the Morserino"
                         : "Optional — connect under Settings › Morserino")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            if radio.morserino.isReady {
                Button {
                    radio.morserino.sendKeying("TEST")
                    sentTest = true
                } label: {
                    Label(sentTest ? "Key TEST Again" : "Key TEST",
                          systemImage: "dot.radiowaves.right")
                }
            }
        } header: {
            Text("Morserino")
        } footer: {
            if radio.morserino.isReady {
                Text("Keys the word TEST on the Morserino so you can hear it — if a transmitter is attached, this goes on the air.")
            }
        }
    }
}

// MARK: - Glossary

/// Searchable plain-English dictionary of CW abbreviations.
struct GlossaryView: View {
    @State private var query = ""

    private var entries: [(term: String, meaning: String)] {
        guard !query.isEmpty else { return CWAbbreviations.glossary }
        let needle = query.uppercased()
        return CWAbbreviations.glossary.filter {
            $0.term.contains(needle) || $0.meaning.uppercased().contains(needle)
        }
    }

    var body: some View {
        List(entries, id: \.term) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.term)
                    .font(.body.monospaced().weight(.semibold))
                    .frame(minWidth: 56, alignment: .leading)
                Text(entry.meaning)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "Search abbreviations")
        .navigationTitle("CW Glossary")
        .navigationBarTitleDisplayMode(.inline)
    }
}
