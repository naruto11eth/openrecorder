# OpenRecorder — Handoff Notes

> Read this first if you're a Claude instance (or human) picking this up. It
> captures everything that isn't obvious from the code: why decisions were
> made, what's been tested on real hardware, what broke, and what to do next.

Last updated: 2026-06-15, after the first real Google Meet test on the author's
work machine. The author will continue testing on a **personal laptop**, so the
TCC/permission state described here does **not** carry over — expect to grant
Screen Recording + Microphone fresh on that machine.

---

## 1. What this is

A local-first macOS meeting recorder. It auto-detects a Google Meet (browser)
or Slack huddle, records the **call window as video** plus system audio + mic,
live-transcribes both sides on-device with WhisperKit, then runs a **post-meeting
verification pass** that re-transcribes the saved audio with a bigger model and
diffs it against the live transcript.

The differentiator vs Granola/Otter/etc: **records the screen/video of the call**
(not audio-only) and does a **two-pass transcript reconciliation**. No bot joins
the call; everything stays on the machine.

Requirements established with the user (verbatim intent):
1. Auto-start when joining a Google Meet or Slack huddle.
2. Auto-select the window/monitor where the call is.
3. Transcribe all participants + their names (best STT).
4. Auto-record the window/monitor for a visual of the call.
5. Save video + transcript to a folder automatically.
6. Final verification pass: recorded audio re-transcribed and reconciled against
   the realtime transcript.

---

## 2. Current status (honest)

| Requirement | Status | Notes |
|---|---|---|
| 1. Auto-start | ✅ Works (Meet) / ⚠️ best-effort (Slack) | Meet detection verified firing on a real call. Slack huddle needs a real "Huddle" window title — unverified on hardware. |
| 2. Window/monitor select | ✅ Works | `desktopIndependentWindow` filter; verified recording the Meet window at 4096×2304. |
| 3. Transcribe + names | ⚠️ Partial | STT works; **names are channel-based only** ("Me"=mic, "Them"=system audio). Real per-participant names NOT done yet (see §6). |
| 4. Record window video | ✅ Works | Verified 88MB `.mov` produced from a ~7min call. |
| 5. Save to folder | ✅ Works | Per-meeting folder created with video + WAV lanes + live transcript JSON. |
| 6. Verification pass | 🔲 Untested end-to-end | Code is written but never reached on hardware because the first test's auto-stop bug (now fixed) meant `stopRecording()` never ran. **This is the #1 thing to verify next.** |

**Bottom line:** capture + detection + live transcription are proven on real
hardware. The stop→verify→markdown back half is written but has not yet executed
on a real recording. Top priority for the next session.

---

## 3. What happened in the first real test (2026-06-15)

The user joined and left a real Google Meet. Findings:

1. ✅ Detection fired: `Meeting detected: google-meet — Google Meet`.
2. ✅ Consent dialog shown + accepted, logged to `consent-log.json`.
3. ✅ Capture started at 4096×2304, wrote `recording.mov` (grew to 88MB),
   `mic.wav`, `system.wav` (6.6MB each), `transcript_live.json`.
4. ❌ **Bug A — recording never stopped.** After leaving, the recording kept
   growing forever. `stopRecording()` (which finalizes the file + runs the
   verification pass) was never called.
5. ❌ **Bug B — transcript was all hallucinated noise.** Every segment was
   `(wind blowing)`, `[BLANK_AUDIO]`, `(crowd murmuring)`, all on the `me`
   lane. The call was effectively silent (solo test, no one talking), and
   Whisper hallucinates non-speech tags on near-silence.

### Bug A root cause + fix (committed)
The Slack-huddle detector used "is the default input device active?" as a
fallback signal. But **OpenRecorder's own recording holds the mic open**, and
Slack was running in the background — so every 2s poll saw "Slack + mic active"
and invented a phantom huddle, flipping `current` and resetting the
miss-counter. The meeting was therefore never seen as "ended".

Fix in `MeetingDetector.swift`: removed the mic-in-use fallback entirely. Slack
detection now requires a literal "Huddle" in the window title (per the research:
huddle detection should be "best-effort + manual override"). Added a per-poll
log line `Meeting window gone (N/5)` so the end-countdown is observable.

