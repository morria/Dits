// Live audio spectrum over the CW band (300–1100 Hz) with the decoder
// frequency marked. Tapping (or dragging) retunes the decoder — the most
// common real-world decode failure is simply not being on frequency.

import SwiftUI

struct SpectrumStripView: View {
    @EnvironmentObject private var radio: RadioController

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawBars(context: context, size: size)
                }
                markers(width: geo.size.width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        tune(atX: value.location.x, width: geo.size.width)
                    }
            )
        }
        .frame(height: 44)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Audio spectrum, 300 to 1100 hertz. Tap to tune the decoder.")
    }

    private func drawBars(context: GraphicsContext, size: CGSize) {
        let bars = radio.spectrum
        guard !bars.isEmpty else { return }
        let barWidth = size.width / CGFloat(bars.count)
        for (i, level) in bars.enumerated() {
            let h = max(1, CGFloat(level) * (size.height - 4))
            let rect = CGRect(x: CGFloat(i) * barWidth,
                              y: size.height - h,
                              width: max(1, barWidth - 1),
                              height: h)
            context.fill(Path(rect), with: .color(.accentColor.opacity(0.35 + 0.65 * Double(level))))
        }
    }

    @ViewBuilder
    private func markers(width: CGFloat) -> some View {
        // Configured decoder frequency (tap target).
        marker(atHz: Double(radio.settings.toneHz), width: width, color: .accentColor, dashed: false)
        // AFC-tracked tone of the station actually being copied.
        if radio.signalDetected, radio.detectedToneHz > 0 {
            marker(atHz: Double(radio.detectedToneHz), width: width, color: .green, dashed: true)
        }
    }

    private func marker(atHz hz: Double, width: CGFloat, color: Color, dashed: Bool) -> some View {
        let span = SpectrumAnalyzer.bandHighHz - SpectrumAnalyzer.bandLowHz
        let x = CGFloat((hz - SpectrumAnalyzer.bandLowHz) / span) * width
        return Path { p in
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: 44))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : []))
    }

    private func tune(atX x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let span = SpectrumAnalyzer.bandHighHz - SpectrumAnalyzer.bandLowHz
        let hz = SpectrumAnalyzer.bandLowHz + Double(x / width) * span
        radio.setToneFrequency(hz)
        Haptics.impact(.light)
    }
}
