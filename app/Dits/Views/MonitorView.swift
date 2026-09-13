// The live band monitor: every committed transmission as it's copied,
// plus a highlighted line for the copy in progress. This is the raw,
// unfiltered feed — the heart of operating CW.

import SwiftUI

struct MonitorView: View {
    @EnvironmentObject private var radio: RadioController
    var openConversation: (String) -> Void
    @State private var filter = ""

    private var filtered: [DecodeEntry] {
        guard !filter.isEmpty else { return radio.monitor }
        let needle = filter.uppercased()
        return radio.monitor.filter {
            $0.text.uppercased().contains(needle) || ($0.callsign?.contains(needle) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if radio.isListening {
                SpectrumStripView()
                    .padding(.horizontal)
                    .padding(.top, 8)
                tuningRow
                    .padding(.horizontal)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                if let peak = radio.offTunePeakHz {
                    offTuneHint(peak)
                        .padding(.horizontal)
                        .padding(.bottom, 6)
                }
            }
            if radio.isRecordingOffAir {
                recordingBanner
            }
            monitorList
        }
        .navigationTitle("Band Monitor")
        .navigationBarTitleDisplayMode(.inline)
        // The live readout and the Listen/Stop control belong on the
        // screens where the operator watches the band, not only on home.
        .safeAreaInset(edge: .top, spacing: 0) { StatusBarView() }
        .searchable(text: $filter, prompt: "Filter copy or callsign")
        .animation(.snappy, value: radio.offTunePeakHz)
        .toolbar {
            Menu {
                Toggle(isOn: $radio.settings.skimmerEnabled) {
                    Label("Band Skimmer", systemImage: "waveform.badge.magnifyingglass")
                }
                if radio.isListening {
                    Button {
                        radio.toggleOffAirRecording()
                    } label: {
                        Label(radio.isRecordingOffAir ? "Stop Recording" : "Record Off-Air Audio",
                              systemImage: radio.isRecordingOffAir ? "stop.circle" : "record.circle")
                    }
                }
                if !radio.monitor.isEmpty {
                    Button(role: .destructive) { radio.clearMonitor() } label: {
                        Label("Clear Monitor", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
    }

    // MARK: Tuning

    /// Where the decoder is listening, and whether the skimmer is
    /// widening that — the two facts a "why is nothing decoding?"
    /// operator needs at a glance, right under the spectrum they're
    /// looking at.
    private var tuningRow: some View {
        HStack(spacing: 10) {
            Label {
                Text("Tuned \(radio.settings.toneHz) Hz · ±\(RadioController.captureHalfWidthHz) Hz")
                    .monospacedDigit()
            } icon: {
                Image(systemName: "dial.medium")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .accessibilityLabel("Tuned to \(radio.settings.toneHz) hertz, capturing plus or minus \(RadioController.captureHalfWidthHz) hertz. Tap the spectrum to retune.")

            Spacer(minLength: 4)

            Button {
                Haptics.selection()
                radio.settings.skimmerEnabled.toggle()
            } label: {
                Label(radio.settings.skimmerEnabled ? "Skimmer On" : "Skimmer Off",
                      systemImage: radio.settings.skimmerEnabled ? "waveform.badge.magnifyingglass" : "waveform.slash")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
            .tint(radio.settings.skimmerEnabled ? .orange : .secondary)
            .accessibilityLabel("Band skimmer")
            .accessibilityValue(radio.settings.skimmerEnabled ? "on" : "off")
            .accessibilityHint("Also decodes the two strongest signals outside the tuned range")
        }
    }

    /// A loud signal the decoder can't hear from where it's tuned. One
    /// tap fixes it; the strip's capture band shows why.
    private func offTuneHint(_ peak: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Strong signal at \(peak) Hz is outside the tuned range")
                .lineLimit(2)
            Spacer(minLength: 4)
            Button {
                Haptics.impact(.light)
                radio.setToneFrequency(Double(peak))
            } label: {
                Text("Tune")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.mini)
            .accessibilityLabel("Tune to \(peak) hertz")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var monitorList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { entry in
                        ActivityRow(entry: entry, openConversation: openConversation)
                            .id(entry.id)
                        Divider()
                    }
                    if !radio.liveText.isEmpty && filter.isEmpty {
                        LiveRow(text: radio.liveText, wpm: radio.currentWPM)
                            .id("live")
                    } else if radio.hearingKeying && filter.isEmpty {
                        HearingRow()
                            .id("hearing")
                    }
                    // Anchor so we can pin the newest content to the
                    // bottom only when the list overflows.
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
            // Top-filling like a log (a freshly cleared or short monitor
            // reads top-down, not pinned to the bottom edge under the
            // search bar); jump to newest as content arrives and on open.
            .onChange(of: radio.monitor.count) { scrollToBottom(proxy) }
            .onChange(of: radio.liveText) { scrollToBottom(proxy) }
            .onChange(of: radio.hearingKeying) { scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
        .overlay {
            if radio.monitor.isEmpty && radio.liveText.isEmpty {
                ContentUnavailableView {
                    Label(radio.hearingKeying ? "Hearing Keying" : "No Activity Yet",
                          systemImage: radio.hearingKeying ? "ear" : "waveform")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    if !radio.isListening {
                        Button("Start Listening") { radio.start() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    /// Say what's actually happening, not just that nothing has
    /// appeared: off-tune, heard-but-held, or genuinely quiet.
    private var emptyDescription: String {
        guard radio.isListening else { return "Start listening to watch the band." }
        if radio.hearingKeying {
            return "Keying is coming in at \(radio.settings.toneHz) Hz, but it hasn't shown a clean CW rhythm yet. Copy appears once it does."
        }
        if let peak = radio.offTunePeakHz {
            return "A strong signal at \(peak) Hz is outside the tuned range. Tap it in the spectrum, or use Tune above."
        }
        return "Listening at \(radio.settings.toneHz) Hz (±\(RadioController.captureHalfWidthHz) Hz). Tap a peak in the spectrum to tune to it."
    }

    private var recordingBanner: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("Recording off-air audio · \(radio.recordingSeconds / 60):\(String(format: "%02d", radio.recordingSeconds % 60))")
                .monospacedDigit()
            Spacer()
            Button("Stop") { radio.stopOffAirRecording() }
        }
        .font(.caption)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        // Deferred a tick so the just-appended row is laid out before we
        // scroll to it (LazyVStack lays out on demand).
        DispatchQueue.main.async {
            let scroll = { proxy.scrollTo("bottom", anchor: .bottom) }
            if animated { withAnimation(.snappy, scroll) } else { scroll() }
        }
    }
}

private struct ActivityRow: View {
    let entry: DecodeEntry
    var openConversation: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
                .font(.subheadline.monospaced())
                .foregroundStyle(entry.isNoise ? .tertiary : (entry.isProvisional ? .secondary : .primary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Text(entry.timestamp, style: .time)
                Label("\(entry.wpm) WPM", systemImage: "speedometer")
                Label("\(entry.toneHz) Hz", systemImage: entry.isSkimmed ? "waveform.badge.magnifyingglass" : "waveform")
                    .foregroundStyle(entry.isSkimmed ? .orange : .secondary)
                Spacer()
                SignalBars(strength: entry.signal, tint: .signal(entry.signal))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            // Where this copy went — or didn't. "Thrown away" is never
            // silent: noise is shown faint and labelled, and copy that
            // failed callsign routing says it stayed here.
            if entry.isNoise || entry.isSkimmed {
                HStack(spacing: 10) {
                    if entry.isNoise {
                        Label("Probably noise · not routed", systemImage: "waveform.path")
                    }
                    if entry.isSkimmed {
                        Label("Skimmer", systemImage: "waveform.badge.magnifyingglass")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
            }

            if let call = entry.callsign {
                Button {
                    openConversation(call)
                } label: {
                    Label(call, systemImage: "arrowshape.turn.up.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .contextMenu {
            if let call = entry.callsign {
                Button { openConversation(call) } label: {
                    Label("Message \(call)", systemImage: "arrowshape.turn.up.right")
                }
            }
            Button {
                UIPasteboard.general.string = entry.text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}

/// Keying is being heard on the tuned frequency but the decoder is
/// holding it back until it proves to be CW (or has dropped it as
/// noise). Without this row the operator sees a lively spectrum and an
/// empty monitor and concludes the app is broken.
private struct HearingRow: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "ear")
                .symbolEffect(.pulse, options: .repeating)
            Text("Hearing keying — waiting for a clean CW rhythm before showing copy")
                .lineLimit(2)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct LiveRow: View {
    let text: String
    let wpm: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                // Gray while provisional; the committed row above it is
                // what turns black.
                Text(text)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                Text("▌")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Label("Copying now\(wpm > 0 ? " · \(wpm) WPM" : "")", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption2)
                .foregroundStyle(.green)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
