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
                    .padding(.bottom, 4)
            }
            if radio.isRecordingOffAir {
                recordingBanner
            }
            monitorList
        }
        .navigationTitle("Band Monitor")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Filter copy or callsign")
        .toolbar {
            Menu {
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
        }
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
            .onAppear { scrollToBottom(proxy, animated: false) }
        }
        .overlay {
            if radio.monitor.isEmpty && radio.liveText.isEmpty {
                ContentUnavailableView {
                    Label("No Activity Yet", systemImage: "waveform")
                } description: {
                    Text(radio.isListening
                         ? "Listening… anything you copy will appear here."
                         : "Start listening to watch the band.")
                } actions: {
                    if !radio.isListening {
                        Button("Start Listening") { radio.start() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
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
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                Text(entry.timestamp, style: .time)
                Label("\(entry.wpm) WPM", systemImage: "speedometer")
                Label("\(entry.toneHz) Hz", systemImage: "waveform")
                Spacer()
                SignalBars(strength: entry.signal, tint: .signal(entry.signal))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

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

private struct LiveRow: View {
    let text: String
    let wpm: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(text)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.primary)
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
