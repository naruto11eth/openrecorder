# OpenRecorder

Local-first meeting recorder for macOS. Auto-detects Google Meet and Slack
huddles, records the **call window as video** (including shared screens),
live-transcribes both sides of the call fully on-device, then runs a
post-meeting verification pass that re-transcribes the recording with a larger
model and reports where the live transcript was wrong.

Everything stays on your machine. No bots join your calls, no audio leaves
your laptop.

## How it works

```
MeetingDetector ──▶ ConsentGate ──▶ CaptureEngine (ScreenCaptureKit)
  2s poll:                            │
  • process scan                      ├─ recording.mov   (window video + system audio + mic,
  • window titles                     │                    fragmented — crash-safe)
  • mic-in-use                        ├─ mic.wav          (16 kHz lane → "Me")
                                      └─ system.wav       (16 kHz lane → "Them")
                                          │
                live: WhisperKit base.en  ├──▶ transcript_live.json (during the call)
                                          │
            offline: WhisperKit large-v3-turbo
                                          └──▶ transcript_final.json
                                               verification.json   (live-vs-offline diff)
                                               meeting.md          (readable notes)
```

- **Detection** — three signals polled every 2 s: running apps (Slack +
  browsers), window titles (`meet.google.com` / `Huddle`), and CoreAudio
  mic-in-use as a Slack fallback (huddle windows don't always show up in
  window enumeration). A 10 s debounce keeps tab-switch flicker from killing a
  recording.
- **Capture** — one `SCStream` with a `desktopIndependentWindow` filter, so
  the recording follows the call window across monitors. Video is capped at
  4096×2304 (H.264 writer limit), written as a fragmented QuickTime file every
  10 s so a crash mid-meeting loses at most 10 seconds.
- **Speaker attribution** — channel-based: your mic is "Me", the call app's
  audio is "Them" (same approach Granola uses). Real per-participant names
  from Meet's caption DOM are on the roadmap.
- **Verification pass** — after the call, both lane WAVs are re-transcribed
  with `large-v3-turbo`, diffed against the live transcript by time-window +
  word overlap, and every low-similarity segment lands in
  `verification.json`. The final transcript and `meeting.md` use the
  higher-accuracy pass.

## Build & run

Requires macOS 15+ (Apple Silicon recommended) and Swift 6 command line tools.

```bash
./make-app.sh          # swift build -c release → OpenRecorder.app (ad-hoc signed)
open OpenRecorder.app
```

First launch:

1. Grant **Microphone** and **Screen Recording & System Audio** when prompted
   (System Settings → Privacy & Security). macOS 15+ re-confirms screen
   recording monthly — that's the OS, not the app.
2. The live model (`base.en`, ~150 MB) downloads from HuggingFace on first
   launch; the offline model (`large-v3-turbo`, ~1.6 GB) downloads on the
   first verification pass.

The app lives in the menu bar (record.circle icon). Joining a Meet or huddle
pops the consent prompt; "Start Recording Now" works for anything else.

## Output

One folder per meeting in `~/Documents/OpenRecorder/`:

```
2026-06-12T14-32-05_google-meet/
├── recording.mov           # call window video + both audio tracks
├── mic.wav  system.wav     # raw 16 kHz lanes
├── transcript_live.json    # realtime pass (base.en)
├── transcript_final.json   # offline pass (large-v3-turbo)
├── verification.json       # where the live pass was wrong
└── meeting.md              # readable, Obsidian-friendly notes
```

## Recording consent

California (and ~10 other states) require **all-party consent** to record a
conversation — local-only recording is not a legal defense. By default
OpenRecorder asks before every recording and shows a suggested announcement
script; consent decisions are logged to `consent-log.json`. The
"Auto-Record Without Asking" toggle exists, but announcing the recording is
on you.

## Roadmap

- Real participant names via a companion Chrome extension scraping Meet's
  caption DOM, reconciled onto the diarized timeline
- Per-process Core Audio taps (capture only the call app's audio, not the
  whole browser)
- On-device diarization (FluidAudio / SpeakerKit) for multi-speaker "Them"
  splitting
- Calendar (EventKit) pre-triggers with attendee names
- LLM summary section in `meeting.md`

## License

MIT
