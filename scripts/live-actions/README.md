# Live actions rig

The rig plays speech into the installed Superkeet app and measures when each action becomes visible. It answers one question. Does an action land about 0.6 s after the sentence that asked for it, without splitting the command or reporting a success that did nothing?

It needs no change to the app. Speech goes through the BlackHole 2ch loopback device, so the room stays quiet. The rig reads what happened from three places that the app already exposes. These are the Accessibility tree of the target app and of the Superkeet HUD, the unified log of the app process, and the app's audit log.

## Prerequisites

- Superkeet is installed at `/Applications/Superkeet.app`, onboarding is done, and Actions Mode is on. To test another build, set `SUPERKEET_APP` to its bundle path. Sign that build with the same Developer ID team as the installed app, so macOS keeps its Accessibility and Microphone grants. The rig quits the installed app and launches that build, and relaunches that build when it restores.
- BlackHole 2ch is installed (`brew install --cask blackhole-2ch`, which asks for an administrator password once).
- The terminal that runs the rig has Accessibility permission. It does not need Screen Recording. The HUD screenshot comes from `cua-driver`, which has its own grant.
- `REPLICATE_API_TOKEN` is set. It is only used when a stimulus is built for the first time.
- `ffmpeg`, `swiftc`, and `python3` are on the path.
- The machine is idle. The rig opens apps, presses keys, and types, so do not use the keyboard or run `swift test` during a run. Load from other work changes the latencies. Each run records the load average.

## Run

```
python3 scripts/live-actions/run.py scripts/live-actions/scenarios/textedit-three-steps.json --runs 5
```

A run takes about 25 seconds. The first call also builds the stimulus, which takes about 30 seconds and calls Replicate. The result is cached under `.build/live-actions/cache/`.

Evidence and the report land in `.build/live-actions/runs/<timestamp>/`. To score a folder again without playing anything, run `python3 scripts/live-actions/report.py <that folder>`.

Pass `--allow-planner` only on a machine where the on-device planner may drive any app. Without it the rig cancels the app the moment the planner starts. See the safety notes below.

## What each piece does

- `build_stimulus.py` turns a scenario into audio. It synthesizes each utterance with `google/gemini-3.8-flash-tts`, trims the silence the voice adds, and joins the clips with the scenario's exact `pause_ms` gaps. It then scales the file to about -16 LUFS with a true peak of at most -1 dBTP, and writes a 48 kHz stereo WAV and a 16 kHz mono copy.
- Three gates guard the audio. The engine must transcribe the copy with every `expect[].after` phrase present on word boundaries, so "ax.com" does not satisfy "x.com". WhisperX must align every phrase inside the utterance windows, which writes `speech-clock.tsv`. And the engine's live partials must show each phrase within one second of its end. The last gate keeps a voice that the engine mishears from passing as a timing result. A failed gate synthesizes the utterances that carry the phrase again, up to three times.
- `observer.swift` is compiled on first use into `.build/live-actions/observer`. It presses the command hotkey read from the app's defaults, plays the WAV to BlackHole, and writes one NDJSON event for each visible change. Three loops poll on their own, so a slow Accessibility call into a launching app cannot delay the frontmost-app timestamps.
- `run.py` sets up the machine, runs the observer N times, collects evidence, tears down, and restores. Each run waits a random 0 to 500 ms on top of 1.5 s between the hotkey and the first sample, so runs land on different phases of the engine's 0.5 s partial tick. The engine counts ticks in audio samples from the start of capture, so a delay before the hotkey would change nothing. This is inferred from the engine's design, not measured.
- `report.py` scores every run and writes `report.md` and `verdict.json`.

## Scenarios

A scenario is a JSON file. `start_state` names the apps to quit before each run. `utterances` are spoken in order, each followed by `pause_ms` of silence. Each `expect` item names a phrase, the probe that must pass, and a budget in milliseconds. `forbid` lists the events that count as failures.

Probes read the real screen state, not the app's own claim.

- `frontmost` passes when that app becomes the frontmost app.
- `new_window` passes when the app shows a document window whose title has not been seen before. The Open panel does not count.
- `focused_text_contains` passes when a text area of the target app contains the text.

Latency is the time the probe first passes minus the end of the phrase in the speech clock. Negative means the action landed before the speaker finished the phrase.

Only `com.apple.TextEdit` may be a target. TextEdit documents are never saved by hand, so a run cannot write real user data. `common.SAFE_TARGETS` enforces this when a scenario loads.

## Forbidden events

- `take_split` counts dispatches of the utterance that happen before the last spoken word ends. The log line is "Pause detected; dispatching the utterance".
- `planner_call` counts log lines in the `ActionPlanner` category that start with "Planning with".
- `duplicate_dispatch` counts mutating audit rows that repeat the same tool and arguments, which covers an early action repeated on the final path.
- `success_without_effect` counts texts that the audit log or the HUD says were typed but that the TextEdit documents do not contain when the run ends. TextEdit's curly quotes do not count as a difference.

## What the rig changes on the machine

- It writes `audioInputDevice` in the `com.superkeet.app` defaults and relaunches Superkeet so the engine reads BlackHole. The original value is saved in `.build/live-actions/restore.json` first.
- It quits and reopens Superkeet, and it quits TextEdit before and after every run. It closes TextEdit documents with "saving no" and refuses to start if TextEdit holds a document with text.
- It presses the command hotkey and, when the planner starts, Escape. The hotkey comes from the `commandHotkeyKeyCode` and `commandHotkeyModifierFlags` defaults. When they are absent, which is true until the shortcut is changed, the rig uses the app's built-in Option+Shift+Space (key code 49, flags 655360).
- It moves any new file that TextEdit autosaves into `~/Library/Mobile Documents/com~apple~TextEdit/Documents/` to `~/.Trash`, and prints an error. The run then exits with status 3. Nothing is deleted outright.

It restores `audioInputDevice` in a `finally` block and on SIGINT and SIGTERM. If the process is killed harder, `restore.json` stays behind and the next run restores from it. When no record exists and the key already says BlackHole 2ch, the rig assumes a crashed earlier run and treats the original as unset. To check by hand, run `defaults read com.superkeet.app audioInputDevice` and `pgrep -fl "parakeet serve"`. If the user never chose a device, the first reports the key as missing and the second shows no `--device`.

## Safety notes

Superkeet's approval policy decides what its planner may do on its own. A clause that the engine mishears can reach the planner or the native `open_url` route, and either can drive apps other than TextEdit. During development, one misheard "TextEdit" opened a Chrome tab through `open_url`, and the planner then opened Notes and created an empty note. The planner guard limits the damage. The native route is not covered, so run the rig in a separate macOS user account if that matters.

## Limits

- The loopback delay between playback and the app hearing the audio is not calibrated, because that needs microphone access for the terminal. `report.py --loopback-ms N` subtracts a measured value. Until then, every latency includes the delay.
- Accessibility polling can lag. The report prints the longest poll per source. The workspace loop is under 2 ms. The target-app loop stalled for about 210 ms while TextEdit launched, so window and text probes can be late by that much around a launch.
- The first AppleScript call to a cold TextEdit can time out after 20 s. The rig retries it once, then stops with a message that names the script.
- Events are timestamped when the observer sees them, so each latency has an error of up to one poll.
- The first-words column is the time from the end of the first spoken word to the first HUD update that shows two consecutive script words. It does not depend on the HUD layout.
- `fixtures/` holds a recorded run that the unit tests in `scripts/test_live_actions.py` score. The tests need no audio, network, or app.
