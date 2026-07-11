// A single chat bubble. Outgoing bubbles take the accent color and carry
// a delivery caption; incoming bubbles are gray and, at the end of a
// group, show the speed and strength they were copied at.

import SwiftUI

struct MessageBubble: View {
    let message: Message
    var showsTail = true
    /// Delivery caption for the last outgoing message (set by the parent).
    var statusCaption: String?
    /// Re-key this message (failed sends offer it inline).
    var onResend: (() -> Void)?

    @State private var showExplanation = false

    private var isOutgoing: Bool { message.direction == .transmitted }

    private var explanation: [(term: String, meaning: String)] {
        CWAbbreviations.explain(message.text)
    }

    var body: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 3) {
            Text(message.text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(isOutgoing ? .white : .primary)
                .background(
                    BubbleShape(isOutgoing: isOutgoing, hasTail: showsTail)
                        .fill(bubbleColor)
                )
                .onTapGesture {
                    // Failed sends retry on tap, Messages-style.
                    if message.status == .failed, let onResend {
                        onResend()
                    }
                }
                .contextMenu {
                    if !isOutgoing, !explanation.isEmpty {
                        Button {
                            withAnimation(.snappy) { showExplanation.toggle() }
                        } label: {
                            Label(showExplanation ? "Hide Explanation" : "Explain",
                                  systemImage: "character.book.closed")
                        }
                    }
                    if isOutgoing, let onResend {
                        Button {
                            onResend()
                        } label: {
                            Label("Resend", systemImage: "arrow.clockwise")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = message.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }

            if showExplanation, !explanation.isEmpty {
                explanationView
            }

            caption
        }
        .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
        .padding(isOutgoing ? .leading : .trailing, 56)
        .padding(.bottom, showsTail ? 4 : 0)
    }

    private var explanationView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(explanation, id: \.term) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.term)
                        .font(.caption.monospaced().weight(.semibold))
                    Text(entry.meaning)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var bubbleColor: Color {
        guard isOutgoing else { return Color(.systemGray5) }
        switch message.status {
        case .queued:  return Color(.systemGray3)
        case .sending: return .orange
        case .failed:  return .red
        default:       return .accentColor
        }
    }

    @ViewBuilder
    private var caption: some View {
        if isOutgoing, let statusCaption {
            outgoingCaption(statusCaption)
        } else if !isOutgoing, showsTail, let wpm = message.wpm {
            HStack(spacing: 6) {
                Text(message.timestamp, style: .time)
                Text("· \(wpm) WPM")
                if let signal = message.signal {
                    SignalBars(strength: signal, tint: .signal(signal))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func outgoingCaption(_ text: String) -> some View {
        Group {
            if message.status == .sending {
                Label(text, systemImage: "dot.radiowaves.right")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
            } else {
                Text(text)
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(message.status == .failed ? .red : .secondary)
        .padding(.bottom, 4)
    }
}

/// A rounded-rect bubble with an optional Messages-style tail.
struct BubbleShape: Shape {
    var isOutgoing: Bool
    var hasTail: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = min(17, min(rect.width, rect.height) / 2)
        var path = Path(roundedRect: rect, cornerRadius: radius)
        guard hasTail else { return path }

        let y = rect.maxY
        let tip: CGFloat = 5.5
        var tail = Path()
        if isOutgoing {
            let x = rect.maxX
            tail.move(to: CGPoint(x: x - radius, y: y))
            tail.addLine(to: CGPoint(x: x, y: y - radius))
            tail.addQuadCurve(to: CGPoint(x: x + tip, y: y),
                              control: CGPoint(x: x + 0.5, y: y - 2))
            tail.closeSubpath()
        } else {
            let x = rect.minX
            tail.move(to: CGPoint(x: x + radius, y: y))
            tail.addQuadCurve(to: CGPoint(x: x - tip, y: y),
                              control: CGPoint(x: x - 0.5, y: y - 2))
            tail.addLine(to: CGPoint(x: x, y: y - radius))
            tail.closeSubpath()
        }
        path.addPath(tail)
        return path
    }
}
