# Actions Mode live parity plan

Status: Phase 0 (the validation rig) is built in `scripts/live-actions/`. Phases 1 to 5 are proposals.

## Goal

Make Actions Mode feel like the reference demo ([tweet](https://x.com/instantricecook/status/2100814590300889426), "Jev" by typesafeai). The words appear while the user speaks, and each action lands about 0.6 s after the sentence that asked for it. The user never waits for a pause.

Concretely, for every native action in a spoken command:

- The live words reach the HUD within 0.5 s of being spoken.
- The visible effect lands within 0.7 s of the end of its sentence at p50, and within 1.0 s at p90.
- A natural pause between sentences (up to 0.8 s) never splits one command into two.
- Each action runs once, and an action that reports success has a visible effect.

The demo's own numbers set these budgets. They are measured below.

## What the evidence says today

### The reference demo

The demo's audio is byte-identical to `Tests/Fixtures/demo-actions/demo-audio.wav`. A per-frame region diff of the video at 30 fps gives the visible onsets. WhisperX word alignment gives the end of each triggering phrase.

| Event | Phrase ends | Visible in video | Phrase end to visible | `video-clock.tsv` says |
|---|---|---|---|---|
| Notes opens | "app" 3993 ms | 4630 ms | 637 ms | 4500 |
| New note | "note?" 6575 | 7300 | 725 | 8500 |
| Title "hello" | "Hello." 10018 | 10600 | 582 | 11500 |
| Arc opens | "browser?" 16322 | 16970 | 648 | 17500 |
| Search results | "Wiener?" 19524 | 20530 | 1006 | 21000 |
| x.com loads | "x.com?" 22947 | 24270 | 1323 | 25500 |
| Photo Booth opens | "booth?" 30512 | 31350 | 838 | 31500 |
| Countdown starts | "picture of me." about 34000 | 35150 | about 1150 | 37000 |

Jev acts after each sentence ends, not mid-word. Notes opens "before I finish my sentence" because the speaker keeps talking after "for me?".

### The simulated gate is too lenient

`DemoReplayTimingTests` passes, but `video-clock.tsv` is 0.15 to 1.85 s later than the video on seven of eight events. Against the measured onsets, the simulation dispatches three events after the video shows them, before any launch or render time:

- `title_hello` dispatches at 11470 ms, 870 ms late. Typing waits for the final transcript.
- `arc` dispatches at 17320 ms, 350 ms late. The open is not the take's first clause, so it waits for the 0.7 s `trailingHold`.
- `photobooth` dispatches at 31390 ms, 40 ms late, for the same reason as `arc`.

`new_note` and `search` dispatch within 10 ms of the video.

### Live runs fail the target scenario

Three live runs used one Gemini TTS command, played through the MacBook speakers into its microphone. BlackHole was not installed. The command was "Can you open up TextEdit for me, and once you're there, can you create a new document? And let's make the title say hello." The observer posted the command hotkey, played the audio, and polled TextEdit and the HUD through Accessibility.

| Run | Takes | TextEdit opens after "TextEdit" | ⌘N window after "document?" | "hello" |
|---|---|---|---|---|
| 1 | 2 | yes | yes | never typed. The planner pressed ⌘N a second time. |
| 2 | 1 | 511 ms | 754 ms | reported typed 1.55 s after "hello.", but the document stayed empty |
| 3 | 2 | yes | yes | never typed. The planner was still working 10 s later. |

Three runs on one acoustic path is not a benchmark. It does show three distinct failures that the simulation cannot see:

1. **Takes split at a 0.54 s pause.** The listening session ends a take after 1.0 s with no new four-word ending in the partials. Partials arrive every 0.5 s and only when the text changes, so a spoken pause of 0.4 to 0.6 s can trigger it. Replaying the command offline at 11 tick phases split it in 9 of them. The split left "And let's make" at the end of take 1. That fragment went to the Foundation Models planner, which improvised a second ⌘N.
2. **Typing can report success without effect.** In run 2 the audit log says `type_text succeeded (auto-approved)` in 20 ms, and TextEdit's document is empty.
3. **The last clause of an utterance is about 1 s slower than the demo.** Typing never runs while spoken, so "hello" waits for the 1.0 s endpoint and the final transcript.

The opening effect from the tweet already works. TextEdit was on screen 511 ms after its name, well before the sentence ended.

## Where the time goes

| Stage | Cost | Source |
|---|---|---|
| Wait for the next partial tick | 0 to 510 ms, mean about 250 | `PreviewCadence` in parakeet-cli `src/segments.rs` |
| Partial decode | about 150 ms on a 7.9 s take, measured once | `Recognizer::preview` |
| Instant launch of the first clause's app | first unambiguous partial | `SpeculativeIntentDetector`, `stabilityThreshold` 1 |
| Trailing clause that is not typing | +700 ms hold | `SpeculativeStepDetector.trailingHold` |
| Trailing typing | waits for the endpoint and the final transcript | `canCommitWhileSpoken` |
| Endpoint | 1.0 s without new progress, then the final decode | `ListeningSessionPolicy.endpointSilence` |
| App launch to window | 35 to 120 ms for TextEdit, measured once | `NativeActionExecutor` |

The partial tick sets the floor for live words. The 0.7 s hold and the 1.0 s endpoint set the gap to the demo.

Two code comments describe behavior the code does not have:

- `ListeningSessionPolicy.endpointSilence` says 1.0 s is "two missed ticks". The 1.0 s timer starts when a partial arrives, and the tick two steps later arrives after it, because the decode of a longer tail takes longer. In practice one tick with no new four-word ending ends the take.
- parakeet-cli `src/serve.rs:100` says "the worker always takes the newest preview". `offer_preview` uses `try_send` on a one-slot channel, so a full slot drops the newer preview. After a slow decode, the worker decodes audio that is one tick old.

## Plan

Each phase ends in a check that the rig or a unit test can run. The rig comes first, so every later phase has a before and after number.

### Phase 0. Build the validation rig

The rig plays speech into the real app through a BlackHole loopback and measures what appears on screen. It needs no app changes. The spikes already proved the hotkey, HUD, log, and Accessibility parts.

Pieces, all under `scripts/live-actions/`:

1. `build_stimulus.py` reads a scenario, synthesizes each utterance with `google/gemini-3.8-flash-tts` on Replicate, joins them with exact silences, and normalizes the level. It then runs a round-trip gate. The engine transcribes the result offline, and the script rejects audio that misses a required phrase at word boundaries. WhisperX alignment writes `speech-clock.tsv` with each word's start and end.
2. `observer`, a small Swift executable, plays the stimulus to the BlackHole output device with `AVAudioEngine`. It posts the command hotkey read from the `com.superkeet.app` defaults and polls three things every 20 ms. These are `NSWorkspace` for launches and the frontmost app, Accessibility probes on the target apps, and the Superkeet HUD text. It writes NDJSON events with wall-clock milliseconds.
3. `run.py` sets `audioInputDevice` to `BlackHole 2ch` and restarts Superkeet so the daemon picks it up. It puts the target apps into the scenario's starting state and captures `log stream --style ndjson` for `com.superkeet.app`. It runs the observer N times with a random 0 to 500 ms onset delay, so runs sample different partial-tick phases. Afterward it restores every setting it changed and closes only documents it created.
4. `report.py` merges the speech clock, observer events, and log lines into one timeline per run. It scores each expectation and writes a Markdown report with a pass or fail verdict.
5. Not built yet: `reference_clock.py`, which measures visible onsets in a screen recording by region diff. A throwaway version produced the reference table above. Phase 1 needs it.

A scenario is a JSON file:

```json
{
	"name": "textedit-three-steps",
	"voice": "Puck",
	"start_state": {"com.apple.TextEdit": "quit"},
	"utterances": [
		{"text": "Can you open up TextEdit for me,", "pause_ms": 200},
		{"text": "and once you're there, can you create a new document?", "pause_ms": 550},
		{"text": "And let's make the title say hello.", "pause_ms": 2000}
	],
	"expect": [
		{"id": "open", "after": "TextEdit", "probe": {"frontmost": "com.apple.TextEdit"}, "budget_ms": 700},
		{"id": "new_doc", "after": "document?", "probe": {"new_window": "com.apple.TextEdit"}, "budget_ms": 700},
		{"id": "hello", "after": "hello.", "probe": {"focused_text_contains": "hello"}, "budget_ms": 700}
	],
	"forbid": ["take_split", "planner_call", "duplicate_dispatch", "success_without_effect"]
}
```

Each run reports these numbers:

- The latency from each phrase end to its probe passing.
- The latency from each word end to the HUD showing that word.
- The counts of take splits, planner calls, duplicate dispatches, and successes without effect.

Over N runs, the rig reports p50, p90, and the rate of each forbidden event.

Done when the rig reproduces the three failures above on BlackHole. A rig that cannot see a known bug cannot prove its fix.

The first 5-run baseline on BlackHole fails, as expected. TextEdit opens 604 ms after its name at p50, within budget in 5 of 5 runs. The new document lands 1114 ms after "document?" at p50, within budget in 1 of 5. "hello" never reaches the document in 5 of 5 runs. Every run splits the command into two takes, and one run reached the planner. Live words reach the HUD 334 to 692 ms after the first word ends.

Calibrate the rig before trusting it. Record the BlackHole input while playing a click track to measure the loopback delay. Compare the Accessibility probe times with a screen recording of one run to measure probe lag.

### Phase 1. Make the existing gates honest

1. Replace `video-clock.tsv` with the measured onsets and regenerate it with `reference_clock.py`. `DemoReplayTimingTests` then fails on `title_hello`, `arc`, and `photobooth`. That failure is the baseline for Phases 3 and 4.
2. Change `missing_phrases` in `scripts/demo_actions_replay.py` to match whole words. It accepts "ax.com" for "x.com" today.
3. Add a unit test that feeds the replay partials of a two-sentence command with a 0.55 s pause to `ListeningSessionController` and expects one take. It fails today.

### Phase 2. Stop splitting commands at natural pauses

The endpoint should measure silence in the audio, not gaps between text changes.

1. In parakeet-cli, add `trailing_silence_ms` to each preview tick. Start from tag v0.1.11, which `release.yml` pins. Since v0.1.11, `Recognizer::transcribe` stops its VAD scan at the first speech chunk, so the preview cannot report trailing silence. Run the Silero VAD on each new 512-sample chunk in the capture loop instead and keep a running silence count. Emit a tick when the silence changes, even if the text did not. Keep the protocol version at 2 and add the field. Superkeet accepts only versions 1 and 2, and it requests partials only when the version equals 2 (`ParakeetService.supportedProtocolVersions`, `daemonStreamsInterimText`). Bumping to 3 would turn live text off in every shipped app. Superkeet ignores fields it does not know, so an extra field is safe.
2. In Superkeet, end a take on 1.0 s of measured silence. End it after 0.5 s when the text ends in sentence-final punctuation and every clause routes natively.
3. If a final transcript ends in a fragment that routes nowhere ("And let's make"), hold the fragment and prepend it to the next take instead of sending it to the planner.
4. In parakeet-cli, make the preview slot keep the newest preview, as its comment already claims.

Check: the Phase 1 unit test passes. The offline tick-phase sweep splits 0 of 11 phases, down from 9 of 11. The rig sees no take split in 20 runs of the TextEdit scenario.

### Phase 3. Make typing prove its effect

Find out where run 2's "hello" went before changing code. The rig records the frontmost app and the focused element at the moment of the dispatch. `SystemTextTyper.type` checks only that Accessibility is trusted, that the app runs, and that it is frontmost. It never checks which window is key or whether a text field has focus. Then make `type_text` check its result. Read the focused element's `AXValue` after the keys post, and report failure when the text did not land. A failed early step is already done again by the final command, so the cost of an honest failure is small.

Check: the rig's success-without-effect count is 0 in 20 runs, and a unit test covers the failure branch.

### Phase 4. Close the latency gap to the demo

1. An open or URL in any clause commits on its first unambiguous partial, the rule `SpeculativeIntentDetector` already uses for the first clause. Today only the first clause gets it.
2. A trailing clause commits when the partial ends in sentence-final punctuation and the engine reports at least 300 ms of trailing silence. This applies to typing too, which is the demo's "hello" case. If the final text extends what was typed, type the rest. If it differs in another way, say so in the HUD and do not undo anything.

Check: `DemoReplayTimingTests` passes against the honest clock. On the rig, every phrase-to-visible latency is at most 700 ms at p50 and 1000 ms at p90 over 20 runs.

### Phase 5. Later, if planner steps need to feel instant

Planner clauses stop early execution today. The cheapest safe step is to prepare the planner while the user speaks, by connecting MCP servers and building the session, and to run it only once the clause is complete. None of the demo's actions need the planner, so this phase is out of scope for parity.

## Choices and their trade-offs

| Choice | Picked | Rejected, and why |
|---|---|---|
| Audio path | BlackHole 2ch, selected per app through `audioInputDevice` | Speakers into the microphone works today but is noisy and audible. A file-input mode in parakeet-cli needs no install but skips Core Audio. A Core Audio process tap needs no root but adds an audio-capture permission prompt and more code. |
| Speech | The demo's own audio for parity runs, plus several Gemini prebuilt voices for scenarios | Cloning the demo speaker's voice needs his consent, and a cloned voice adds nothing that the original recording lacks. |
| Pauses | Synthesize each utterance and join them with exact silences | Gemini's pause tags are imprecise. One voice spoke "long pause" aloud. |
| Word timing | WhisperX alignment on Replicate | The engine's `audio_ms` has 0.5 s steps. |
| Measured effect | Accessibility probes, with a screen recording to calibrate them | Audit timestamps have whole-second precision and are written when a step finishes. |

## What the operator decides

- **Choose where the rig runs.** The rig opens apps and types, so the machine is unusable during a run. The default is the main account with TextEdit scenarios. TextEdit saves a typed document to iCloud Drive on its own, so the rig closes every document without saving and moves any new file in TextEdit's iCloud folder to the Trash. Notes and Photo Booth scenarios write notes and take photos, so they belong in a separate macOS user account.
- **Accept trailing typing before the pause.** Phase 4 can type a word the speaker then extends. The plan types the extension and never undoes text. If that is too risky, keep typing on the final transcript and accept about 1 s more latency on that one step.
