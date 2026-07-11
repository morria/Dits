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
                                OnboardingSheet, Theme
  Assets.xcassets/              AppIcon (tools/make_icon.py), AccentColor
app/DitsTests/                  CW roundtrip, CallsignParser, Maidenhead, CWMacros
tools/                          make_icon.py, install-device.sh, upload-testflight.sh
```

## Key design points

- **CW has no addressing.** Copy is routed to a thread by the callsign parsed
  out of it. Routing is deliberately conservative — `CallsignParser.counterparty`
  requires "DE \<call\>" structure so band noise never spawns junk threads.
  The Band Monitor shows the raw, unfiltered feed regardless. For the same
  reason there is no "new conversation" sheet: you can't address a station
  you haven't heard, so the compose button starts a fresh CQ thread
  (opening call prefilled, never auto-sent). You work a specific station by
  answering it — from the Band Monitor, or its existing thread.
- **Conversations have identity, not callsign keys.** `Conversation.id` is a
  UUID (legacy stores are migrated on load and written back once, so ids stop
  moving). Several CQ threads coexist — one per call you make — and copy joins
  the *newest* thread with a given station. Exactly one thread is `active`:
  it receives unaddressed copy inside `qsoReplyWindow` (5 min). Keying,
  starting a new call, or a parsed callsign moves `active`, so an old thread
  never quietly keeps collecting. `startNewConversation()` always lands in an
  empty thread (reusing an untouched CQ rather than duplicating it) and
  retires the previous CQ's answer window. `RadioController.commitCopy` is
  internal, not private, so `ConversationRoutingTests` can drive routing
  without an audio path.
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
`--bayesian-only`, default = classic; `--fp-only` = fast subset for
false-positive tuning). Composite as of 2026-07-10: **classic 96.8,
bayesian 96.7, dual 96.7** — the suite gained three acoustic
false-positive scenarios (impulsive_room, level_wander, tone_flutter:
what an idle iPhone mic actually hears; all three decoders now score
100 on the false_positive category), so these are NOT comparable to
the 2026-07-03 suite-v2 numbers (97.2/97.2/97.1), which are themselves
not comparable to v1 (97.03). Known cost: jitter/40pct (extreme-fist
edge case) no longer copies — its dit/dah clusters are statistically
indistinguishable from noise under the emission probation. Fast tuning loop: JSON param
overrides via `--params` (classic) / `--bayesian-params` (bayesian),
no rebuild needed. Real-audio corpus: `CWBenchmark --corpus <dir>`
scores WAVs against sidecar `.txt` transcripts (kept out of the
composite as an overfitting check); `DecodeWAV --mode cw` decodes a
single recording. Key architecture (2026-07-03 pass, both decoders
unless noted):
- Hysteresis tone gate (ON at the adaptive threshold, OFF at 0.4× with a
  3×-noise floor) — AGC-pumping immunity without element stretching.
- Min-statistics noise floor (cap at 6× the rolling min of smoothed
  power) — recovers from tone-contaminated startup within ~1 s.
- Two-consecutive-block bootstrap + idle un-bootstrap + SNR-gated
  emission — an idle band stays silent for hours instead of E/T chatter.
- Adaptive gap clustering (nearest-log-cluster learning, order-statistic
  word threshold) — Farnsworth and compressed fists both copy.
- Phase-slope fine AFC (Goertzel complex output) — follows continuous
  drift up to ~5 Hz/s without rebuilding the FIR; coarse AFC keeps the
  never-abandon-healthy-signal veto.
- Noise blanker ahead of the FIR — QRN static crashes no longer ring
  through the narrow filter.
- Bayesian: beam search prunes against the Morse tree with a ham-text
  character prior; prosigns (SK/CT/SOS/SN) decode as `<SK>` etc.
- `resynchronize()` preserves calibration across the app's TX mute
  (reset() would re-learn the noise floor while the reply is starting).
- Sub-block edge timing: quarter-block Goertzel refinement at gate
  transitions (fractional element/gap durations; neutral 0.5 fractions
  reproduce legacy whole-block behavior when SNR is poor) — 30–40 WPM
  hand-sent jitter now copies clean.
- Emission probation (2026-07-10, both decoders): post-bootstrap
  characters are held until element/gap timing proves CW-like rhythm
  (tight dit/dah clusters ~3× apart, per-class CV ≤ 0.28, gaps on the
  1/3/7-dit grid), sustained across two evaluations 4+ elements apart;
  at the 2-block quantization floor (40+ WPM) timing is unfalsifiable
  so a 12× SNR corroboration is required; a rhythm-EMA watchdog revokes
  a confirmed channel that degenerates (speed changes revoke too, but
  held chars re-flush on re-confirmation — latency, not loss); held
  copy gets a relaxed last-chance check at un-bootstrap / flush so a
  lone "CQ" isn't swallowed. This is what keeps an idle *acoustic*
  channel (room impulses, level wander, tonal flutter) silent — the
  old SNR gates only handled stationary noise.

## App receive/TX extras

- Spectrum strip (300–1100 Hz, tap-to-tune) atop the Band Monitor;
  `SpectrumAnalyzer` also feeds an optional 2-channel skimmer
  (`settings.skimmerEnabled`) that decodes off-channel signals into the
  monitor. Live meters poll the decoder at 2.5 Hz.
- Morserino-32 BLE keyer (`Morserino/MorserinoKeyer.swift`, NUS +
  m32 protocol): when connected, `RadioController.transmit` routes text
  to `PUT cw/play/...` instead of the audio path; Settings → Keyer.
- Template messages (`QuickMessage`, Settings → Messages) with {CALL}
  {NAME} {QTH} {GRID} {THEIRCALL} placeholders fill the compose field;
  an empty compose field turns Send into repeat-last-sent.
- Active-QSO routing: keying to a counterparty (or a parsed "DE call")
  opens a 5-minute window during which substantial unparsed copy routes
  into that thread — mid-QSO overs drop the "DE" prefix. Junk-gated by
  `isSubstantialCopy` (≥4 chars, <70% E/I/S/H/5/T). ConversationView
  pins a live copy strip above the compose bar while decode is in
  progress.

## Deploy

- Device: `tools/install-device.sh` (iPhone connected, unlocked, trusted).
- TestFlight: `tools/upload-testflight.sh` (needs the App Store Connect app
  record for com.w2asm.dits + signed-in Xcode account).
