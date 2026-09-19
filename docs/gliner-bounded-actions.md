# GLiNER bounded actions: implementation and evidence

Historical baseline report, September 17, 2026. The base-model intent/slot
quality gate failed. The experiment now defaults to the custom fine-tune;
see the [September 18 grounding evaluation](custom-grounder-evaluation.md)
for its different task, results, and current implementation status. Measurements
below are retained unchanged for reproducibility.

## Implemented

- A local GLiNER2.5 adapter with the same `choose_live` interface as the
  [pinned jev-use example](https://github.com/trycua/cua/tree/201732fffd81a40818be7ce2e04269aec962bc42/libs/cua-driver/examples/jev-use).
  A reproducible patch installer adds `--provider gliner` and `--gliner` to its
  runners. Candidate descriptions are labels; the original table retains all
  tools and arguments. Unknown, duplicate, missing, nonfinite, out-of-range,
  and zero-mass model scores are rejected. Exact ties choose `reobserve`.
- Pinned Python dependencies and checkpoint revisions, CPU/MPS fixture
  benchmarks, 100 synthetic intent examples, and 30 synthetic click tables.
- Swift `ActionCandidate`, `ChoiceRequest`, `ChoiceResponse`,
  `BoundedChoiceOutcome`, `ActionChoosing`, `HeuristicChooser`, `ActionIntent`,
  `ActionIntentExtracting`, `HeuristicIntentExtractor`, and `ActionIntentPolicy`.
  The wire methods reject unknown fields, enforce collection/string/64 KB
  limits, preserve reserved IDs, and resolve responses against the original
  immutable table with capture checks.
- Intent-based tool-filtering and prioritization interfaces. The existing
  Foundation Models planner extracts one heuristic intent for routing. Legacy
  task-string entry points remain compatibility wrappers. Existing routing
  behavior and approvals are preserved.

No Python runtime is launched by Superkeet, no model download setting is
exposed, and no bounded execution path replaces the existing planner yet.

## Measured evidence

Host: Apple M5 Max, 128 GiB RAM, macOS 27 build 26A428, Python 3.13.15,
`gliner2==2.0.0`, Cua Driver 0.28.2. Models use their default precision.
Checkpoints are pinned in `scripts/gliner/gliner_adapter.py`.

| Model | CPU warm p50 | MPS warm p50 | Submit fixture |
| --- | ---: | ---: | --- |
| Small | 30.1 ms | 12.6 ms | 20/20 per device |
| Base | 66.6 ms | 18.9 ms | 20/20 per device |
| Multilingual | 88.6 ms | 20.1 ms | 20/20 per device |

All six combinations selected a reserved candidate for the ambiguous visual
fixture. Twenty repeats of one deterministic fixture measure latency and
repeatability, not general accuracy. Measurements exclude import, download,
model load, and observation time. Small's process/model startup added about
3.4 seconds to the first live decision; the next decision including observation
took 81.6 ms.

The real loopback browser proof completed with `verified` for both mock and
small/CPU, using `/state` readback rather than the tool response. Driver typing
and clicking together took about 4.9 seconds even with the mock provider.
The plan's sub-second app/URL target has not been demonstrated.

The synthetic intent evaluation failed the required 90% action accuracy and
0.85 slot F1 for every checkpoint:

| Model | Action accuracy | Slot micro F1 |
| --- | ---: | ---: |
| Small | 66% | 0.555 |
| Base | 70% | 0.549 |
| Multilingual | 36% | 0.550 |

On the final synthetic click set, all models chose the correct candidate in
20/20 unambiguous tables with rotated candidate positions, and stayed within
the reserved choices in 10/10 ambiguous tables. This does not compensate for
the missing or incorrect intent slots needed to build real candidate tables.
The [machine-readable evidence](gliner-evaluation.json) records the pinned
revisions, latency measurements, final quality summaries, and live JSONL events.

For example, small classified the combined Helium/YouTube command as
`open_url` but put `youtube.com` in `query` and `target`, leaving `url` empty.
Base classified that command as `open_app`. Small lost the text slot for
“Type hello world”; all models missed the target slot for “Click Save”.
These are failures of the tested fixed schema, not proof that all schema or
fine-tuned variants will fail. Human descriptions were used for chooser labels;
short imperative alternatives and a structured chooser head remain unevaluated.

The synthetic set was used at the user's direction because history records
have no Command Mode marker. No real-user transcripts were exported. Thirty
real window snapshots, multilingual evaluation, confidence calibration, and
real-command accuracy remain unverified. The full reproducible methodology is
in [the experiment README](../scripts/gliner/README.md).

## Gate before runtime integration

The current schema should not supply action slots for executable candidate
construction. Before Phase 2, revise and evaluate extraction on a separate
held-out set: consider action classification plus action-specific extraction,
explicit missing-slot fallback, or fine-tuning. Require the original accuracy
thresholds and a calibrated confidence/margin policy before enabling model
choices. Do not tune against this smoke set and claim an independent result.

The app integration also needs fresh, untruncated observations: today the
session controller caches tool results and the router truncates them to 800
characters. Both must be addressed when implementing reobservation and
independent postconditions, or the loop could verify stale/incomplete state.

An upstream submission is deferred while quality evidence is incomplete.
The pinned checkout and reproducible patch installer are available for review.

## Validation

- `swift build` and `swift build -c release`: passed.
- `swift test`: 324 tests, 5 skipped, no failures.
- `swiftlint lint --strict`: zero violations.
- `python3 -m unittest discover -s scripts -p 'test_*.py'`: 22 passed.
- Upstream core and choice-contract tests: 16 passed.
- The one-shot GLiNER CLI also passed with `SUPERKEET_GLINER_OFFLINE=1`.

This validation covers the proof tooling and Phase 1 contracts; it does not
claim a working app sidecar or bounded execution loop.
