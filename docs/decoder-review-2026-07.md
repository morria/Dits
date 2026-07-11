# CW Decode Pipeline Review — Opportunities for Improvement

*July 2026. Covers the full receive path: `CWAudioController` → `CWModemService` → `AmateurDigitalCore` decoders (`CWDemodulator`, `BayesianCWDecoder`, `DualCWDecoder`) → `RadioController` segmentation, plus the `CWBenchmark` harness that defines the quality metric.*

Current standing: composite **97.03** for classic and dual (baselines 91.33 / 89.26). The pipeline is in good shape — the classic decoder is well-tuned, the audio plumbing is genuinely robust, and the benchmark is unusually thorough for a hobby-radio project. The opportunities below are ranked by expected impact on real-world copy quality.

---

## Tier 1 — Highest-impact fixes

### 1. Port the classic decoder's AFC fixes to the Bayesian decoder

The AFC capture bug documented in CLAUDE.md ("retunes away from a healthy signal… corrupted characters at every SNR") was fixed in `CWDemodulator` but **never ported to `BayesianCWDecoder`**, which is half of the shipped diversity decoder. Three specific gaps in `BayesianCWDecoder.updateAFC()` (BayesianCWDecoder.swift:748):

- **No healthy-signal veto.** Classic refuses to retune while `signalLevel > noiseLevel * 25` (CWDemodulator.swift:652). Bayesian will retune mid-copy whenever a neighboring bin wins a window — the exact bug class that cost classic points at every SNR.
- **No eager/locked margin split.** Classic acquires at 1.2× and demands 2.0× once locked; Bayesian uses one margin (`afcMinPowerRatio` ≈ 1.4) for both, so it acquires slower *and* retunes easier.
- **Wrong ordering.** Bayesian sets `afcInitialScanDone = true` *before* calling `updateAFC()` (BayesianCWDecoder.swift:363–366); classic deliberately runs the scan first, with a comment explaining why the order matters.
- Bonus: on a locked retune, classic flushes pending (valid) elements; Bayesian silently discards them.

The same pattern extends beyond AFC: classic's AGC-pumping fix (`thresholdFractionClean` 0.20 → **0.08**, the change that took that category 62 → 100) was also never mirrored — Bayesian still runs 0.290.

**Why this is #1 — measured today** (`swift run -c release CWBenchmark --bayesian-only`): Bayesian standalone composite is **91.6** vs classic's 97.03, and the losses sit exactly where the un-ported fixes predict: **agc_pumping 46.7**, **qrm 68.9**, **itu_channel 75.0** (jitter 89.5; even clean is 95.7). The shipped decoder is `DualCWDecoder`, and dual only beats classic when the Bayesian leg contributes — today dual merely *ties* classic (97.03), because a second opinion that's wrong ~8% of the time adds nothing to the vote. Porting a handful of already-proven fixes is small, mechanical work with a known payoff pattern.

### 2. The Bayesian decoder isn't Bayesian — make it real or simplify it

Two of its three headline mechanisms have no effect on output:

- **The tone-probability model is dead code.** `computeToneProbability()` → `smoothedToneProb` is computed every block (BayesianCWDecoder.swift:394–396) and **never read**. Actual tone detection is the same hard threshold as classic. The `toneSmoothing` and `tonePriorWeight` parameters tune a number nobody looks at.
- **The beam search is a disguised second threshold.** `updateBeam()` adds the *same* `ditLL`/`dahLL` to every hypothesis (BayesianCWDecoder.swift:640), so the top hypothesis is always the per-element argmax sequence — equivalent to classifying with a hard boundary at the Gaussian crossover (2.0 × dit) instead of `ditDahBoundary` (1.787 × dit). `beamWidth` and `pruneThreshold` cannot change the output. The only real effect is that `flushCharacter()` prefers the 2.0×-boundary reading when it forms a valid character.
- **Dead tuning knobs**: `signalTrackingRate` and `noiseTrackingRate` are settable, serialized, exposed to Optuna — and never read. Every Optuna run wastes budget exploring four no-op dimensions (these two plus the beam knobs).

Two honest paths:

- **(a) Make it real.** Wire `smoothedToneProb` into the state machine (soft on/off with hysteresis); make hypotheses diverge by giving each its own dit-length estimate (joint speed+sequence inference) and scoring *gaps* as well as marks; score completed characters against a ham-domain prior (see §6). This is the CW Skimmer recipe and is where a genuine step past fldigi-class decoding lives.
- **(b) Simplify.** Delete the dead machinery, keep it as "classic with different constants," and let the diversity value come from decorrelated tuning. Cheaper, honest, still useful — but it caps the ceiling.

Either is better than the current state, where the name promises probabilistic inference and the code delivers a second threshold.

