# Dits Usability Plan — Novice CW Operators, iOS-Native

*2026-07-03. A critical pass over every screen from a designer / user-researcher lens. The reference persona is a newly licensed ham: knows some Morse, owns a Morserino or a small rig, doesn't yet know QSO conventions, and is nervous about transmitting wrongly. The bar: feel like an Apple-built app that happens to speak CW.*

Already fixed in this pass (they were reported/blocking): Stop now actually stops — an explicit Stop survives app foregrounding, and in-flight decoder characters are dropped instead of trickling into the monitor; Morserino pairing is one tap (open the screen, it connects to the only device in range) and re-pairing is zero taps (quiet reconnect to the remembered device on foreground, never against an explicit Disconnect).

---

## What works and should not be touched

The Messages metaphor over a CW band is the product's big idea and it lands: conversation list, bubbles with tails and grouped timestamps, compose bar, honest delivery states. The status strip under the nav bar is a legitimate pattern (Voice Memos does the same for live state). Monospaced copy text is the right call — CW operators read character-by-character. Keep all of it.

---

## P0 — High-impact, low-effort (do first)

**1. Failed messages have no retry.** A red "Not Sent" bubble offers only Copy in its context menu. The single most common recovery action doesn't exist. Add **Resend** to the context menu of any outgoing message and a tap-to-retry affordance directly on failed bubbles ("Not Sent · Tap to retry" — Messages does exactly this).

**2. "Match their speed."** The app *knows* the sender's speed (`currentWPM`) and the novice doesn't know the convention (answer at the speed you were called). When the decoded speed differs from the TX setting by more than ~3 WPM, show a small chip in the compose bar: *"Reply at 22 WPM"* — one tap sets `settings.wpm`. This single control encodes operating etiquette a novice would otherwise learn by being ignored on the air.

**3. Empty states should act, not instruct.** "Tap the pencil to call CQ" makes the user find an icon. Put a **Call CQ** button in the empty conversation list, and a **Start Listening** button in the monitor's empty state when stopped. (HIG: empty states are onboarding surfaces; the primary action belongs in them.)

**4. Remove the duplicate Band Monitor entry point.** It's both a pinned home-row *and* a toolbar icon. The pinned row (with its live preview line) is the better one; drop the toolbar button. One concept, one place.

**5. Template editor: adding should edit.** "Add Template" appends a row named "New" and leaves the user to find it. Navigate straight into the new template's edit form with the label field focused.

**6. Rename "Sent" honestly.** CW has no delivery receipt; "Sent" nudges novices toward an iMessage expectation the medium can't honor. Caption outgoing success as **"Sent on air"** (first message per group), and say this plainly once in onboarding: *"Everything you key is heard by everyone on frequency — replies appear when the other station answers."*

**7. Stop button color.** Stop-listening is rendered `tint(.red)` like a destructive action. It isn't — it's Pause semantics. Use the neutral accent; reserve red for the transmit-abort Stop, which genuinely interrupts something on the air.

---

## P1 — The novice arc (next block of work)

**8. Onboarding doesn't know Morserino exists.** The first screen commits to "wire up your radio with a USB-C audio interface," but a large share of the target audience owns a Morserino. Rework the welcome into a two-path choice — *"How will you connect?"* → **Radio via audio cable** / **Morserino over Bluetooth** — and land each path in its own ready-check (below). Keep Skip.

**9. A setup ready-check moment.** The #1 novice support question will be "it decodes nothing." Add a check step after onboarding (and reachable from Settings): a large live input meter plus the spectrum strip, with three states in plain language — *"No audio coming in — check the cable/interface"*, *"Audio, but no CW tone found"*, *"Copying: …"* with live decoded text. For the Morserino path: connection status plus a **Send test** that keys "TEST" and confirms the echo.

**10. Surface tuning where the user actually waits.** The spectrum strip lives only in Band Monitor, but a novice sits in a conversation wondering why nothing arrives. When listening in a conversation with no signal detected for ~10 s, show a quiet inline hint above the compose bar: *"No CW tone near 600 Hz — open Band Monitor to tune"* (tappable). Consider showing the detected-tone chip (`600 Hz ▸ 640 Hz`) as a tap-to-retune affordance in the status strip.

**11. Pre-send audio preview.** Key fright is real. A long-press on Send (or a small speaker icon beside the on-air estimate) plays the message as sidetone locally without transmitting. The estimate line already proves the timing math exists; let them *hear* it. (Skip when Morserino-connected, or route preview to the Morserino speaker via `PUT cw/play` with TX disabled — needs a check of device semantics.)

**12. Actionable errors.** The status strip's error line ("Check the microphone permission…") is honest but dead-ended. Make error states tappable: microphone permission → deep-link to the app's Settings page; audio interface gone → open the ready-check screen (#9).

**13. Advanced settings split.** Min/max tracked WPM and decoder choice are expert knobs sitting at the same level as Speed and Tone. Move them under an **Advanced** disclosure group. Default decoder is already right; a novice should never have to see "Bayesian."

**14. Accessibility pass.** SignalBars and LevelMeter are purely visual — add `accessibilityLabel`/`accessibilityValue` ("Signal strength 4 of 5"). Audit Dynamic Type at XL sizes: the status strip's two-line layout and the compose bar's overlaid send button are the likely breakpoints. The spectrum strip already has a label; add an `accessibilityValue` announcing the strongest tone frequency.

---

## P2 — Differentiators for learners (worth prototyping)

**15. Guided QSO.** The template chips already encode the standard exchange (CQ → Reply → RST → Name → QTH → 73). Sequence them: after the counterparty's RST arrives, float the RST chip first with a subtle highlight; after names are exchanged, suggest QTH; after a 73, suggest 73/SK. It's a script prompter, not automation — the user always taps. This converts the app from a tool into a teacher, and no competitor has it.

**16. Plain-English annotations.** Long-press (or a toggle) on any received bubble shows a translated line: "UR RST 599 = your signal report is excellent · 73 = best regards · SK = end of contact." A small static dictionary of ~50 abbreviations covers 95% of real traffic. Pairs with a searchable glossary screen linked from Settings.

**17. Listening confidence meter.** Novices can't judge conditions. A one-word qualifier derived from existing signal metrics — *"Strong copy" / "Workable" / "Weak — expect gaps"* — under the WPM readout in the status strip, in plain language rather than S-units.

---

## Explicitly considered and rejected

- **Confirmation before repeat-send on empty field** — the icon change to `repeat.circle.fill` is sufficient signaling, and repeating CQ rapidly is the core workflow the feature exists for; a confirm would break it.
- **Auto-TX anything** (auto-answer, auto-73) — a licensed operator must stay in the loop on every transmission; guided QSO (#15) deliberately stops at *suggesting*.
- **Replacing the status strip with iOS Live Activities** — attractive later for lock-screen monitoring, but it's additive, not a substitute; out of scope until the in-app loop is polished.

## Suggested order

P0 items are each under an hour and land together as one "polish" build. P1 #8–9 (onboarding + ready-check) are the largest single block and the highest-leverage for the novice persona — schedule as their own build. P1 #10–14 fit alongside. Prototype P2 #15 behind a Settings toggle first; validate with two or three real novice sessions (watch them work a first QSO; count where they hesitate) before committing to it as default UX.
