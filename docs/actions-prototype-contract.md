# Actions prototype contract

This is the P01 reference contract for a bounded continuous Actions prototype. P01 supplies evidence tools, not the runtime. Production Actions, dictation, engine pins, and packaging remain unchanged. E01, S01, S02, and S03 must not start from an unverified P01 receipt.

## Contract identity

`Tests/Fixtures/actions-prototype/contract-index.json` lists the SHA-256 of each schema and golden fixture. Its own SHA-256 is the contract identity. `test_actions_probe.py` rejects file drift. Downstream dependency manifests must record this identity and the exact app, engine, probe, model, and fixture identities. A changed contract or artifact invalidates affected receipts.

Admission verifies every indexed member before operational work. Receipts also hash the Python runner and imported browser verifier. The template manifest contains placeholders and is not executable evidence.

The version-1 JSON schemas use a closed subset of JSON Schema. Unknown fields, duplicate keys, nonfinite numbers, boolean integers, and ambiguous variants fail validation. The probe implements the subset in `validate_schema`. These files are authoritative for field names. The prose defines the additional ordering and ownership invariants.

## Identity and ownership

A session has a client-generated UUID. Legacy file replay retains its actual engine ID `replay`; it is never relabelled as a continuous session. A turn ID belongs to one session. A revision ID increases within one unfinished turn. An action occurrence ID identifies an intention, not argument equality or a turn alone. Two intentional identical commands receive different occurrence IDs. Delivery of one event twice does not create a new occurrence.

Source ranges are half-open intervals of 16 kHz post-resampling samples. They exclude decoder padding. Preview context can overlap. Authoritative turn ownership cannot overlap or change after finalization. `source_accounted` records partition the accepted source frontier into speech, silence, and explicit loss without gaps or overlaps. Speech records name their finalized owner. Silence and loss have an empty `turn_id`. Missing owned audio ends Actions safely.

Native target references bind actual executable identity, PID, UID, kernel start time, bundle ID, observer epoch, window, focused editable element, and generation. Generation changes when the window or focused element changes or observation fails. Epoch changes on observer restart. A serialized observation is evidence, not a reusable AX handle or permission to mutate a note.

Chrome references bind the dedicated executable, PID and kernel start time, fresh profile, loopback listener, browser WebSocket, page target, and committed main-frame URL. Navigation acknowledgement does not verify a loaded result. The observer checks the result through the bound page's accessibility tree.

Action receipts include source turn, revision, range, occurrence, target, and dependencies. Outcomes are `proposed`, `ready`, `awaiting-approval`, `executing`, `verified`, `failed`, `cancelled`, and `unknown`. Unknown means inspect before retry. It is not failure with automatic re-execution. The action-receipt schema freezes a future interface. P01 emits no action-execution receipts.

## Initial spoken grammar

The pause-separated demonstration contains these finalized turns:

1. `Open Notes.`
2. `Create a new note.`
3. `Set the title to Prototype hello.`
4. `Type Open Safari is literal text.`
5. `Search Chrome for Norbert Wiener.`

The bounded grammar covers explicit Notes and Chrome opens, new-note creation, title text, body text, browser search, and explicit HTTP or HTTPS URL navigation. Payload begins after the title, body, typing, or search introducer and consumes the rest of that finalized turn. Punctuation is literal. `Type Open Safari` never opens Safari. `Search Chrome for cats and open Notes` is one query. Explicit spoken correction of a committed effect requests clarification without mutation. ASR revision before finalization replaces provisional text and is a separate case.

Only one explicit leading app-open occurrence per turn can execute early, subject to the same approval policy as final actions. A matching final reuses its observed receipt. A contradiction or withdrawal records the existing open and blocks dependent mutations. All other mutations wait for authoritative finalization. P01 specifies these rules but does not parse or execute them.

## Future engine protocol 3

P01 freezes requests, replies, and events under `schemas/protocol3-*-v1.json`. No current runtime is inferred from these fixtures. P01's genuine baseline uses only observed protocol 1 or 2. Requesting a future driver returns nonzero before a substitute can execute.

