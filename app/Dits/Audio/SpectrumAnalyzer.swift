// Lightweight FFT band analyzer behind the tuning strip and the skimmer.
// Fed mono 48 kHz samples on the audio thread; publishes smoothed
// magnitudes for the 300–1100 Hz CW band on the main thread (~12 Hz).

import Accelerate
import Foundation

final class SpectrumAnalyzer {

    /// One analyzed FFT frame over the CW band.
    struct Frame {
        /// Linear power per bin (un-smoothed), for peak picking.
        let power: [Float]
        /// 0–1 display heights (smoothed, dB-mapped, rolling-max normalized).
        let normalized: [Float]
        /// Frequency of the first bin in Hz.
        let startHz: Double
        /// Bin width in Hz.
        let binHz: Double

        func frequency(ofBin i: Int) -> Double { startHz + Double(i) * binHz }
    }

    static let bandLowHz: Double = 300
    static let bandHighHz: Double = 1100

    private let fftSize = 4096                 // 85 ms @ 48 kHz → 11.7 Hz/bin
    private let log2n: vDSP_Length = 12
    private let sampleRate: Double
    private let setup: FFTSetup
    private var window: [Float]
    private var buffer: [Float] = []
    private var smoothed: [Float]
    private var maxEMA: Float = 1e-6
    private let queue = DispatchQueue(label: "com.w2asm.dits.spectrum", qos: .utility)
    private let binLow: Int
    private let binCount: Int

    /// Fired on the main thread for every analyzed frame.
    var onFrame: ((Frame) -> Void)?

    init?(sampleRate: Double = 48_000) {
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s
        self.sampleRate = sampleRate
        let binHz = sampleRate / Double(fftSize)
        self.binLow = Int(Self.bandLowHz / binHz)
        self.binCount = Int(Self.bandHighHz / binHz) - binLow + 1
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = w
        self.smoothed = [Float](repeating: 0, count: binCount)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    private var paused = false

    /// Safe to call from the audio thread.
    func feed(_ samples: [Float]) {
        queue.async {
            guard !self.paused else { return }
            self.process(samples)
        }
    }

    /// Skip FFT work entirely (backgrounded — nobody can see the strip).
    func setPaused(_ paused: Bool) {
        queue.async {
            self.paused = paused
            if paused { self.buffer.removeAll() }
        }
    }

    func reset() {
        queue.async {
            self.buffer.removeAll()
            self.smoothed = [Float](repeating: 0, count: self.binCount)
            self.maxEMA = 1e-6
        }
    }

    private func process(_ samples: [Float]) {
        buffer.append(contentsOf: samples)
        while buffer.count >= fftSize {
            let chunk = Array(buffer.prefix(fftSize))
            buffer.removeFirst(fftSize)
            analyze(chunk)
        }
    }

    private func analyze(_ chunk: [Float]) {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(chunk, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: binCount)

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2,
                              &split, 1, vDSP_Length(fftSize / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                var mags = [Float](repeating: 0, count: fftSize / 2)
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(fftSize / 2))
                for i in 0..<binCount { power[i] = mags[binLow + i] }
            }
        }

        // Fast attack / slow decay per bin, then map to dB relative to a
        // rolling band maximum so the strip reads the same at any gain.
        var frameMax: Float = 1e-9
        for i in 0..<binCount {
            let p = power[i]
            smoothed[i] = p > smoothed[i]
                ? p * 0.6 + smoothed[i] * 0.4
                : smoothed[i] * 0.75 + p * 0.25
            frameMax = max(frameMax, smoothed[i])
        }
        maxEMA = max(frameMax, maxEMA * 0.98)
        let floorPower = maxEMA * 1e-4                     // 40 dB display range
        var normalized = [Float](repeating: 0, count: binCount)
        for i in 0..<binCount {
            let db = 10 * log10(max(smoothed[i], floorPower) / floorPower)
            normalized[i] = min(1, db / 40)
        }

        let frame = Frame(power: power,
                          normalized: normalized,
                          startHz: Double(binLow) * sampleRate / Double(fftSize),
                          binHz: sampleRate / Double(fftSize))
        DispatchQueue.main.async { self.onFrame?(frame) }
    }
}
