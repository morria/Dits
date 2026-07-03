# Dits — CW for iPhone

The easiest way to work CW (Morse code) from your iPhone. Plug your phone
into your radio with a wired audio interface, and Dits copies incoming
Morse into clean text and keys out perfectly timed CW from anything you
type — with a Messages-style chat for every station you work.

## Highlights

- **Live band monitor** — everything you copy, as it arrives, with speed,
  tone, and signal strength.
- **Conversations by callsign** — directed QSOs are grouped into threads,
  just like Messages. Junk from band noise never spawns a thread (routing
  requires real "DE \<call\>" structure).
- **Type-to-send + macros** — one-tap CQ / DE / 73 / RST / prosigns; Dits
  keys them out as shaped, click-free CW with sidetone.
- **Three decoders** — Classic (Goertzel state machine), Bayesian, and a
  Diversity decoder that fuses both for the best copy.
- **Native and polished** — NavigationStack, Messages-style bubbles,
  haptics, Dynamic Type, dark mode, `ContentUnavailableView` empty states.

## Architecture

```
RadioController (@MainActor store)
  ├─ CWAudioController   AVAudioEngine, .measurement mode
  │     input tap → mono 48 kHz Float ─┐
  │     AVAudioPlayerNode ← keyed TX   │
  ├─ CWModemService  ─────────────────┘  DSP queue
  │     Classic / Bayesian / Diversity decoder  (AmateurDigitalCore)
  │     char stream → main → conversations + monitor
  └─ Persistence (UserDefaults JSON)
```

The CW modem itself is the `AmateurDigitalCore` Swift package, referenced
locally from the sibling `../Amateur-Digital` checkout. The TX→RX
roundtrip is covered by an XCTest that runs the real modulator and
demodulator over synthetic audio.

## Building

```sh
cd app && xcodegen generate
xcodebuild -project Dits.xcodeproj -scheme Dits \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project Dits.xcodeproj -scheme Dits \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

## Radio setup

1. Connect a wired audio interface (USB-C or Lightning) between the iPhone
   and the radio's data port.
2. Set your callsign (and optionally grid) in Settings.
3. Tune to a CW frequency, press **Listen**, and copy the band.
4. Set the transmit level so the radio shows little or no ALC; key with VOX
   or a CAT/PTT interface.

## Deploying

- **To your device:** `tools/install-device.sh` (iPhone plugged in,
  unlocked, trusting this Mac).
- **To TestFlight:** create the App Store Connect app record for
  `com.w2asm.dits`, then `tools/upload-testflight.sh`.

## License / credits

Decoding and keying are powered by **AmateurDigitalCore**. Bundle id
`com.w2asm.dits`, team `7Q2SS8772K`.