The future capability query is `parakeet capabilities --format json`. A continuous artifact must report protocol 3, request and event schema version 1, and the named `continuous-turns-v1` capability. A numeric protocol version alone is insufficient. The future socket request `capabilities` uses the request schema. `continuous_start` explicitly names input kind, partials, and a bounded sample limit. `continuous_finish` drains the accepted tail. `continuous_cancel` suppresses pending action-bearing finals. Acknowledgements are not authoritative final events. Rejections identify the request, reason, and `state_changed=false`. Legacy commands retain their protocol-1/2 behavior.

Each session event has a contiguous positive session-wide event ID, session ID, protocol/schema version, engine monotonic publication time, and clock ID. Source sample position and engine publication time are separate clocks. `session_started` comes first. `session_terminal` comes exactly once and nothing follows it.

`audio_progress` and `speech_activity` report capture independently of transcript changes. Candidate boundaries can retract before finalization. `turn_preview` replaces the entire previous unfinished turn revision. `replaces_revision=0` begins a preview chain. Later previews name the current base revision. `truncated` marks omitted advisory content and never authorizes mutation. `turn_final` is authoritative and carries complete text, immutable ownership, recognition status, and explicit counters. A successful final cannot contain loss. `loss` identifies a lost range and cause. Terminal counters and the accounted source frontier must agree. A finished terminal cannot hide loss or recognition failure.

Golden traces are synthetic protocol fixtures. They cover revision replacement, boundary retraction, graceful finish, cancellation, and loss. Rejected-request goldens cover unsupported protocol, capability, input, malformed requests, busy ownership, wrong session, and requests after terminal. Tests also reject event gaps, stale replacement bases, wrong sessions, partition errors, and post-terminal events. These do not establish microphone continuity or ASR accuracy.

## Probe commands

All paths below are illustrative. The operator supplies an enrolled disposable account before operational commands can run.

```bash
python3 scripts/actions_probe.py preflight --manifest "$RUN/run.json" --out "$RUN/preflight-001"
python3 scripts/actions_probe.py run --scenario legacy-wav --manifest "$RUN/run.json" --out "$RUN/replay-001"
python3 scripts/actions_probe.py observe --scenario notes-target --manifest "$RUN/run.json" --out "$RUN/notes-001"
python3 scripts/actions_probe.py compare --scenario legacy-wav --baseline-manifest "$RUN/base.json" --manifest "$RUN/head.json" --out "$RUN/comparison-001"
```

`run-v1.json` defines the strict manifest. The account declaration includes actual UID/home and a hashed operator enrollment receipt that attests no personal Apple ID or Notes data. This attestation is not an OS observation. Root and UID 501 are always denied. The real UID, effective UID, directory-service home, `HOME`, and desktop console owner must agree where applicable. Changing `HOME` does not create desktop isolation.

The manifest lists exact artifact paths, hashes, source SHAs, and hashed build receipts. Each build receipt binds `source_sha` and `binary_sha256`; for a model directory, the latter is the inventory hash. A directory inventory hashes the compact JSON array of sorted relative file paths and file SHA-256 values. No model discovery, download, or executable fallback occurs. Read-only build inputs can be explicitly outside the run root. Mutable probe outputs and the Chrome profile cannot. Fixed legacy app paths still require the disposable account.

The input is exactly one of `wav`, `microphone`, and `protocol-events`. A WAV contains its hash and required phrases. A microphone input contains the device, bounded duration, and required phrases. Event fixtures can support the future reducer only. They never prove ASR, microphone capture, or desktop effects. Observation scenarios do not consume the declared speech input.

`fixture_writes=true` separately permits fixture process/profile/runtime creation. It does not permit arbitrary desktop commands or deletion. Native observation only reads the exact declared existing Notes process. It never owns or terminates that process. An unavailable native mutation or app GUI trigger remains blocked, not replaced with a fake executor.

The fixed scenario table is in `SCENARIOS`. `legacy-wav` executes actual `transcribe --session --format json`, with partials for protocol 2. `legacy-microphone` owns a real daemon and sends legacy start/stop requests. Neither is continuous-turn execution. `notes-target` observes two actual AX samples. `chrome-fixture` uses the local result fixture. `chrome-public-smoke` checks the real public page separately. Future continuous, reducer, adapter, integrated, and unimplemented legacy GUI outcome drivers remain blocked.

## Evidence and exits

