# Dits

iOS CW (Morse) messenger. SwiftUI, iOS 17+, XcodeGen. The CW modem is the
`AmateurDigitalCore` Swift package referenced from the sibling
`../Amateur-Digital/AmateurDigital/AmateurDigitalCore` checkout.

## Build & test

```bash
cd app && xcodegen generate                       # regenerate Dits.xcodeproj from project.yml
xcodebuild -project app/Dits.xcodeproj -scheme Dits \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project app/Dits.xcodeproj -scheme Dits \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`Dits.xcodeproj` is generated — never edit it by hand; edit `app/project.yml`.

## Layout

```
app/project.yml                 XcodeGen source of truth (bundle com.w2asm.dits, team 7Q2SS8772K)
app/Dits/
  App/DitsApp.swift             @main, owns RadioController
  Engine/
    RadioController.swift       @MainActor store: state, conversations, monitor, TX
    CWModemService.swift        Classic/Bayesian/Diversity decoders + TX encode (uniform CWReceiving)
    Persistence.swift           UserDefaults JSON
  Audio/CWAudioController.swift AVAudioEngine .measurement; tap → 48k mono Float; AVAudioPlayerNode TX
  Models/                       Message, Conversation, DecodeEntry, StationSettings
  Utilities/                    CallsignParser, Maidenhead, CWMacros, Haptics, LocationFetcher
  Views/                        RootView, StatusBarView, ConversationListView, ConversationView,
                                MessageBubble, ComposeBar, MonitorView, SettingsView,
                                NewConversationSheet, OnboardingSheet, Theme
  Assets.xcassets/              AppIcon (tools/make_icon.py), AccentColor
app/DitsTests/                  CW roundtrip, CallsignParser, Maidenhead, CWMacros
tools/                          make_icon.py, install-device.sh, upload-testflight.sh
```

## Key design points

- **CW has no addressing.** Conversations are keyed by callsign parsed from
  the copy. Routing is deliberately conservative — `CallsignParser.counterparty`
  requires "DE \<call\>" structure so band noise never spawns junk threads.
  The Band Monitor shows the raw, unfiltered feed regardless.
- **Half-duplex.** RX is muted (and the decoder reset) while transmitting so
  the app never decodes its own sidetone. TX render happens off-main
  (`encodeAsync`); completion uses `.dataPlayedBack` + an engine-alive check
  so a half-keyed message is reported failed, never sent.
- **Audio resilience.** `CWAudioController` observes interruptions, route
  changes, engine-config changes, and media-services resets; restarts while
  `desiredRunning`; a 2 s watchdog restarts on silent input and gives up
  (with `.died`) after 4 strikes. `RadioController` surfaces `.paused` /
  `.error` honestly. `start()` is idempotent (tap removed before install).
- **Segment commit adapts to speed** — `RadioController.commitDelay(forWPM:)`
  is 2.5× the word gap, clamped to 1.2–4.0 s, so 5 WPM fists aren't split
  mid-transmission and 30 WPM copy commits promptly.
- **Decoder choice** lives in `StationSettings.decoder` (default: diversity =
  `DualCWDecoder`); `CWModemService` rebuilds the backend on change,
  debounced 0.6 s so slider drags don't destroy decode state. All three
  implement `CWReceiving`; min/max WPM pass through to every backend.
- **No iCloud / network** — settings persist to UserDefaults to keep signing
  trivial. Saves are debounced; per-conversation history capped at 500;
  an undecodable store is preserved under a backup key, never overwritten.
  Mic + location are gated by Info.plist usage strings only.
- **Demo mode** (DEBUG only): `SIMCTL_CHILD_DITS_DEMO=1`, optional
  `SIMCTL_CHILD_DITS_OPEN=chat|monitor|settings` for screenshots. Compiled
  out of Release.

## Decoder quality (library work lives in ../Amateur-Digital)

The decoders are in `AmateurDigitalCore`; measure with
`swift run -c release CWBenchmark` (`--dual` = the app's shipped decoder,
`--bayesian-only`, default = classic). Composite as of 2026-07:
**97.03** for classic and dual (baselines were 91.33 / 89.26). Key fixes
made from this project (in the library working tree):
- AFC no longer retunes away from a healthy signal (noise/QRM capture bug
  that corrupted characters at every SNR), and initial-scan ordering is
  fixed so acquisition still works at ±200 Hz.
- `thresholdFractionClean` 0.20 → 0.08 (AGC-pumping resilience, 62 → 100).
- `DualCWDecoder` merge rewritten: sample-based clock, order-preserving,
  agreement-fraction reliability (not output rate), `flush()`, min/max WPM.
- Benchmark: added `--dual`, made ITU seeds deterministic.

## Deploy

- Device: `tools/install-device.sh` (iPhone connected, unlocked, trusted).
- TestFlight: `tools/upload-testflight.sh` (needs the App Store Connect app
  record for com.w2asm.dits + signed-in Xcode account).
