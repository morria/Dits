// Field check: run a real off-air recording through the app's own
// receive path (CWModemService with the operator's settings) and print
// what would reach the transcript. Skipped unless OFFAIR names a WAV.

import XCTest
import AmateurDigitalCore
@testable import Dits

final class OffAirPipelineTests: XCTestCase {
    func testRecordingThroughService() {
        guard let path = ProcessInfo.processInfo.environment["OFFAIR"],
              let data = FileManager.default.contents(atPath: path), data.count > 44 else { return }
        let seconds = Double(ProcessInfo.processInfo.environment["SECONDS"] ?? "120") ?? 120
        let body = data.subdata(in: 44..<data.count)
        let all: [Float] = body.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
        }
        let samples = Array(all.prefix(Int(seconds * 48000)))

        var settings = StationSettings()
        settings.callsign = "W2ASM"
        settings.toneHz = Int(ProcessInfo.processInfo.environment["TONE"] ?? "700") ?? 700
        let service = CWModemService(settings: settings)
        var text = ""
        var events = 0
        service.onTextEvent = { event, _, _, _ in
            events += 1
            if case .character(let c, _) = event { text.append(c) }
        }
        var i = 0
        while i < samples.count {
            let end = min(i + 4096, samples.count)
            service.feed(Array(samples[i..<end]))
            i = end
        }
        service.flushPending()
        // Barrier: pollStatus queues behind every feed on the DSP queue,
        // so its completion means all audio (and the flush) went through.
        // Debug builds decode slower than real time — allow minutes.
        let done = expectation(description: "drain")
        service.pollStatus { _ in done.fulfill() }
        wait(for: [done], timeout: 1200)
        // Events hop to main after the barrier fires; let them land.
        let settled = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { settled.fulfill() }
        wait(for: [settled], timeout: 10)
        print("APP PIPELINE (\(settings.decoder), tone \(settings.toneHz), \(settings.minWPM)-\(settings.maxWPM) WPM): events=\(events) text=«\(text)»")
    }
}