### 3. Robust noise-floor estimation — fix the tune-in-mid-signal deafness

Both decoders estimate the noise floor by averaging the **first 200 ms unconditionally** (CWDemodulator.swift:312, `preambleBlocks` in Bayesian). If a tone is present during that window, the "noise" estimate is contaminated, the bootstrap threshold (8× noise) lands above the signal, and the decoder is deaf until enough idle silence decays the estimate (`0.95/0.05` EMA, only during sustained gaps).

This matters far more in the app than in the benchmark, because it's systematic there:

- **Every un-mute after TX resets the decoder** (`CWModemService.setMuted` → `reset()`), so the 200 ms re-estimation runs on post-TX audio — and in a messenger, the counterparty's reply routinely starts right then. The current design makes the app deafest at the exact moment copy matters most.
- Opening the app on an in-progress transmission (how band monitoring actually works) hits the same path.
- The benchmark never sees this: every scenario ships 100–300 ms of guaranteed silence up front (`runTest` uses `preambleMs: 300`), so the current 97.03 measures a case reality doesn't offer.

Fixes, cheapest first:

- **App-level:** on un-mute, restore the pre-TX noise/signal/speed state instead of cold-resetting (the floor measured 20 s ago is far better than one measured mid-reply). A `pauseForTransmit()`/`resumeAfterMute()` pair on the decoders that preserves `noiseLevel`, `signalLevel`, `ditBlocks`, and AFC frequency would do it.
- **Library-level:** minimum-statistics noise tracking (rolling minimum of block powers over ~1 s, standard in speech DSP) instead of a trusting preamble average. Works whether or not the tone is present at start, and keeps working through long transmissions.
- **Benchmark:** add a `cold_start_mid_signal` category so this stays fixed.

### 4. Sub-block timing resolution for 30+ WPM

All element/gap decisions are made in integer counts of a fixed block laid down at init (10 ms at the default 20 WPM config; `goertzelBlockSize` never adapts to the *tracked* speed). The arithmetic at speed:

| WPM | dit | dit in 10 ms blocks | ±1 block quantization error |
|----:|----:|----:|----:|
| 20 | 60 ms | 6.0 | 17 % |
| 30 | 40 ms | 4.0 | 25 % |
| 40 | 30 ms | 3.0 | 33 % |
| 45 | 26.7 ms | 2.7 | 37 % |

At 40+ WPM, quantization alone approaches the dit/dah discrimination margin before any channel impairment or fist jitter is added, and the noise-spike rejector (`max(2, dit/3)` blocks) starts eating real dits. The speed sweep tops out at 45 WPM and the app's `maxWPM` default is 45 — this is the binding constraint.

Options: measure tone edges on the FIR-filtered envelope at sample resolution (the 513-tap bandpass output is already there; a rectified+smoothed envelope with threshold crossing interpolation gives ~1 ms edges for free), or run overlapping Goertzel blocks (50–75 % hop). Element durations become floats; the state machine logic barely changes. This is the biggest pure-DSP quality lever left in the codebase.

---

## Tier 2 — Decode algorithm upgrades

### 5. Soft decisions and adaptive gap thresholds

- Element classification is a single hard cut (`duration <= 2×dit → dit`, CWDemodulator.swift:558). Keeping a confidence per element (distance from boundary) and per gap costs nothing and enables everything downstream (lexical rescoring, smarter dual merge).
- Gap thresholds are fixed multiples (2.0× dit inter-char, 5.0× word). Real fists compress inter-character gaps and stretch intra-character ones; fldigi/MRP40-style two-cluster tracking of observed gap durations (running histogram, threshold at the valley) adapts to the sender instead of the standard.
- Tone on/off uses one threshold both directions (`toneOn = p > T`, `toneOff = p < T`). Hysteresis (on at T, off at ~0.7 T) buys fading and chatter resilience without touching sensitivity — cheap, classic, currently absent.

### 6. A ham-domain prior (the "quality feel" win)

Nothing in the pipeline knows that `CQ`, `DE`, `599`, `73`, `TU`, `QTH`, callsign grammar, or RST reports exist. A lightweight rescoring layer — even bigram frequencies over ham corpus + a callsign-shape model applied when element/gap confidence is low — is how top decoders make weak-signal copy *read* dramatically better. It also directly serves the app's core routing requirement: `CallsignParser.counterparty` needs an exact `DE <call>`, so a single flipped element in the callsign silently orphans the message today. This pairs with §5 (needs confidences to know when to intervene) and fits naturally as the beam search's missing scoring function (§2a).

### 7. Smarter dual merge

