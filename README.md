# NoteTaker

A macOS menu bar app that records and transcribes full meetings — your mic **and** the
other participants (Google Meet in a browser, Zoom, Teams, anything your Mac plays) —
entirely on-device, then saves clean Markdown notes with optional AI summaries.

## Features

- **Full-meeting capture** — microphone (labeled *You*) plus system audio via a Core
  Audio process tap (labeled *Others*). No bot joins your call; no screen recording.
- **On-device transcription** — Apple's `SpeechAnalyzer` (macOS 26+). Audio never
  leaves your Mac.
- **Global hotkeys** — `⌥⌘R` start/stop, `⌥⌘P` pause/resume, and `⌥⌘K` flag a key
  moment, from any app, mid-call. Paused time is excluded from all timestamps.
- **Audio kept locally** — mic and system audio saved as compressed AAC (.m4a,
  ~40–80 MB/hour) next to each transcript (toggle in Settings → Meetings).
- **Library** — a searchable window (`⌥⌘L`) of every recording with synced
  audio playback (transcript highlights and follows along; click a line to
  seek), Transcript/Summary tabs, and copy / summarize / reveal / delete
  actions (delete moves transcript + audio to the Trash).
- **Crash-safe autosave** — the in-progress transcript is written to disk every
  20 seconds during recording, so a crash costs seconds, not the meeting.
- **Record reminders (optional, off by default)** — a notification with a
  Start Recording button appears when a calendar meeting begins.
- **Key moments** — timestamped notes pinned inline in the transcript
  (`> ⭐ 36:44 · Venue confirmed`).
- **Markdown output** — saved to `~/Documents/Meeting Notes`, ready to paste into
  Notion/Obsidian or any AI. One-click *Copy Markdown*.
- **AI summaries, your choice of provider** — Anthropic (Claude), OpenAI, Google
  (Gemini), or local Ollama; model is selectable per provider; API keys live in
  your Keychain. The transcript is only sent when you click Summarize.
- **Claude without an API key** — the Anthropic provider can authenticate from
  your local config dir (`~/.config/anthropic`, created by `ant auth login`)
  instead of a pasted key. Switchable in Settings → Summaries.
- **English & Korean** — pick the transcription language (Automatic / English /
  한국어) in Settings → Meetings; the UI, markdown headings, and speaker labels
  localize to Korean automatically when the Mac's language is Korean, and AI
  summaries answer in the transcript's language.
- **Calendar-aware titles (optional, off by default)** — names recordings after the
  event you're in.
- **Modern UI** — Liquid Glass toolbar and controls, live chat-style transcript
  window, translucent material window.

## Build & run

```sh
./Scripts/make-app.sh
open build/NoteTaker.app
```

Requires Xcode 27 / macOS 26+.

## First run

1. Click the waveform icon in the menu bar → **Start Recording** (or press `⌥⌘R`).
2. macOS will ask for **Microphone** and **System Audio Recording** permission —
   allow both. The on-device speech model downloads once on first use.
3. Stop with `⌥⌘R`. The Markdown transcript is saved to `~/Documents/Meeting Notes`.
4. To enable summaries: menu bar → **Settings… → Summaries**, pick a provider and
   model, paste an API key (not needed for Ollama).

## Layout

- `Sources/NoteTaker/MicRecorder.swift` — AVAudioEngine mic capture
- `Sources/NoteTaker/SystemAudioRecorder.swift` — Core Audio process tap (system audio)
- `Sources/NoteTaker/TranscriptionEngine.swift` — SpeechAnalyzer/SpeechTranscriber pipeline
- `Sources/NoteTaker/AppState.swift` — recording lifecycle, key moments, summarization
- `Sources/NoteTaker/SummaryService.swift` — Anthropic / OpenAI / Ollama providers
- `Sources/NoteTaker/HotKeys.swift` — Carbon global hotkeys
- `App/Info.plist`, `Scripts/make-app.sh` — bundle assembly

## License

MIT — see [LICENSE](LICENSE).
