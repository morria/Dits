// Off-air recorder: captures the exact mono 48 kHz stream the decoder
// hears into a WAV in Documents (visible in the Files app). A field
// failure becomes a corpus recording we can replay through
// `CWBenchmark --corpus` at home, instead of an anecdote.

import Foundation

final class FieldRecorder {

    /// Hard cap so a forgotten recording can't fill the phone (~55 MB).
    static let maxSeconds = 600

    private let queue = DispatchQueue(label: "com.w2asm.dits.recorder", qos: .utility)
    private var handle: FileHandle?
    private var url: URL?
    private var frames = 0
    private let sampleRate = 48_000

    /// Benign-race fast path so the audio callback pays one Bool read
    /// when idle.
    private(set) var isArmed = false

    /// Fired on main when the length cap auto-stops the recording.
    var onAutoStop: (() -> Void)?

    /// Starts a new recording; returns the destination URL.
    @discardableResult
    func start() -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "OffAir-\(stamp.string(from: Date())).wav"
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destination = documents.appendingPathComponent(name)

        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let file = try? FileHandle(forWritingTo: destination) else { return nil }

        queue.sync {
            handle = file
            url = destination
            frames = 0
            file.write(Self.wavHeader(frames: 0, sampleRate: sampleRate))
        }
        isArmed = true
        return destination
    }

    /// Safe to call from the audio thread.
    func append(_ samples: [Float]) {
        guard isArmed else { return }
        queue.async {
            guard let handle = self.handle else { return }
            var pcm = Data(capacity: samples.count * 2)
            for sample in samples {
                var value = Int16(max(-1, min(1, sample)) * 32767)
                withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
            }
            handle.write(pcm)
            self.frames += samples.count
            if self.frames >= Self.maxSeconds * self.sampleRate {
                self.finish()
                DispatchQueue.main.async { self.onAutoStop?() }
            }
        }
    }

    /// Returns the finished file's URL.
    @discardableResult
    func stop() -> URL? {
        isArmed = false
        var finished: URL?
        queue.sync {
            finished = url
            finish()
        }
        return finished
    }

    var seconds: Int {
        queue.sync { frames / sampleRate }
    }

    private func finish() {
        guard let handle else { return }
        // Patch the RIFF/data sizes now that the length is known.
        try? handle.seek(toOffset: 0)
        handle.write(Self.wavHeader(frames: frames, sampleRate: sampleRate))
        try? handle.close()
        self.handle = nil
        self.url = nil
        isArmed = false
    }

    private static func wavHeader(frames: Int, sampleRate: Int) -> Data {
        let dataSize = UInt32(frames * 2)
        var header = Data()
        func append(_ string: String) { header.append(string.data(using: .ascii)!) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(UInt32(sampleRate)); append32(UInt32(sampleRate * 2))
        append16(2); append16(16)
        append("data"); append32(dataSize)
        return header
    }
}
