# Decision: local speech-to-text in HiveMinds

## Question
Is it feasible to add voice-to-text dictation to HiveMinds, using a local speech model that is installed on the Mac, similar to Handy?

## Options considered
1. **whisper.cpp linked into the app** (SwiftPM C target). Dropped: it puts a C++/Metal build inside the Command Line Tools-only build, the same trap that pinned SwiftTerm.
2. **whisper.cpp as a helper subprocess.** Chosen. It isolates the build and inference risk, and a model crash can't take down the terminals.
3. **Apple `SpeechAnalyzer`** (macOS 26, on-device). Chosen as a second engine: no download, no C++ dependency.
4. **Global hotkey and system-wide typing** (needs Accessibility). Deferred past v1.

## Decision
**Feasible. Build it as opt-in dictation behind one `Transcriber` protocol with two engines, after a one-day spike.**

v1 scope:
- In-app push-to-talk (hold a key while HiveMinds is focused). Microphone permission only.
- Text goes straight to the pty for terminal tiles, and through a normal insert for the Canvas answer box and other fields. No pasteboard.
- Audio is captured at 16 kHz mono with `AVAudioEngine`, only while recording, and piped to the helper over stdin. Nothing is written to disk.
- A silence and minimum-length guard to stop hallucinated text.
- A Voice tab in `Settings.swift`, off by default, with an engine picker, model, and language. Keys go in `SettingKey` and defaults in `SettingDefault`, each with a one-line explanation.
- Model download on first use (`base.en`, about 150 MB) into Application Support, with a pinned URL, a checksum, and a confirm before fetching.
- Helper stays warm for a few minutes after use, then exits on a single one-shot timer. There is no polling, so idle CPU stays at 0%.

**Helper build:** pin a whisper.cpp version (submodule or checksummed tarball). Build the helper once and cache it. `build-app.sh` copies it into the app and rebuilds only when the pin changes. It is ad-hoc signed with the app. No prebuilt binary downloads.

**Why:** everything stays local, which suits an app used on private code. Dictating prompts into Claude Code and Codex sessions is the obvious use. The helper design keeps the unproven part (whisper.cpp and Metal under Command Line Tools) away from the Swift build.

## The spike (1 day, two arms)
Whisper.cpp helper (CPU/Accelerate first, then Metal) versus `SpeechAnalyzer`, on this Mac with `base.en`.

Measure:
- Does the helper build under Command Line Tools only?
- A 5 s clip transcribed in under 2 s, both warm and on a cold start (first press after the helper exited).
- Accuracy on a small set of agent-style dev phrases (identifiers, commands, jargon).
- How `build-app.sh` signs the app today, and whether mic permission resets on each rebuild.

**Default-engine rule, set now:** if `SpeechAnalyzer` meets the same gate, it is the out-of-box default and whisper is the "install a local model" option, one click away. If it is clearly worse on jargon or latency, the whisper helper is the default.

## Disagreement left
- No disagreement on feasibility or on the v1 shape. All four seats ended on `Settled: yes`.
- One small difference in emphasis: Debater 4 wants the whisper helper kept as the headline feature, since "install a local model" is what was asked for. Others would let `SpeechAnalyzer` be the default if the numbers allow. The default-engine rule above resolves it, and the spike data decides.

## Next steps
1. Run the spike and record the numbers in `HANDOFF.md` under Progress.
2. Add the `Transcriber` protocol and the chosen engine(s).
3. Add mic capture and in-app push-to-talk into terminal tiles and the Canvas answer box.
4. Add the Voice settings tab and the model downloader.
5. Revisit global hotkey and system-wide typing only after real use.
6. After each code change, follow the repo rules: release build with `scripts/build-app.sh`, then update `HANDOFF.md` and `README.md`.

## Not yet verified
No code was run in this meeting. Latency figures are from memory, and the Metal build under Command Line Tools is unproven. The spike is meant to settle both.
