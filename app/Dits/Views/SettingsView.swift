// Operator and operating settings, presented as a grouped form sheet.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var radio: RadioController
    @Environment(\.dismiss) private var dismiss
    @State private var fetchingLocation = false

    var body: some View {
        NavigationStack {
            Form {
                stationSection
                messagesSection
                transmitSection
                keyerSection
                receiveSection
                displaySection
                setupSection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: Station

    private var callsignValid: Bool {
        let c = radio.settings.callsign
        return c.isEmpty || CallsignParser.isCallsign(c)
    }

    private var stationSection: some View {
        Section {
            TextField("Callsign", text: $radio.settings.callsign)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())

            HStack {
                TextField("Grid square (optional)", text: $radio.settings.grid)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                Button {
                    fetchingLocation = true
                    radio.fetchGrid { _ in fetchingLocation = false }
                } label: {
                    if fetchingLocation {
                        ProgressView()
                    } else {
                        Image(systemName: "location.fill")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(fetchingLocation)
            }

            TextField("Name (optional)", text: $radio.settings.operatorName)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()

            TextField("Location (optional)", text: $radio.settings.qth)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
        } header: {
            Text("Station")
        } footer: {
            if !callsignValid {
                Text("That doesn't look like a valid amateur callsign.")
                    .foregroundStyle(.red)
            } else {
                Text("Your callsign identifies you on the air and groups your QSOs.")
            }
        }
    }

    // MARK: Transmit

    private var wpm: Binding<Double> {
        Binding(get: { Double(radio.settings.wpm) },
                set: { radio.settings.wpm = Int($0.rounded()) })
    }

    private var tone: Binding<Double> {
        Binding(get: { Double(radio.settings.toneHz) },
                set: { radio.settings.toneHz = Int($0.rounded()) })
    }

    private var transmitSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Speed")
                    Spacer()
                    Text("\(radio.settings.wpm) WPM").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: wpm, in: StationSettings.wpmRange, step: 1) {
                    Text("Speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise")
                } maximumValueLabel: {
                    Image(systemName: "hare")
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Tone")
                    Spacer()
                    Text("\(radio.settings.toneHz) Hz").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: tone, in: StationSettings.toneRange, step: 10)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Transmit Level")
                    Spacer()
                    Text("\(Int(radio.settings.txLevel * 100))%").foregroundStyle(.secondary).monospacedDigit()
                }
                Slider(value: $radio.settings.txLevel, in: 0.1...1.0, step: 0.05)
            }
        } header: {
            Text("Transmit")
        } footer: {
            Text("Set the transmit level so your radio shows little or no ALC. Keying uses VOX or your CAT/PTT interface.")
        }
    }

    // MARK: Messages

    private var messagesSection: some View {
        Section {
            NavigationLink {
                TemplateMessagesView()
            } label: {
                LabeledContent("Templates",
                               value: "\(radio.settings.quickMessages.count)")
            }
            Toggle("Guided QSO", isOn: $radio.settings.guidedQSO)
            NavigationLink("CW Glossary") {
                GlossaryView()
            }
        } header: {
            Text("Messages")
        } footer: {
            Text("Templates fill the compose field with one tap. Guided QSO floats the template the standard exchange calls for next.")
        }
    }

    // MARK: Setup

    private var setupSection: some View {
        Section {
            NavigationLink {
                SetupCheckView()
            } label: {
                Label("Setup Check", systemImage: "stethoscope")
            }
        } footer: {
            Text("Verify audio is arriving and CW is decoding.")
        }
    }

    // MARK: Keyer

    private var keyerSection: some View {
        Section {
            NavigationLink {
                MorserinoView(keyer: radio.morserino)
            } label: {
                LabeledContent("Morserino") {
                    if radio.morserino.isReady {
                        Label(radio.morserino.deviceName ?? "Connected",
                              systemImage: "dot.radiowaves.up.forward")
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Text("Not Connected")
                    }
                }
            }
        } header: {
            Text("Keyer")
        } footer: {
            Text("With a Morserino-32 connected, messages are keyed by the Morserino instead of being sent as audio.")
        }
    }

    // MARK: Receive

    private var receiveSection: some View {
        Section {
            Toggle("Band Skimmer", isOn: $radio.settings.skimmerEnabled)

            // Expert knobs stay out of a novice's way; the defaults are
            // the right answer for almost everyone.
            DisclosureGroup("Advanced") {
                Picker("Decoder", selection: $radio.settings.decoder) {
                    ForEach(CWDecoder.allCases) { decoder in
                        Text(decoder.title).tag(decoder)
                    }
                }
                .pickerStyle(.segmented)

                Stepper(value: $radio.settings.minWPM, in: 4...20) {
                    HStack {
                        Text("Slowest Copy")
                        Spacer()
                        Text("\(radio.settings.minWPM) WPM").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Stepper(value: $radio.settings.maxWPM, in: 25...60) {
                    HStack {
                        Text("Fastest Copy")
                        Spacer()
                        Text("\(radio.settings.maxWPM) WPM").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        } header: {
            Text("Receive")
        } footer: {
            Text("The skimmer also decodes the two strongest off-channel signals into the Band Monitor. Advanced: \(radio.settings.decoder.detail) Narrow the speed range if noise keeps decoding as very fast or very slow characters.")
        }
    }

    // MARK: Display

    private var displaySection: some View {
        Section {
            Toggle("Keep Screen Awake", isOn: $radio.settings.keepScreenOn)
        } header: {
            Text("Display")
        } footer: {
            Text("Stops the screen from locking while you're listening.")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: appVersion)
            LabeledContent("Decoder Engine", value: "AmateurDigitalCore")
        } header: {
            Text("About")
        } footer: {
            Text("Dits is a CW messenger. Connect your iPhone to your radio with a wired audio interface to send and copy Morse.")
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
