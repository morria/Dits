// First-run welcome: explain the wired-radio setup and capture the
// operator's callsign and grid so they can transmit right away.

import SwiftUI

struct OnboardingSheet: View {
    @EnvironmentObject private var radio: RadioController
    @Environment(\.dismiss) private var dismiss

    @State private var callsign = ""
    @State private var grid = ""
    @State private var fetching = false

    private var valid: Bool { CallsignParser.isCallsign(callsign) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header

                    VStack(spacing: 14) {
                        FeatureRow(icon: "cable.connector", tint: .accentColor,
                                   title: "Wire up your radio",
                                   detail: "Connect your iPhone to your rig with a USB-C or Lightning audio interface.")
                        FeatureRow(icon: "antenna.radiowaves.left.and.right", tint: .green,
                                   title: "Copy the band",
                                   detail: "Dits decodes incoming Morse into clean, readable text.")
                        FeatureRow(icon: "paperplane.fill", tint: .orange,
                                   title: "Send by tapping",
                                   detail: "Type or tap a macro — Dits keys it out as perfectly timed CW.")
                    }
                    .padding(.horizontal)

                    VStack(spacing: 12) {
                        TextField("Your callsign", text: $callsign)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .multilineTextAlignment(.center)
                            .padding()
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

                        HStack {
                            TextField("Grid (optional)", text: $grid)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .font(.body.monospaced())
                                .multilineTextAlignment(.center)
                            Button {
                                fetching = true
                                radio.fetchGrid { ok in
                                    fetching = false
                                    if ok { grid = radio.settings.grid }
                                }
                            } label: {
                                if fetching { ProgressView() } else { Image(systemName: "location.fill") }
                            }
                            .buttonStyle(.borderless)
                            .disabled(fetching)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    Text("Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!valid)
                .padding()
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(false)
        .onAppear {
            callsign = radio.settings.callsign
            grid = radio.settings.grid
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 84, height: 84)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Welcome to Dits")
                .font(.largeTitle.bold())
            Text("The easiest way to work CW from your iPhone.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top)
    }

    private func save() {
        radio.settings.callsign = CallsignParser.normalized(callsign)
        radio.settings.grid = grid.uppercased()
        dismiss()
        radio.startIfNeeded()
    }
}

private struct FeatureRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
