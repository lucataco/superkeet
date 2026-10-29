# Verify Actions prototype evidence

P01 is not verified. The current operator supplied only the primary macOS account, UID 501. No disposable account or guest is available. Do not launch Notes, Chrome, Superkeet, microphone capture, or an AX observation on that account. A worktree is not desktop isolation.

The current delivery covers tools and non-desktop tests only. Native screenshot/title/body proof aggregation and the legacy GUI outcome/performance driver are unimplemented, not just blocked by permissions. Actual Notes AX evidence must precede their design. An isolated account alone will not complete P01. Keep E01 and S01 blocked until all P01 gates pass.

## Run safe checks without a desktop

1. Run the repository gates.

```bash
swiftlint lint --strict
swift build
swift build -c release
swift test
python3 -m unittest discover -s scripts -p 'test_*.py'
```

2. Lint and compile the standalone helper explicitly. The repository SwiftLint configuration includes only Sources and Tests by default.

```bash
swiftlint lint --strict --no-cache --config .swiftlint.yml scripts/ActionsProbe/main.swift
swiftc scripts/ActionsProbe/main.swift -o "$EVIDENCE/ActionsProbe"
```

3. Run CLI help and a primary-account refusal with a valid manifest. Save the actual terminal transcript and exit code. Do not substitute a rendered mock terminal image.

```bash
python3 scripts/actions_probe.py --help
python3 scripts/actions_probe.py preflight --manifest "$EVIDENCE/unsafe-run.json" --out "$EVIDENCE/must-not-exist"
```

Expect nonzero and no output-directory creation. A schema-valid manifest can still be operationally unsafe. The unit tests exercise duplicate keys, wrong input kinds, path escapes, stale process identity, malformed stream outcomes, privacy, lease contention, and failure exit codes without desktop access.

## Prepare an isolated desktop

1. Ask the operator to supply a disposable macOS account or guest with an active GUI session. Do not create an account or reuse personal state.
2. Record its actual UID and directory-service home. Keep its Apple ID disconnected and its Notes data disposable. Save the operator's enrollment attestation and SHA-256.
3. Copy exact fixtures and artifacts into approved paths. Preserve the original model, fixture, source, build-input, and executable hashes. Read-only artifacts outside the run root must remain explicit inputs.
4. Create a private run root in that account. Set its mode to `0700`. Use new output directories for each attempt. Never reuse a Chrome profile or remove an old attempt to make a command pass.
5. Write the manifest against `schemas/run-v1.json`. Select one input kind. Declare fixture writes separately from content retention. Record the contract-index SHA-256.
6. For every artifact, attach a hashed build receipt with `source_sha` and `binary_sha256`. Record the release configuration, toolchain, source cleanliness, build command, and resource/model inventory in that receipt. Do not identify a build from its version string alone.
7. Ask the operator to grant the actual signed identities Microphone, Accessibility, and screenshot permissions in the disposable account. Add Notes Automation only if a separately reviewed fixture preparation method requires it. Never grant or reset TCC automatically.
8. Record app, engine, helper, fixture, model, hardware, OS, workflow, signing identity, and contract hashes in the external run manifest. Recheck them before each proof.

The legacy app still uses per-account fixed defaults, storage, audit, and runtime paths. A test bundle ID alone does not redirect them. Run one legacy app/engine lane at a time. The probe's desktop lease is keyed to the account, not the worktree or run directory.

## Assemble an explicit test bundle

Use the root's freshly rebuilt baseline engine and its build receipt. Do not rebuild the engine independently or select an older executable by version. Run this only after release app gates pass.

```bash
scripts/package_actions_prototype.sh \
  --app "$APP_RELEASE/Superkeet" \
  --engine "$BASELINES/engine-build/release/parakeet" \
  --app-source-sha "$APP_SHA" \
  --engine-source-sha "$ENGINE_SHA" \
  --out "$EVIDENCE/test-bundle-001" \
  --bundle-id "com.superkeet.actionsprobe.$RUN_SUFFIX" \
  --signing-identity "$TEST_SIGNING_IDENTITY" \
  --capability legacy-session
```

Inspect the resulting sidecar manifest. Verify strict signatures and the final app and embedded-engine hashes after signing. Before any live launch, bind those final hashes into the run manifest. An explicit ad-hoc identity can test artifact assembly without a desktop, but does not prove live permission identity. No assembler output is installed or notarized.

Request `continuous-turns-v1` only with a future artifact that actually negotiates the frozen capability. A protocol-2 baseline must refuse that request. A successful future-capability package still does not supply a missing runtime driver.

## Capture the real legacy baseline

1. Run `preflight` under the disposable account. Inspect the capability scope. A legacy protocol pass is not native feasibility.
2. Run `legacy-wav` with the existing demo audio and the same freshly rebuilt engine for trunk and head. Preserve the original demo fixtures.
3. Retain source events only with local content opt-in. Check exactly one actual completion, successful status, explicit zero losses, complete frame accounting, and required phrases. Record phrase coverage, not exact transcript equality.
4. Run `legacy-microphone` separately for a bounded single take. Keep the input device and duration explicit. Do not call repeated legacy takes continuous capture.
5. Preserve `preflight.json`, `baseline.json`, `events.ndjson`, `assertions.json`, process identities, cleanup, and the evidence index outside the checkout. Record unavailable commitment, dispatch, and effect timestamps as unavailable.

The new probe can drive an engine at trunk externally even though trunk lacks the probe. The app has no safe headless replay entry point in P01. Native GUI triggering and native end-state baseline require an unimplemented driver and proof aggregator. Establish actual Notes AX evidence in the disposable desktop before designing them. Do not call internal production setters or fake executors to fill that gap.