### Bug B root cause + fix (committed)
Whisper emits ambient sound as bracketed/parenthesized annotations. Fix in
`TranscriptionEngine.meaningfulText()`: drop any segment whose entire content is
a bracketed annotation (strip `[...]`, `(...)`, stray brackets — if nothing
real remains, it's noise). Also raised the RMS energy gate (0.005→0.01) and pass
explicit anti-hallucination `DecodingOptions` (suppressBlank, compressionRatio
2.0, noSpeechThreshold 0.6). The same filter is used by the verification pass.

**Neither fix has been re-tested on hardware yet** — the second test never ran
because of the signing/permission issue below.

---

## 4. The signing / TCC permission trap (important for iteration)

macOS TCC (Screen Recording, Microphone) keys permission to the app's code
signature. **Ad-hoc signing changes the code hash on every build**, so each
rebuild looked like a brand-new unauthorized app and forced a fresh Screen
Recording grant. Worse: toggling Screen Recording permission **kills the running
app** (standard macOS behavior), so the "auto-continue after grant" flow can't
survive the very first grant — the process is terminated by the OS.

Fix: a **stable self-signed code-signing identity** ("OpenRecorder Dev").
- Create it once per machine: `./make-signing-cert.sh`
- `make-app.sh` auto-uses it if present, else falls back to ad-hoc.
- Gotcha solved: OpenSSL 3.x PKCS12 export uses a MAC algorithm macOS `security`
  can't import ("MAC verification failed"). The script uses legacy
  `-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1`.

⚠️ **As of this handoff, `make-app.sh` signing with the identity still emitted
`errSecInternalComponent` and fell back to/produced an adhoc CodeDirectory** (see
last terminal output: `flags=0x20002(adhoc,linker-signed)`). This was being
debugged when the session ended. **The signing identity is created and valid for
`codesign` listing, but the actual `codesign --sign "OpenRecorder Dev"` on the
bundle did not cleanly apply.** Likely causes to investigate:
  - The login keychain may be locked during signing → `security unlock-keychain`.
  - `--deep` signing the bundle with a self-signed cert + the SwiftPM
    `linker-signed` main binary may conflict; try signing without `--deep`, or
    sign the inner Mach-O explicitly first.
  - May need `codesign ... --keychain ~/Library/Keychains/login.keychain-db`.

On the user's **personal laptop**, the simplest path to test NOW is:
  1. `./make-signing-cert.sh` (optional but recommended).
  2. `./make-app.sh` — if it prints "signed ad-hoc", that's fine for a single
     test; you'll just re-grant Screen Recording once.
  3. `open OpenRecorder.app`, grant **Screen Recording** (the app gets killed by
     macOS — relaunch with `open OpenRecorder.app`), grant **Microphone**.
  4. Join a Meet, **talk**, leave, confirm auto-stop + verification.

---

## 5. Architecture / file map

```
Package.swift              swift-tools 6.0, macOS 15+, depends on WhisperKit 0.18
make-app.sh                build → OpenRecorder.app → codesign
make-signing-cert.sh       one-time stable signing identity
Resources/Info.plist       LSUIElement (menu-bar app), TCC usage strings
Sources/OpenRecorder/
  main.swift               NSApplication + menu-bar UI (NSStatusItem)
  AppController.swift       @MainActor orchestrator: detect→consent→capture→STT→verify
  MeetingDetector.swift     3-signal detection (process / window title / [mic removed])
  CaptureEngine.swift       SCStream → AVAssetWriter (video+sysaudio+mic), audio lane tee
  AudioLane.swift           per-lane 16kHz WAV writer + chunk emitter; Log helper
  TranscriptionEngine.swift WhisperKit live STT (actor), meaningfulText() noise filter
  VerificationPass.swift    offline re-transcribe + reconcile + report
  MeetingStore.swift        per-meeting folder layout + markdown writer
  ConsentGate.swift         CIPA consent dialog + consent-log.json
  Permissions.swift         Screen Recording + Microphone TCC helpers
  Transcript.swift          Codable models (segments, lanes, verification report)
docs/
  HANDOFF.md               this file
  PLAN.md                  roadmap / phased plan
  RESEARCH.md              condensed findings from the prior-art research sweep
```

### Data flow
`MeetingDetector` (2s poll) → `AppController.handleMeetingStarted` →
`ConsentGate` → `CaptureEngine.start` (one `SCStream`, filter =
`desktopIndependentWindow`). Audio arrives on the SCStream delegate: system
audio + mic each tee into an `AudioLaneProcessor` that (a) writes a 16kHz mono
WAV and (b) emits 12s chunks to `TranscriptionEngine` (an actor) for live STT.
Video + both audio tracks are muxed into a fragmented `.mov` via `AVAssetWriter`
(10s `movieFragmentInterval` for crash safety). On meeting end (5 consecutive
"window gone" polls), `stopRecording()` finalizes the file, then a detached Task
runs `VerificationPass` (WhisperKit `large-v3-turbo`) and rewrites `meeting.md`.

### Output folder (`~/Documents/OpenRecorder/<ISO>_<source>/`)
```
recording.mov          window video + system audio + mic (fragmented)
mic.wav  system.wav    16kHz mono lanes (verification input)
transcript_live.json   realtime pass (base.en)
transcript_final.json  offline pass (large-v3-turbo)  [only after verify]
verification.json       live-vs-offline discrepancy report [only after verify]
meeting.md             readable notes (rewritten by verify pass)
```
Plus `~/Documents/OpenRecorder/consent-log.json` (append-only consent record).

---

## 6. Known limitations / gotchas

- **Speaker names are channel-based only.** "Me" = your mic, "Them" = the call
  app's system audio. Multiple remote participants all collapse to "Them". Real
  names need the Meet caption-DOM scrape (see PLAN §"Real participant names").
- **WAV finalization on hard-kill.** `AVAudioFile` writes its header length on
  dealloc. If the app is `kill -9`'d mid-recording, the WAVs report 0 duration
  (data is present but the header is stale). The clean stop path finalizes them
  correctly. Consider periodic header flush for crash resilience.
- **System-audio lane captures the whole call app**, not just the Meet tab. If
  you have music playing in another Chrome tab, it lands on the "Them" lane.
  Per-process Core Audio taps (macOS 14.4+) would fix this — see PLAN.
- **"You left the meeting" screen.** If the user leaves but leaves the Meet tab
  open, its title may still contain "Google Meet", so auto-stop won't fire until
  the tab is closed/navigated. Closing the tab or using menu "Stop Recording"
  works. Consider detecting the post-call URL state.
- **Energy gate may drop very quiet speech.** RMS threshold 0.01 was tuned
  against a silent call; validate against real speech and lower if it clips
  quiet talkers.
- **macOS 15+ re-confirms Screen Recording monthly** (OS behavior, not a bug).
- **First Screen Recording grant kills the app** (OS behavior). Relaunch.

---

## 7. What to do next (priority order)

1. **Re-test the full lifecycle on the personal laptop with people actually
   talking.** Confirm: auto-stop fires within ~10s of leaving; `recording.mov`
   is playable; `transcript_final.json` + `verification.json` + the rewritten
   `meeting.md` are produced; live transcript has real words on both lanes.
2. **Resolve the `errSecInternalComponent` signing issue** (§4) so permissions
   persist across rebuilds. Until then, expect to re-grant Screen Recording each
   rebuild.
3. **Validate `recording.mov`** opens in QuickTime with video + audio in sync.
4. **Real participant names** (biggest product gap). Recommended: a companion
   Chrome MV3 extension that scrapes Meet's caption DOM (speaker labels live in
   the DOM) and sends names+timestamps to the app via native messaging or a
   localhost socket; reconcile onto the diarized timeline in the verify pass.
5. **Per-process audio** via Core Audio process taps (isolate the Meet tab).
6. **On-device diarization** (FluidAudio / SpeakerKit) to split multiple remote
   speakers within the "Them" lane.
7. **Calendar pre-trigger** (EventKit) to pre-populate attendee names + warn
   before scheduled meetings.
8. **LLM summary** section appended to `meeting.md`.

See `docs/PLAN.md` for the phased breakdown and `docs/RESEARCH.md` for the
prior-art / library decisions behind these.

---

## 8. How to build & run (quick reference)

```bash
./make-signing-cert.sh        # once per machine (optional, recommended)
./make-app.sh                 # build + bundle + sign  → OpenRecorder.app
open OpenRecorder.app         # launch (menu-bar app, look for record.circle icon)
tail -f /tmp/openrecorder.log # live logs (app writes here regardless of launch)
```
First launch downloads `base.en` (~150MB) live model; first verification pass
downloads `large-v3-turbo` (~1.6GB) — both from HuggingFace, cached after.

Debugging tip: the app writes all logs to `/tmp/openrecorder.log` (see the `Log`
enum in `AudioLane.swift`), so you can `tail -f` it even when launched via
`open` (which detaches stderr).
