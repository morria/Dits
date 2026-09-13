// Live audio spectrum over the CW band (300–1100 Hz) with the decoder's
// tuned frequency and its capture range marked. Tapping (or dragging)
// retunes the decoder — the most common real-world decode failure is
// simply not being on frequency, so the strip has to say where the
// decoder is listening, not just where the energy is.

import SwiftUI

struct SpectrumStripView: View {
    @EnvironmentObject private var radio: RadioController

    private static let height: CGFloat = 52
    private static let ticksHz: [Int] = [400, 600, 800, 1000]

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    drawCaptureBand(context: context, size: size)
                    drawBars(context: context, size: size)
                    drawScale(context: context, size: size)
                }
                markers(width: geo.size.width)
                tunedLabel(width: geo.size.width)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        tune(atX: value.location.x, width: geo.size.width)
                    }
            )
        }
        .frame(height: Self.height)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Audio spectrum, 300 to 1100 hertz")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Tap to tune the decoder")
    }

    private var accessibilityValue: String {
        var parts = ["Tuned to \(radio.settings.toneHz) hertz, capturing plus or minus \(RadioController.captureHalfWidthHz) hertz"]
        if radio.signalDetected, radio.detectedToneHz > 0 {
            parts.append("copying a signal at \(radio.detectedToneHz) hertz")
        }
        if let peak = radio.offTunePeakHz {
            parts.append("strong signal at \(peak) hertz outside the tuned range")
        }
        if !radio.skimChannelsHz.isEmpty {
            parts.append("skimmer decoding at " + radio.skimChannelsHz.map { "\($0)" }.joined(separator: " and ") + " hertz")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Drawing

    private func x(forHz hz: Double, width: CGFloat) -> CGFloat {
        let span = SpectrumAnalyzer.bandHighHz - SpectrumAnalyzer.bandLowHz
        return CGFloat((hz - SpectrumAnalyzer.bandLowHz) / span) * width
    }

    /// The ±capture band around the tuned tone — the only part of the
    /// strip the decoder can actually hear from.
    private func drawCaptureBand(context: GraphicsContext, size: CGSize) {
        let center = Double(radio.settings.toneHz)
        let half = Double(RadioController.captureHalfWidthHz)
        let x0 = x(forHz: center - half, width: size.width)
        let x1 = x(forHz: center + half, width: size.width)
        let rect = CGRect(x: x0, y: 0, width: x1 - x0, height: size.height)
        context.fill(Path(rect), with: .color(.accentColor.opacity(0.12)))
    }

    private func drawBars(context: GraphicsContext, size: CGSize) {
        let bars = radio.spectrum
        guard !bars.isEmpty else { return }
        let barWidth = size.width / CGFloat(bars.count)
        let usable = size.height - 14   // leave room for the scale
        for (i, level) in bars.enumerated() {
            let h = max(1, CGFloat(level) * usable)
            let rect = CGRect(x: CGFloat(i) * barWidth,
                              y: size.height - h,
                              width: max(1, barWidth - 1),
                              height: h)
            context.fill(Path(rect), with: .color(.accentColor.opacity(0.35 + 0.65 * Double(level))))
        }
    }

    /// Frequency ticks along the top so a peak can be read in hertz.
    private func drawScale(context: GraphicsContext, size: CGSize) {
        for hz in Self.ticksHz {
            let px = x(forHz: Double(hz), width: size.width)
            var tick = Path()
            tick.move(to: CGPoint(x: px, y: 0))
            tick.addLine(to: CGPoint(x: px, y: 4))
            context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
            let label = Text("\(hz)").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundColor(.secondary)
            context.draw(context.resolve(label), at: CGPoint(x: px, y: 9), anchor: .center)
        }
    }

    @ViewBuilder
    private func markers(width: CGFloat) -> some View {
        // Configured decoder frequency (tap target).
        marker(atHz: Double(radio.settings.toneHz), width: width, color: .accentColor, dashed: false, lineWidth: 2)
        // AFC-tracked tone of the station actually being copied.
        if radio.signalDetected, radio.detectedToneHz > 0 {
            marker(atHz: Double(radio.detectedToneHz), width: width, color: .green, dashed: true, lineWidth: 1.5)
        }
        // Skimmer channels: thin, so they read as secondary.
        ForEach(radio.skimChannelsHz, id: \.self) { hz in
            marker(atHz: Double(hz), width: width, color: .orange, dashed: true, lineWidth: 1)
        }
    }

    private func marker(atHz hz: Double, width: CGFloat, color: Color, dashed: Bool, lineWidth: CGFloat) -> some View {
        let px = x(forHz: hz, width: width)
        return Path { p in
            p.move(to: CGPoint(x: px, y: 14))
            p.addLine(to: CGPoint(x: px, y: Self.height))
        }
        .stroke(color, style: StrokeStyle(lineWidth: lineWidth, dash: dashed ? [3, 2] : []))
    }

    /// The tuned frequency, pinned beside its marker (kept inside the
    /// strip at the edges).
    private func tunedLabel(width: CGFloat) -> some View {
        let px = x(forHz: Double(radio.settings.toneHz), width: width)
        let text = Text("\(radio.settings.toneHz) Hz")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Color(.secondarySystemBackground).opacity(0.85), in: Capsule())
        return text
            .fixedSize()
            .alignmentGuide(.leading) { d in
                // Flip to the left of the marker near the right edge.
                px + 4 + d.width > width ? -(px - d.width - 4) : -(px + 4)
            }
            .padding(.top, 16)
    }

    private func tune(atX x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let span = SpectrumAnalyzer.bandHighHz - SpectrumAnalyzer.bandLowHz
        let hz = SpectrumAnalyzer.bandLowHz + Double(x / width) * span
        radio.setToneFrequency(hz)
        Haptics.impact(.light)
    }
}
