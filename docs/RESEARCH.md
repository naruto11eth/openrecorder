# OpenRecorder — Prior-Art & Library Research (condensed)

Condensed from a multi-lane research sweep (open-source prior art, macOS capture
APIs, meeting detection, STT/diarization, architecture + legal). Kept here so the
next session doesn't re-derive the landscape.

## Key conclusion
No existing OSS or commercial **botless** tool combines all of: auto-detect
Meet+Slack, window **video** capture, live diarized transcript, and an offline
reconciliation pass. Almost every notetaker (Granola, Otter, Fathom, Krisp,
Notion AI) is audio-only. Fireflies Desktop (Nov 2025) is the only botless tool
with screen video, and it's paywalled. → video + two-pass reconciliation is open
territory.

## Open-source references worth reading
- **meetink** (MIT) — closest architecture: ScreenCaptureKit sysaudio + mic +
  whisper.cpp + sherpa-onnx diarization; 3-signal meeting detection.
- **Recap** (MIT) — cleanest driver-free system audio via Core Audio taps.
- **Hyprnote / Anarlog** (MIT, very active) — calendar detection, markdown-per-
  meeting output format (borrowed our output shape from here).
- **screenpipe** (source-available) — most complete architecture; study only.
- **Recall.ai OSS Meet bot** / **Vexa** — caption-DOM scraping for speaker names.
- **WhisperX** — the canonical offline diarize+align pipeline (our verify pass
  is a lighter-weight version of this idea).

## macOS capture API decisions
- **Video + system audio:** ScreenCaptureKit. `SCContentFilter(desktopIndependent
  Window:)` follows the window across monitors — no frame polling needed.
- **Mic + system audio sync:** separate `AVAssetWriterInput`s; anchor the writer
  session to the first video frame; use each buffer's PTS (don't manually offset).
- **Crash safety:** `movieFragmentInterval = 10s` (without it, a crash loses the
  whole file — only the moov atom at `finishWriting` makes it readable otherwise).
- **Resolution:** cap at 4096×2304 (H.264 `AVAssetWriter` crashes above this on
  5K/6K displays).
- **Per-process audio (future):** Core Audio process taps (`CATapDescription`,
  macOS 14.4+), `muteBehavior = CATapUnmuted` so the call still plays normally.
  Strictly better than BlackHole/virtual drivers and more precise than SCK app-
  level audio (which captures the whole browser).
- **TCC:** ship a signed `.app` bundle (Tahoe broke bare executables); Info.plist
  needs `NSScreenCaptureUsageDescription`, `NSMicrophoneUsageDescription`, and
  `NSAudioCaptureUsageDescription` (the last is NOT in Xcode's dropdown).

## Detection decisions
- 3 signals: calendar pre-trigger (EventKit, future) → process scan (NSWorkspace)
  → window-title scan (CGWindowList, needs Screen Recording perm for titles).
- **Meet:** match `meet.google.com` / "Google Meet" in browser window titles.
  A Chrome extension content script is the instant, zero-poll signal (future).
- **Slack huddle:** huddle windows are inconsistent in window enumeration across
  Slack versions. Use title="Huddle" best-effort + manual hotkey. **Do NOT** use
  mic-in-use as a signal — our own recording holds the mic and self-triggers
  (this caused the auto-stop bug; see HANDOFF §3).

## STT / diarization decisions (2025–2026 landscape)
- **Live:** WhisperKit (Argmax, CoreML/ANE) — ~2.2% WER, ~0.45s latency on
  Apple Silicon, fully on-device. We use `base.en` for speed; `large-v3-turbo`
  available.
- **Offline:** WhisperKit `large-v3-turbo` locally; ElevenLabs Scribe v2 is the
  cloud accuracy leader (2.3% WER) if a cloud opt-in is ever added.
- **Diarization:** Argmax SpeakerKit is **post-hoc only** in the OSS tier
  (streaming is paywalled). **FluidAudio** (Apache-2.0) does on-device streaming
  diarization — the pick when we add multi-speaker "Them" splitting.
- **Real names:** diarization never yields names. Only reliable botless path for
  Meet is scraping the caption DOM (names live there) via a Chrome extension.

## Legal
California CIPA = all-party consent; the Jan 2025 AG advisory extends it to AI
recorders; local recording is **not** a defense. SB 690 (would add a commercial
carve-out) had **not** passed as of mid-2026. → keep the consent gate on by
default, disclosure before recording, logged. Design consent as a pluggable
module so it can relax if the law changes.
