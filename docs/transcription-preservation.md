# Transcription preservation and recovery

## Implemented

1. **Complete messages:** stdout is byte-framed NDJSON. UTF-8 is decoded after a
   complete message arrives. Long/multiline transcripts are delivered once. A
   message over 8 MiB fails explicitly instead of retaining a suffix.
2. **Bounded engine sessions:** parakeet-cli v0.1.6's session pipeline assigns
   every accepted audio sample to a bounded segment, preserving shared encoder
   and decoder context. Token-frame ownership avoids text-based deduplication.
3. **Conservative filler cleanup:** only uh/uhh/um/umm are removed. er, err, ER,
   hmm, ah, like, negations and deliberate repetitions remain literal.
4. **Completion state:** client-generated session IDs survive stop/inference.
   Recording is blocked until completion; cancellation, crash, timeout, silence,
   partial recovery and success have definite outcomes. Status is shown in the
   menu bar, announced for accessibility, and visible in Output & Privacy.
5. **Independent collection:** microphone callbacks/collection do not wait for
   recognition. Overflow counters and segment failures travel with completion.
   Stop closes the callback gate, drains accepted queued audio, then flushes the
   resampler tail. The normal inference queue holds over ten minutes of audio;
   an overrun is explicit even if inference stalls longer.
6. **Audio regression suite:** eight synthetic WAV scenarios, an exact
   critical-word/answer-count oracle, WER scoring, and a real-daemon protocol
   smoke test. See [AudioRegression](../Tests/AudioRegression/README.md).
7. **Recovery:** Copy Last Transcript, Copy Original Transcript and Undo Text
   Changes and Copy work without persistent history. Original text and partial
   status are also retained with saved history when history is enabled. Old
   history files remain readable. Undo restores text to the clipboard for the
   user to paste; it does not edit an external application's document.
8. **Personal phrases:** explicit whole-phrase replacements, optionally scoped
   by bundle identifier. App-specific rules take precedence, longer phrases win,
   and replacements cannot cascade. No dictionary-based recognition bias is claimed.
9. **Optional spoken commands:** standalone punctuated clauses/lines support
   scratch that, replace X with Y, and undo last correction within the current
   recording. Ambiguous targets stay literal. Natural er/err/or is never inferred
   to be a correction. The original transcript remains recoverable.

## Follow-up correctness fixes (review items 1–6)

Malformed replacement commands remain literal instead of constructing invalid
Swift ranges. Delayed auto-paste verifies target activation, frontmost state,
Accessibility and clipboard generation before posting a keystroke. History and
statistics save only changed state and back up unreadable originals before their
first replacement, surfacing persistence errors in the UI. Toggle autorepeat is
consumed, and a second press cancels a pending start using request identities.
Provisioning exceptions publish a retryable failure before their task completes.
Short-lived ready/crash cycles preserve restart history; a sustained healthy run
can reset the backoff.

## Cleanup and shared components

- `TranscriptSessionGate` is the recording-output gate; the retired Boolean gate
  and its tests have been removed.
- `DebouncedStoreWriter` owns scheduling, revision checks, retryable writes and
  synchronous flushing for both history and usage statistics. Each store retains
  its own data model and user-facing messages.
- `DevelopmentEngineLocator` defines Swift-side engine selection and the pinned
  checkout reference. Explicit binary overrides take precedence over an explicit
  source directory, then local checkouts, installed binaries and the versioned
  bootstrap checkout. Invalid explicit overrides fail rather than selecting a
  different executable. Startup and model provisioning use the same selection.
- `AppVersion` reads packaged-app metadata, with the source repository's plist as
  the local-development fallback. The unused SwiftPM resource declaration is gone.
- The microphone picker, readiness checks and meter share native CoreAudio device
  names. Name parity was verified against the engine's four available inputs on
  this Mac. Repeat that check on other hardware with:

```bash
SUPERKEET_DEVICE_PARITY_ENGINE=/path/to/parakeet swift test --filter AudioDeviceParityTests
```

The engine's live entry point is `src/serve.rs`, with focused collection, protocol,
runtime-file and worker modules under `src/serve/`. Its original uncompiled daemon
is preserved locally in `.refactor-backups/serve-legacy-20260914.rs`; that directory
is ignored by Git. No acoustic algorithm was changed as part of this cleanup.

## Measured acoustic limits

On September 14, 2026, using the local INT8 v3 model and macOS Samantha synthetic
speech, four of eight strict audio scenarios passed:

| Scenario | WER | Critical checks |
| --- | ---: | --- |
| List starting at five | 0% | Pass |
| Auth versus off | 14.3% | Fail: auth → off |
| Correction versus choice | 12.5% | Fail: err → air |
| Negations | 0% | Pass |
| Intentional like | 0% | Pass |
| Repeated answers | 100% | Fail: “AAA agrade, agrade” |
| Immediate stop | 0% | Pass |
| Ten-minute session | 26.1% | Fail: substitutions and count errors |

All eight engine runs reported zero queue drops and zero failed inference
segments. These counters establish transport health, **not word accuracy**. The
long sample contains repeated synthetic speech plus pauses and is exactly 600
seconds. A separate sample-conservation test covers uninterrupted ten-minute
input. Human complaint recordings were unavailable; microphone/driver and
real-world recognition accuracy still need recorded evaluation. Failures remain
hard failures in the runner rather than being waived by cleanup or WER thresholds.

Generated WAVs, SHA-256 provenance and the full local report are under
`.build/audio-regression/`. Generation is reproducible through the checked-in
manifest/runner; voice versions may change the waveform and recorded hashes.

## Release dependency

The release, installer and development pins target
[parakeet-cli v0.1.8](https://github.com/lucataco/parakeet-cli/releases/tag/v0.1.8)
and accept transcript protocol 1 or 2. Local development can use
`PARAKEET_SOURCE_DIR` or the adjacent Formulae checkout.

The client speaks daemon protocols 1 and 2 (`ParakeetService.supportedProtocolVersions`)
and records which one the running engine reported. Protocol 2 (parakeet-cli
0.1.7) adds opt-in interim text: when a Command Mode recording can use it,
`start` carries `"partials": true` and the engine streams
`{"type":"partial","session_id":…,"text":…,"sequence":n,"truncated":bool}`
events, which `ParakeetService.interimTranscripts(sessionID:)` exposes as an
`AsyncStream<PartialTranscript>`. Partials are advisory and never touch the
`complete` text, the clipboard, history, or the loss accounting; dictation
recordings never request them. Any other event type on the daemon's stdout is
logged and ignored rather than treated as a protocol violation, so a still-newer
engine can be adopted without lock-stepping the app release. Malformed events
and an unsupported `protocol_version` in socket replies still fail the session.

Persistent audio retention/replay/retry remains the explicitly later recovery
phase. The app keeps no audio archive; persistent transcript history stays opt-in.
