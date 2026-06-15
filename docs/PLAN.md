# OpenRecorder — Plan & Roadmap

## Vision

A local-first macOS meeting recorder that beats Granola/Otter on two axes:
**records the call window as video** (including shared screens) and runs a
**two-pass transcript** (fast live pass + high-accuracy offline pass that
verifies and corrects the live one). No bot joins the call; nothing leaves the
machine.

## Phase status

### Phase 1 — Capture core ✅ (done, verified on hardware)
- [x] ScreenCaptureKit window video via `desktopIndependentWindow` filter
- [x] System audio + microphone capture on one `SCStream`
- [x] Fragmented `.mov` writer (crash-safe, 10s fragments)
- [x] 16kHz mono WAV lane files for the offline pass
- [x] 4096×2304 resolution cap (H.264 writer limit)
- [x] Per-meeting folder layout + markdown output

### Phase 2 — Detection + consent ✅ (Meet verified, Slack best-effort)
- [x] 3-signal detection: process scan + window-title scan (+ mic signal removed
      after it caused a self-trigger bug — see HANDOFF §3)
- [x] Auto-stop on meeting end (5-poll debounce) — fixed, **re-test pending**
- [x] CIPA consent gate + append-only consent log
- [ ] Slack huddle detection validated on hardware (currently title-only)
- [ ] Handle "you left the meeting" tab-still-open state

### Phase 3 — Transcription ✅ live / 🔲 verify untested
- [x] WhisperKit live STT (`base.en`), 12s chunks, channel-based Me/Them lanes
- [x] Non-speech hallucination filter (`meaningfulText`) — **re-test pending**
- [x] Offline verification pass (`large-v3-turbo`) + reconciliation report
- [ ] Verify pass executed end-to-end on a real recording (TOP PRIORITY)
- [ ] Tune energy gate against real speech (currently 0.01 RMS)

### Phase 4 — Real participant names 🔲 (biggest product gap)
- [ ] Chrome MV3 extension: scrape Meet caption DOM for speaker labels
- [ ] Native-messaging or localhost bridge from extension → app
- [ ] Reconcile DOM speaker names onto diarized segments in the verify pass
- [ ] Versioned CSS-selector table (Meet obfuscates class names; expect churn)
- [ ] Fallback: post-call "who was Speaker N?" rename UI

### Phase 5 — Audio precision + diarization 🔲
- [ ] Per-process Core Audio taps (macOS 14.4+) to isolate the Meet tab's audio
      from the rest of the browser (`CATapDescription`, `muteBehavior=CATapUnmuted`)
- [ ] On-device diarization (FluidAudio Apache-2.0 streaming, or SpeakerKit
      post-hoc) to split multiple remote speakers within the "Them" lane

### Phase 6 — Polish 🔲
- [ ] EventKit calendar pre-trigger + attendee pre-population
- [ ] LLM summary section in `meeting.md` (local model or BYO key)
- [ ] Resolve stable code-signing so TCC persists across rebuilds (HANDOFF §4)
- [ ] Onboarding flow for permissions
- [ ] Recording indicator / visible "REC" affordance (also a consent nicety)

## Design decisions (and why)

- **Native Swift, not Electron/Tauri.** All capture APIs (ScreenCaptureKit,
  AVFoundation, Core Audio taps) are native; a wrapper adds friction with no
  benefit for a capture-heavy app. WhisperKit is a native Swift package.
- **WhisperKit over whisper.cpp.** CoreML/Neural Engine, lower latency on Apple
  Silicon, App Store compatible, clean Swift API. (Research: 2.2% WER, ~0.45s
  latency for the realtime path.)
- **Two-pass, not single-pass.** Live pass = low-latency `base.en` for instant
  notes; offline pass = `large-v3-turbo` for accuracy. Reconciliation flags
  where live was wrong. No shipping consumer product does this — it's the moat.
- **Channel-based speakers first, real names later.** "Me"=mic, "Them"=system
  audio is free and correct for 1:1s (same as Granola desktop). Real names are a
  separate, harder workstream (Phase 4).
- **Consent gate on by default.** California is all-party consent; local
  recording is not a legal defense. Off-by-default auto-record + a logged
  disclosure prompt is the minimum responsible posture.

## Non-goals (for now)
- Windows/Linux (macOS-only; deeply tied to ScreenCaptureKit/CoreAudio).
- Joining calls as a bot (the whole point is botless local capture).
- Cloud transcription (privacy-first; offer as opt-in later if accuracy demands).