`DualCWDecoder.flushMergeWindow()` matches only at the queue *heads*; one inserted character by either decoder desyncs the streams, and the whole expired region resolves winner-take-all by reliability EMA. Character-level alignment (edit distance within the 350 ms window) would recover the agreeing majority of a desynced region and only arbitrate the actual conflict. With per-character confidence from §5, disagreements become weighted votes instead of coin flips biased by history. Also worth noting: the two decoders AFC independently and can lock different frequencies; surfacing both (and cross-checking) is free diagnostic signal.

### 8. AFC refinement

- `GoertzelFilter` already has phase output (`processBlockComplex`, GoertzelFilter.swift:139) — **unused**. Phase-slope AFC gives sub-Hz tracking between the 25 Hz bins and lets you follow slow VFO drift *without* the current all-or-nothing choice between "never retune while healthy" (classic — loses a drifter that walks out of the ±100 Hz FIR passband) and "retune eagerly" (Bayesian — the capture bug). Small corrections below ~10 Hz don't even need a filter rebuild.
- AFC bins integrate rectangular (unwindowed) Goertzel over raw audio; sinc sidelobes mean a strong interferer 200 Hz away leaks into every bin. A window (or reusing `FFTProcessor` for the scan) hardens acquisition against QRM.
- The interference-cancellation stubs (`interfererPowerPerBlock`/`interfererLeakageFactor`, CWDemodulator.swift:127–129) are declared and reset but never used — finish the idea or delete it.

### 9. Prosigns are silently dropped

`prosignTable` exists (MorseCodec.swift:100) but is never inserted into the decode tree. Consequences: AR arrives as `+`, BT as `=`, KN as `(` (acceptable, conventional) — but **SK, CT, and SOS decode to nil and vanish**. For a QSO-driven messenger, the end-of-contact prosign disappearing from the copy is a real loss. Emit them as text (`<SK>`, `<CT>`) via prosign leaves in the tree. Any invalid element sequence is likewise dropped with no trace; consider an error glyph so the operator can see *where* copy was lost rather than reading falsely clean text.

---

## Tier 3 — App layer

### 10. Preserve decoder state across TX (pairs with §3)

`finishTransmit()` → `setMuted(false)` resumes a decoder that was reset when muting. Even with the library fix in §3, the app should keep the pre-TX noise floor, speed estimate, and AFC lock — the counterparty didn't move frequency or change fists during your over.

### 11. Live meters go stale between characters

`RadioController` updates `currentWPM`, `signalStrength`, and `detectedToneHz` only inside `handleCharacter` — the meters freeze whenever no characters decode, which is precisely when the operator looks at them ("am I getting anything?"). Poll the receiver at a few Hz for the meters (the values are already exposed on `CWReceiving`), independent of the character stream.

### 12. Tuning feedback — a spectrum strip

Copy quality currently depends on the operator landing the station within ±250 Hz of `toneHz`, blind. A small live spectrum/waterfall over 300–1100 Hz with a marker at the decoder frequency and tap-to-tune (feeding `tune(to:)`, which already exists) would eliminate the most common real-world failure mode — mistuning — and give the AFC an honest starting point. `FFTProcessor` covers the DSP.

### 13. Strategic: multi-signal decode (skimmer-lite)

The band monitor decodes one frequency. The architecture is ~already there for N: an FFT peak-picker (the `DecodeWAV` tool does exactly this pre-scan for RTTY/PSK) spawning a decoder per active tone. Even 3–4 concurrent channels would make the Band Monitor a real band monitor and would be a genuine differentiator on iOS — nothing shipping does CW Skimmer-style multi-channel on a phone. CPU headroom exists, especially after §17's decimation.

---

## Tier 4 — Benchmark & measurement

The benchmark defines "quality," so its blind spots become the product's blind spots.

### 14. A real off-air corpus

Everything is synthetic, and the decoders have now been through multiple Optuna rounds against this exact suite — classic overfitting territory (e.g. `thresholdFractionClean: 0.08` was tuned specifically to the synthetic `agc_pumping` scenario). WebSDR/KiwiSDR recordings of real QSOs with hand-transcribed ground truth, held out from optimization, as a scored category. Note `DecodeWAV` currently has **no CW mode** — adding one gives you both the corpus harness and a user-facing "decode a recording" feature.

### 15. Missing synthetic scenarios

- **QRN / impulse noise** (static crashes) — the most common summer-band impairment; entirely absent (white noise ≠ lightning).
- **Cold start mid-signal** — every current test guarantees ≥100 ms of clean preamble (see §3).
- **Slow continuous drift** (e.g. 1–5 Hz/s VFO walk) — distinct from the static offset tests; specifically stresses the classic AFC's never-retune-while-healthy rule.
- **Straight-key swing** — real fists have *systematic* bias (short dahs, compressed inter-element gaps), not the uniform ±jitter currently modeled; Farnsworth spacing likewise breaks the fixed 2×/5× gap multiples.
- **Other tone frequencies** — every test runs at 700 Hz; the app defaults to 600 Hz and allows 400–1000.
- **Long-duration false-positive rate** — 3 s of noise, scored once. The app listens for hours; measure junk chars/minute over several minutes instead.
- **Chunked-feed parity** — feed one scenario in 85 ms app-sized chunks vs one giant buffer and assert identical output (the sample-clock merge fix claims this; nothing verifies it).

