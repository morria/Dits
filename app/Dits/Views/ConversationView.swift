// A QSO thread: scrolling bubbles with hourly date separators, grouped
// tails, delivery captions, and the CW compose bar pinned to the bottom.

import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var radio: RadioController
    let counterparty: String

    @State private var draft = ""
    @FocusState private var composing: Bool
    @State private var sendCount = 0

    private var messages: [Message] {
        radio.conversation(for: counterparty)?.messages ?? []
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                        if showsDateSeparator(at: index) {
                            DateSeparator(date: message.timestamp)
                        }
                        MessageBubble(
                            message: message,
                            showsTail: isGroupEnd(at: index),
                            statusCaption: statusCaption(at: index)
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .overlay { if messages.isEmpty { emptyState } }
            .onChange(of: messages.count) {
                radio.markRead(counterparty)
                scrollToEnd(proxy)
            }
            .onChange(of: composing) { _, focused in
                if focused { scrollToEnd(proxy, animated: true) }
            }
        }
        .navigationTitle(counterparty == "CQ" ? "CQ" : counterparty)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ComposeBar(
                counterparty: counterparty,
                draft: $draft,
                composing: $composing,
                onSent: { sendCount += 1 }
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: sendCount)
        .onAppear {
            radio.markRead(counterparty)
            prefillIfNeeded()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: counterparty == "CQ" ? "megaphone" : "person.wave.2")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text(counterparty == "CQ" ? "Call CQ to get a QSO going."
                                      : "Send the first message to \(counterparty).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    // MARK: Behaviour

    private func prefillIfNeeded() {
        guard draft.isEmpty, messages.isEmpty, counterparty != "CQ" else { return }
        draft = CWMacros.reply(to: counterparty, callsign: radio.settings.callsign)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        guard let last = messages.last else { return }
        if animated {
            withAnimation(.snappy) { proxy.scrollTo(last.id, anchor: .bottom) }
        } else {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    // MARK: Grouping

    private func showsDateSeparator(at index: Int) -> Bool {
        guard index < messages.count else { return false }
        guard index > 0 else { return true }
        let prev = messages[index - 1].timestamp
        let curr = messages[index].timestamp
        return curr.timeIntervalSince(prev) > 3600
    }

    private func isGroupEnd(at index: Int) -> Bool {
        guard index < messages.count - 1 else { return true }
        let curr = messages[index]
        let next = messages[index + 1]
        if curr.direction != next.direction { return true }
        return next.timestamp.timeIntervalSince(curr.timestamp) > 60
    }

    private func statusCaption(at index: Int) -> String? {
        let message = messages[index]
        guard message.direction == .transmitted else { return nil }
        switch message.status {
        case .queued:  return "Waiting to send…"
        case .sending: return "Sending…"
        case .failed:  return "Not Sent"
        case .sent:
            let isLastOutgoing = !messages[(index + 1)...].contains { $0.direction == .transmitted }
            return isLastOutgoing ? "Sent" : nil
        case .received:
            return nil
        }
    }
}

private struct DateSeparator: View {
    let date: Date
    var body: some View {
        Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }
}