An admitted attempt creates a private new output directory. It contains the exact manifest, `preflight.json`, `events.ndjson`, `assertions.json`, `receipt.json`, `cleanup.json`, process journals, and a hashed evidence index. Legacy work also writes `baseline.json`. The native observer writes `native-target-proof.json` with an explicit blocked state until independent screenshot and title/body correlation complete the proof. No placeholder screenshot counts as evidence.

Ordinary event traces omit transcript, AX values, query strings, source error messages, and unapproved event fields. The exact manifest can contain expected fixture content and is private evidence, not an ordinary log or public attachment. `privacy.retain_content=true` separately retains exact source-wire bytes, timestamped source events, and readable observations. Raw audio retention is not implemented. Nothing is uploaded automatically. Private files use the process umask `077`. The original local evidence is never altered for publication.

Each event records actual host monotonic receipt time. Source audio availability, engine publication, action commitment, dispatch, and verified effect remain separately labelled unavailable when unobserved. Source `audio_ms`, synthetic fixture timestamps, and old replay delays are not end-to-end timing evidence.

Exit meanings are fixed:

| Code | Meaning |
| --- | --- |
| 0 | All assertions for the explicitly named supported scope passed. Never whole-program verification. |
| 1 | An observed assertion, stream invariant, loss, phrase, or budget failed. |
| 2 | Invalid CLI, manifest, path, provenance, ownership, or fixture authorization. |
| 3 | Required environment, capability, permission, driver, or observation is blocked or unsupported. |
| 4 | Work or cleanup is incomplete, timed out, or failed unexpectedly. |
| 130 | Interrupted work. Owned cleanup is attempted and reported. |

Unsafe output requests write no evidence there and emit a redacted diagnostic to stdout. Assertions require a real authoritative completion, successful status, explicit zero loss counters, expected phrases, and process success. Phrase coverage is not exact transcript matching. Partial-only output, malformed or truncated frames, duplicate terminals, foreign sessions, and events after completion fail.

The OS desktop lease uses a fixed per-user temporary lock inode and `flock`, not a run-selected lock. It remains held through owned-process cleanup. Contention refuses before desktop interaction. Closing the descriptor releases the lease; the lock file is not deleted. Process cleanup rechecks PID, UID, kernel microsecond start time, executable path, and hash before signaling a recorded child. It records observed descendants while the browser remains live and retains those identities after reparenting. An unexpectedly exited browser parent makes descendant accounting incomplete rather than certifying cleanup. The pinned engine and native helper are reviewed leaf executables, not arbitrary subprocess drivers. The manifest is accident prevention, not an OS sandbox for hostile same-user code.

Cleanup never uses `killall`, adopts a pre-existing Notes process, or deletes fixture data. SIGKILL or machine failure cannot execute cleanup. Incomplete journals need operator reconciliation.

## Performance comparison scope

`compare` runs ten alternating A/B pairs through the actual legacy WAV driver. Both manifests must use the same run root, input, engine, and model. It reports median, range, failed attempts, complete event count, and measured recorder processing time. A common-path median fails only above both 20 percent and 100 ms. Recorder median above 2 ms per event fails. Lost events and false success fail independently.

Current comparisons establish same-engine replay repeatability and recorder overhead only. They do not measure a different app binary because the app has no supported headless replay trigger. Native completion and app regression performance remain blocked until an authorized public driver and independent effect observer exist. No number from this command substitutes for those gates. Profiling must run separately from reported samples. No baseline performance claim has been earned on the current desktop.

## Disposable bundle assembly

`package_actions_prototype.sh` accepts explicit app and engine executables, source SHAs, requested capability, new output, test bundle ID, and signing identity. The accepted test ID prefix is `com.superkeet.actionsprobe.`. It does not call production packaging, build an engine, install, notarize, release, or alter production pins.

The assembler copies the exact binaries, changes only the copied plist, signs engine then app executable then bundle, and strictly verifies them. The sidecar `bundle-manifest.json` records original source hashes, resource hashes, actual signing details, and final post-sign executable hashes. It is outside the sealed app to avoid a circular hash. A live launch must use the final embedded engine hash, not an environment override. Explicit ad-hoc signing is artifact-only evidence and does not satisfy a stable live TCC identity gate. Unsupported continuous capability is refused rather than invented.