### 16. Metric alignment with the product

CER treats all characters equally, but the app's routing lives or dies on the callsign field: one error in `DE K1ABC` orphans the whole message. Add a callsign-exact-copy rate over QSO-shaped scenarios as a first-class metric alongside CER. (Also: two benchmark helpers, `applyFrequencyShift` and `generateCWAtDifferentFrequency`, are dead code.)

---

## Tier 5 — Hygiene and performance

- **Dead code to remove or finish**: interference-cancellation stubs (§8), `smoothedToneProb` + dead knobs (§2), `toneActive` (set, never read, both decoders), the per-instance `morseCodec` member (decode uses the static API), and the fresh center-frequency `GoertzelFilter` constructed *every block* for AFC (CWDemodulator.swift:276, BayesianCWDecoder.swift:349).
- **CPU/battery**: the dual decoder runs two independent 513-tap overlap-add FIRs and 2 × 21 Goertzel bins at 48 kHz. Fine on an A-series core, but a 48 → 12 kHz decimation front end (the library's `Decimator` is unused by the CW path) would cut DSP work ~4× and shrink the FIR proportionally — relevant for §13 and for hours-long monitor sessions on battery. The two sub-decoders could also share one bandpass/decimator stage since they run identical front-end filters at the same frequency.
- `CWModemService.wire` reads `self.receiver.*` inside the character callback; after a settings rebuild swaps `receiver`, a late callback from the old decoder reports the new decoder's WPM/tone. Harmless today; one-line fix (capture the receiver) whenever nearby code is touched.

---

## Suggested sequencing

| Order | Item | Effort | Expected payoff |
|---|---|---|---|
| 1 | §1 port AFC + threshold fixes to Bayesian | Small | Bayesian 91.6 → ~classic parity; dual finally exceeds 97.03; QRM/AGC copy in app |
| 2 | §3 + §10 noise floor + TX state carry-over | Small–medium | Fixes the app's single most user-visible decode failure (deaf after TX / on open) |
| 3 | §15 benchmark scenarios (esp. cold-start, QRN, drift) | Small | Makes 1–2 measurable; guards regressions |
| 4 | §4 sub-block timing | Medium | Unlocks reliable 35–50 WPM; helps every jitter/speed category |
| 5 | §5 + §7 soft decisions + aligned merge | Medium | Compounding accuracy in marginal copy |
| 6 | §6 + §2a ham prior + real Bayesian scoring | Large | The step past fldigi-class decoding; biggest ceiling raise |
| 7 | §12 → §13 spectrum strip → skimmer-lite | Medium → Large | Real-world usability now; category differentiation later |

The through-line: the classic decoder is near its structural ceiling (97 on a synthetic suite that flatters it), and the remaining headroom is in (a) making the second diversity leg pull its weight, (b) surviving the app's actual operating conditions — mid-signal starts and post-TX resumes — and (c) moving from hard thresholds to soft decisions with a domain prior.

---

## Outcome (2026-07-03)

Every item above is implemented and benchmark-verified, including §4 (sub-block timing: quarter-block Goertzel edge refinement with neutral-fraction fallback that reproduces legacy behavior bit-for-bit when SNR is poor).

Scores on **suite v2** (adds cold_start, qrn, drift, swing, farnsworth, tone_freq, chunked_parity, callsign_copy, speed_jitter, 30 s false-positive rate; *not comparable to the old 97.03*):

| Decoder | v2 at review time | v2 after this pass |
|---|---|---|
| Classic | ~93.0 | **97.2** |
| Bayesian | ~92.3 (91.6 on v1) | **97.2** |
| Dual (shipped) | ~93.0 | **97.1** |

Highlights: drift 87→100 (phase-slope fine AFC), QRN 73→96–98 (noise blanker), farnsworth 60→93 (adaptive gap clustering; the residual error is the causally-unknowable first gap), swing 69→100, 30–40 WPM hand-sent jitter 100 across the board (sub-block timing), cold start 97.4 (min-statistics floor + resynchronize-after-TX), 30 s idle-band junk reduced from continuous E/T chatter to zero/near-zero via a two-block bootstrap requirement and an SNR-gated emission path. A real-audio corpus harness now exists (`CWBenchmark --corpus <dir>`, `DecodeWAV --mode cw`) — recordings with sidecar transcripts are scored out-of-composite as the overfitting check; the next step is collecting off-air WebSDR captures.
