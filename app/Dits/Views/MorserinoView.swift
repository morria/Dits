// Morserino-32 connection screen: scan, connect, device status, and
// keyer-mode control. Standard inset-grouped list per the HIG — status
// first, actionable rows below, destructive action last.

import SwiftUI

struct MorserinoView: View {
    @EnvironmentObject private var radio: RadioController
    @ObservedObject var keyer: MorserinoKeyer

    var body: some View {
        List {
            statusSection
            if keyer.isReady {
                deviceSection
            } else {
                discoverySection
            }
        }
        .navigationTitle("Morserino")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !keyer.isReady { keyer.startScanning() }
        }
        .onDisappear {
            keyer.stopScanning()
        }
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            HStack {
                Image(systemName: keyer.isReady ? "dot.radiowaves.up.forward" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundStyle(keyer.isReady ? .green : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusHeadline)
                        .font(.body.weight(.medium))
                    Text(statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if keyer.connectionState == .connecting || keyer.connectionState == .scanning
                    || keyer.connectionState == .reconnecting {
                    ProgressView()
                }
                if keyer.connectionState == .reconnecting {
                    Button("Cancel") { keyer.disconnect() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            .padding(.vertical, 2)
        } footer: {
            Text("When a Morserino is connected, messages are keyed by the Morserino instead of being sent as audio.")
        }
    }

    private var statusHeadline: String {
        switch keyer.connectionState {
        case .idle:         return "Not Connected"
        case .scanning:     return "Searching…"
        case .connecting:   return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .ready:        return keyer.deviceName ?? "Morserino"
        }
    }

    private var statusDetail: String {
        switch keyer.connectionState {
        case .ready:
            return keyer.inKeyerMode
                ? "Connected · CW Keyer mode"
                : "Connected · not in keyer mode"
        case .scanning:
            return "Make sure the Morserino is on and nearby"
        case .connecting:
            return "Establishing link"
        case .reconnecting:
            return "Will reattach when \(keyer.deviceName ?? "the device") is back in range"
        case .idle:
            return "Messages are sent as audio"
        }
    }

    // MARK: Connected device

    private var deviceSection: some View {
        Section("Device") {
            if let firmware = keyer.firmware {
                LabeledContent("Firmware", value: firmware)
            }
            if let battery = keyer.batteryStatus {
                LabeledContent("Battery", value: battery)
            }
            LabeledContent("Keying Speed", value: "\(radio.settings.wpm) WPM")

            if !keyer.inKeyerMode {
                if keyer.keyerMenuAvailable {
                    Button {
                        keyer.startKeyerMode()
                    } label: {
                        Label("Start CW Keyer Mode", systemImage: "play.circle")
                    }
                } else {
                    Label("Select CW Keyer on the device", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }

            Button(role: .destructive) {
                keyer.disconnect()
            } label: {
                Label("Disconnect", systemImage: "xmark.circle")
            }
        }
    }

    // MARK: Discovery

    private var discoverySection: some View {
        Section {
            if keyer.devices.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Looking for Morserino devices…")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(keyer.devices) { device in
                    Button {
                        keyer.connect(device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .foregroundStyle(.primary)
                                Text("Signal \(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .disabled(keyer.connectionState == .connecting)
                }
            }
        } header: {
            Text("Devices")
        } footer: {
            Text("Requires a Morserino-32 with BLE serial firmware.")
        }
    }
}