## Establish Notes target feasibility

1. Have the operator prepare one uniquely marked disposable note in the isolated account. Leave it for inspection. No automated Notes mutation driver is implemented in P01.
2. Record Notes' actual executable hash, PID, UID, microsecond kernel start time, and bundle ID in `native_target`. Do not adopt it as an owned child for cleanup.
3. Run `observe --scenario notes-target` with the compiled helper and local content retention. It reads two actual AX observations. Missing AX access returns BLOCKED rather than an empty successful target.
4. Capture an independent screenshot of that exact app/window. Correlate the AX window, focus, readable editor, title, and body with the same visible fixture. A title-only tree is insufficient.
5. Verify stable editor identity across observations and a changed generation when the focused window changes. A new observer epoch invalidates older tokens.
6. Keep `native-target-proof.json` blocked. The probe lacks a screenshot/title/body proof aggregator. Independent correlation supplies design evidence but does not change the receipt automatically. Do not mark native proof verified until that implementation and its independent verification exist.

If title/body observation is insufficient, record UNSUPPORTED for that Notes/macOS adapter scope and stop mutation work. Select a smaller supported operation or explicit adapter alternative before S02. This is an unresolved feasibility gate, not permission for blind typing.

## Establish Chrome binding

1. Declare the exact Chrome artifact and a fresh dedicated profile under the run root. Enable fixture writes. Do not use an existing personal process, profile, debugging port, or tab.
2. Run `run --scenario chrome-fixture`. It starts a loopback fixture and the declared browser, verifies the actual listening process and profile, creates a page target, and reads the committed URL and accessible result.
3. Capture the same page and browser window independently. Confirm the profile PID, target ID, URL, expected query, and result agree.
4. Test a wrong result page. Successful navigation with the wrong result must fail.
5. Run `chrome-public-smoke` separately. A challenge, consent screen, network failure, or unobservable result blocks the public smoke. The local fixture is not a substitute for public search.
6. Save process identities, raw opt-in observations, assertions, and cleanup. Retain the disposable profile; deletion needs separate operator authorization.

## Run the ten live lanes

Run each lane at the exact PR head in the disposable account. Use fresh independent verifiers, not the code owner. Save actual terminal transcripts and screenshots under `/tmp/swarm-PR_ID/worker-N/SLUG.png`, then copy their evidence index to durable storage.

| Lane | Required proof | Current state |
| --- | --- | --- |
| 1 | Trunk/head legacy phrase coverage with the same rebuilt engine and observer impact check | BLOCKED pending disposable live lane; use the root's recorded rebuilt artifact |
| 2 | Primary-user path refused before launch or mutation | Unit/CLI refusal is runnable; live terminal screenshot remains open |
| 3 | Notes visible document and AX editable target identify the same app/window | BLOCKED |
| 4 | Chrome screenshot, profile PID, page target, and URL agree | BLOCKED |
| 5 | Operator-revoked test Accessibility permission yields BLOCKED | BLOCKED |
| 6 | Focused-window change changes generation | BLOCKED |
| 7 | Wrong fixture result fails despite accepted navigation | BLOCKED |
| 8 | Interrupt stops only recorded owned processes | Pure cleanup tests are runnable; live lane BLOCKED |
| 9 | Second desktop lease refuses without input injection | OS-lock unit proof is runnable; desktop lane BLOCKED |
| 10 | Ordinary trace excludes dictated content and opt-in trace remains auditable | Pure privacy tests are runnable; live terminal proof BLOCKED |

No fixture or unit result closes a native lane. Missing screenshot permissions or a stable test signing identity stays BLOCKED. P01 has no special operator review gate, but required repository review remains an operator gate. Do not bypass it.

## Measure performance after builds stop

1. Check machine load and active builds. Stop if another build or desktop worker can affect the sample. Acquire the exclusive disposable desktop lease.
2. Record the proposed claim and timing scope before measurement. Keep cold, warm, public-network, approval-wait, and profiler runs separate.
3. Capture trunk first in `perf/P01-baseline.json`. Use the same rebuilt engine, model, fixtures, hardware, release configuration, and observation definition on both sides.
4. Run `compare --scenario legacy-wav` for ten alternating A/B pairs. Inspect work counts, failures, complete event counts, median, range, and recorder time.
5. Report this tool's current scope as same-engine file-replay repeatability and recorder cost. It does not execute a different app artifact. Do not label this an app speedup or native completion comparison.
6. Measure real Notes and browser completion independently after a safe public GUI trigger and actual postcondition observer are available. That portion remains blocked. Profile separately to identify the limiting stage.

Fail a shared-path median regression only when it exceeds both 20 percent and 100 ms. Fail recorder processing above 2 ms median per event. Any lost event or false success fails regardless of latency. The complete P01 performance gate needs file replay and verified Notes/browser scenarios, not this subset alone.

## Close an attempt without data deletion

1. Interrupt or finish the probe normally. Inspect its cleanup receipt and directly check every recorded child identity exited.
2. Leave pre-existing Notes and unrelated applications running. Do not use process-name termination.
3. Confirm the kernel lease is released. Keep its fixed lock inode.
4. Keep test notes, profiles, fixture output, raw local evidence, failed attempts, and signing receipts. Request separate deletion authorization.
5. Record the exact head and all blockers in the external decision trail. Hand off one PR without merging, tagging, deploying, changing pins, or declaring P01 verified.
