// Template message editor (ported from Morserino-iOS): reorderable list
// of one-tap messages with {TOKEN} placeholders, plus a per-template
// edit form with a live "will send" preview.

import SwiftUI

struct TemplateMessagesView: View {
    @EnvironmentObject private var radio: RadioController

    /// Navigation target for a just-added template (add should edit).
    private struct NewTemplate: Identifiable, Hashable { let id: UUID }
    @State private var newTemplate: NewTemplate?

    var body: some View {
        List {
            Section {
                ForEach($radio.settings.quickMessages) { $template in
                    NavigationLink {
                        TemplateEditView(template: $template)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.label)
                                .font(.body.weight(.medium))
                            Text(template.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .onDelete { radio.settings.quickMessages.remove(atOffsets: $0) }
                .onMove { radio.settings.quickMessages.move(fromOffsets: $0, toOffset: $1) }

                Button {
                    let template = QuickMessage(label: "New Template", text: "")
                    radio.settings.quickMessages.append(template)
                    newTemplate = NewTemplate(id: template.id)
                } label: {
                    Label("Add Template", systemImage: "plus")
                }
            } footer: {
                Text("Templates appear above the message field and fill it when tapped. Placeholders {CALL}, {NAME}, {QTH}, {GRID}, and {THEIRCALL} are filled from your station details and the open conversation.")
            }
        }
        .navigationTitle("Templates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .navigationDestination(item: $newTemplate) { nav in
            if let index = radio.settings.quickMessages.firstIndex(where: { $0.id == nav.id }) {
                TemplateEditView(template: $radio.settings.quickMessages[index])
            }
        }
    }
}

struct TemplateEditView: View {
    @EnvironmentObject private var radio: RadioController
    @Binding var template: QuickMessage

    var body: some View {
        Form {
            Section("Label") {
                TextField("Label", text: $template.label)
            }
            Section {
                TextField("Message", text: $template.text, axis: .vertical)
                    .font(.callout.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .lineLimit(2...6)
            } header: {
                Text("Message")
            } footer: {
                previewText
            }
        }
        .navigationTitle(template.label)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var previewText: some View {
        let expanded = radio.settings.expand(template.text, theirCall: "K1ABC")
        return Text("Will send: \(expanded.text.uppercased())")
            .font(.caption.monospaced())
    }
}
