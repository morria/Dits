// A QSO thread: scrolling bubbles with hourly date separators, grouped
// tails, delivery captions, and the CW compose bar pinned to the bottom.

import SwiftUI

struct ConversationView: View {
    @EnvironmentObject private var radio: RadioController
    let conversationID: UUID

    @State private var draft = ""
    @FocusState private var composing: Bool
    @State private var sendCount = 0

    /// The thread's station, or "CQ" for a general call. Falls back to "CQ"
    /// only if the thread was deleted out from under this view.
    private var counterparty: String {
        radio.conversation(id: conversationID)?.counterparty ?? "CQ"
    }

    private var messages: [Message] {
        radio.conversation(id: conversationID)?.messages ?? []
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
                            statusCaption: statusCaption(at: index),
                            onResend: message.direction == .transmitted
                                ? { radio.resend(message.id, in: conversationID) }
                                : nil
                        )
                        .id(message.id)
                    }
                    // Copy in progress, right where it will land. Gray
                    // until the segment commits, when the same words
                    // reappear as a real (black) bubble in its place.
                    if showsLiveCopy {
                        ProvisionalBubble(text: radio.liveText, wpm: radio.currentWPM)
                            .id(liveBubbleID)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .animation(.easeInOut(duration: 0.15), value: showsLiveCopy)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .overlay { if messages.isEmpty && !showsLiveCopy { emptyState } }
            .onChange(of: messages.count) {
                radio.markRead(conversationID)
                scrollToEnd(proxy)
            }
            .onChange(of: radio.liveText) {
                if showsLiveCopy { scrollToEnd(proxy) }
            }
            .onChange(of: composing) { _, focused in
                if focused { scrollToEnd(proxy, animated: true) }
            }
        }
        .navigationTitle(counterparty == "CQ" ? "Calling CQ" : counterparty)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StatusBarView() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if quietSeconds >= 10 { tuningHint }
                ComposeBar(
                    conversationID: conversationID,
                    draft: $draft,
                    composing: $composing,
                    onSent: { sendCount += 1 }
                )
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: sendCount)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            // Waiting in a conversation with nothing arriving is where a
            // mistuned novice actually sits — surface the fix here.
            if radio.state == .listening && !radio.signalDetected && radio.liveText.isEmpty {
                quietSeconds += 5
            } else {
                quietSeconds = 0
            }
        }
        .onAppear {
            // The open thread is where copy goes — see RadioController.
            radio.setVisibleConversation(conversationID)
            radio.markRead(conversationID)
            prefillIfNeeded()
        }
        .onDisappear {
            radio.clearVisibleConversation(conversationID)
        }
    }

    @State private var quietSeconds = 0
    private let liveBubbleID = "live-copy"

    /// Copy is being decoded and this thread is where it will land.
    private var showsLiveCopy: Bool {
        !radio.liveText.isEmpty && radio.liveDestinationID == conversationID
    }

    private var tuningHint: some View {
        NavigationLink(value: RootView.Route.monitor) {
            HStack(spacing: 6) {
                Image(systemName: "dial.medium")
                Text("No CW tone near \(radio.settings.toneHz) Hz — tune in the Band Monitor")
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .buttonStyle(.plain)
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

    /// Open an empty thread with its opening call already in the field —
    /// never sent, just staged, so the first tap is Send rather than a
    /// blank page. A CQ thread opens with the general call; a named one
    /// with a reply to that station.
    private func prefillIfNeeded() {
        guard draft.isEmpty, messages.isEmpty else { return }
        draft = counterparty == "CQ"
            ? CWMacros.cqCall(callsign: radio.settings.callsign)
            : CWMacros.reply(to: counterparty, callsign: radio.settings.callsign)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let target: AnyHashable
        if showsLiveCopy {
            target = liveBubbleID
        } else if let last = messages.last {
            target = last.id
        } else {
            return
        }
        // Deferred a tick so a just-appended row is laid out before we
        // scroll to it (LazyVStack lays out on demand).
        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy) { proxy.scrollTo(target, anchor: .bottom) }
            } else {
                proxy.scrollTo(target, anchor: .bottom)
            }
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
        case .failed:  return "Not Sent · Tap to Retry"
        case .sent:
            // "on air", not "delivered" — CW has no receipts, and the
            // iMessage framing would promise one.
            let isLastOutgoing = !messages[(index + 1)...].contains { $0.direction == .transmitted }
            return isLastOutgoing ? "Sent on air" : nil
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
