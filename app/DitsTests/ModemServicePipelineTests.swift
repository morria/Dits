// The app's actual receive path: audio into CWModemService.feed, text
// events out on main. The round-trip test drives the Core decoder
// directly; this one drives the service the way RadioController does.

import XCTest
import AmateurDigitalCore
@testable import Dits

final class ModemServicePipelineTests: XCTestCase {

    func testFeedProducesTextEvents() {
        var settings = StationSettings()
        settings.callsign = "W2ASM"
        settings.wpm = 20
        settings.toneHz = 600
        let service = CWModemService(settings: settings)
        let samples = service.encode("CQ CQ DE W2ASM K", settings: settings)

        var text = ""
        let sawCopy = expectation(description: "characters arrive on main")
        sawCopy.assertForOverFulfill = false
        service.onTextEvent = { event, _, _, _ in
            if case .character(let c, _) = event {
                text.append(c)
                if text.contains("W2ASM") { sawCopy.fulfill() }
            }
        }

        service.feed([Float](repeating: 0, count: 24000))
        var i = 0
        while i < samples.count {
            let end = min(i + 4096, samples.count)
            service.feed(Array(samples[i..<end]))
            i = end
        }
        service.feed([Float](repeating: 0, count: 48000))
        // Debug builds decode slower than real time on the simulator.
        wait(for: [sawCopy], timeout: 120)
        XCTAssertTrue(text.contains("CQ CQ DE W2ASM"), "got «\(text)»")
    }
}

extension ModemServicePipelineTests {
    /// A skimmer channel is a classic decoder behind the same revising
    /// wrapper; its copy must still reach the skimmer callback.
    func testSkimChannelDecodesOffChannelSignal() {
        var settings = StationSettings()
        settings.callsign = "W2ASM"
        settings.wpm = 22
        settings.toneHz = 600
        let service = CWModemService(settings: settings)

        var offChannel = settings
        offChannel.toneHz = 900
        let samples = service.encode("CQ TEST DE W1XYZ", settings: offChannel)

        var text = ""
        let sawCopy = expectation(description: "skimmer copy arrives on main")
        sawCopy.assertForOverFulfill = false
        service.onSkimCharacter = { c, hz, _, _ in
            XCTAssertEqual(hz, 900)
            text.append(c)
            if text.contains("W1XYZ") { sawCopy.fulfill() }
        }
        service.setSkimChannels([900], settings: settings)

        service.feed([Float](repeating: 0, count: 24000))
        var i = 0
        while i < samples.count {
            let end = min(i + 4096, samples.count)
            service.feed(Array(samples[i..<end]))
            i = end
        }
        service.feed([Float](repeating: 0, count: 48000))
        wait(for: [sawCopy], timeout: 120)
        XCTAssertTrue(text.contains("CQ TEST DE W1XYZ"), "got «\(text)»")
    }
}
