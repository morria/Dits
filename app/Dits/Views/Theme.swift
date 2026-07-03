// Small shared visual helpers: signal-strength coloring, the level/signal
// meter, and relative time formatting. Keeps the views themselves lean.

import SwiftUI

extension Color {
    /// Waterfall-style coloring for a 0–100 signal strength.
    static func signal(_ strength: Int) -> Color {
        switch strength {
        case 70...:  return .green
        case 45...:  return .mint
        case 25...:  return .yellow
        case 10...:  return .orange
        default:     return .secondary
        }
    }
}

/// A compact five-bar strength indicator.
struct SignalBars: View {
    var strength: Int          // 0–100
    var tint: Color = .accentColor
    var barCount = 5

    var body: some View {
        let filled = Int((Double(strength) / 100.0 * Double(barCount)).rounded(.toNearestOrAwayFromZero))
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(i < filled ? tint : Color(.systemGray4))
                    .frame(width: 3, height: 6 + CGFloat(i) * 2.5)
            }
        }
        .accessibilityLabel("Signal \(strength) percent")
    }
}

/// A horizontal input-level meter that animates smoothly.
struct LevelMeter: View {
    var level: Float           // 0–1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.systemGray5))
                Capsule()
                    .fill(LinearGradient(
                        colors: [.green, .green, .yellow, .orange],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, geo.size.width * CGFloat(min(1, level))))
            }
        }
        .frame(width: 46, height: 5)
        .animation(.linear(duration: 0.12), value: level)
        .accessibilityHidden(true)
    }
}

enum RelativeTime {
    /// Messages-style short stamp: time today, weekday this week, else date.
    static func short(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = cal.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
