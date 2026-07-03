// Start a new QSO: enter a callsign, or jump straight to calling CQ.

import SwiftUI

struct NewConversationSheet: View {
    @EnvironmentObject private var radio: RadioController
    @Environment(\.dismiss) private var dismiss
    var onStart: (String) -> Void

    @State private var callsign = ""
    @FocusState private var focused: Bool

    private var valid: Bool { CallsignParser.isCallsign(callsign) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Callsign", text: $callsign)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit { if valid { start(callsign) } }
                } footer: {
                    Text("Enter the station you want to work.")
                }

                Section {
                    Button {
                        start("CQ")
                    } label: {
                        Label("Call CQ", systemImage: "megaphone")
                    }
                }
            }
            .navigationTitle("New Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") { start(callsign) }
                        .disabled(!valid)
                }
            }
            .onAppear { focused = true }
        }
    }

    private func start(_ counterparty: String) {
        let key = counterparty == "CQ" ? "CQ" : CallsignParser.normalized(callsign)
        dismiss()
        onStart(key)
    }
}
