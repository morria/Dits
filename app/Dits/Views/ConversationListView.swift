// Home screen: a Messages-style list of QSOs plus a prominent entry into
// the live band monitor.

import SwiftUI

struct ConversationListView: View {
    @EnvironmentObject private var radio: RadioController
    var openConversation: (String) -> Void
    var openMonitor: () -> Void

    var body: some View {
        List {
            Section {
                Button(action: openMonitor) {
                    MonitorRow()
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            }

            if radio.conversations.isEmpty {
                Section {
                    emptyHint
                        .listRowBackground(Color.clear)
                }
            } else {
                Section("Conversations") {
                    ForEach(radio.conversations) { conversation in
                        Button { openConversation(conversation.counterparty) } label: {
                            ConversationRow(conversation: conversation)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            radio.deleteConversation(radio.conversations[index].counterparty)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
                .padding(.top, 24)
            Text("No conversations yet")
                .font(.headline)
            Text("Start listening and stations you copy will show up here. Tap the pencil to call CQ.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 8)
    }
}

private struct MonitorRow: View {
    @EnvironmentObject private var radio: RadioController

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Band Monitor")
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if radio.signalDetected {
                Image(systemName: "waveform")
                    .foregroundStyle(.green)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private var subtitle: String {
        if !radio.liveText.isEmpty { return radio.liveText }
        if let last = radio.monitor.last { return last.text }
        return radio.isListening ? "Listening for activity…" : "Everything you copy, live"
    }
}

private struct ConversationRow: View {
    let conversation: Conversation

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(conversation.unreadCount > 0 ? Color.accentColor : .clear)
                .frame(width: 9, height: 9)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.counterparty)
                        .font(.headline)
                    Spacer()
                    if let last = conversation.lastMessage {
                        Text(RelativeTime.short(last.timestamp))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(preview)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
        }
        .contentShape(Rectangle())
    }

    private var preview: String {
        guard let last = conversation.lastMessage else { return "No messages yet" }
        let prefix = last.direction == .transmitted ? "You: " : ""
        return prefix + last.text
    }
}
