# Custom CUA grounder evaluation

September 18, 2026. The experiment now uses
[`lucataco/gliner2.5-cua-grounder-macos-v1`](https://huggingface.co/lucataco/gliner2.5-cua-grounder-macos-v1)
with the matching [`gliner-cua`](https://github.com/lucataco/gliner-cua) runtime.
The grounding smoke gate passes. This is a current-step action grounder;
the earlier intent/slot test measured a different capability and is not claimed
as fixed by this result.

## Implementation

- Default checkpoint: `lucataco/gliner2.5-cua-grounder-macos-v1`, revision
  `571da5981b95e29cbcc6b4fdefb0f07ac1bf9144`.
- Runtime dependency: `gliner-cua` at
  `b0a822ff90a6827247847dc40cd927b4be4f308a`, pinned in the requirements lock.
- The adapter uses `LocalCUAChooser` with the training serializer, exact
  `driver_action` instruction, ordered opaque labels, escaping, FP32 scoring,
  temperature-1 softmax, and hard 4,096-token limit. The previous independent
  sigmoid-label scorer is retained only for historical base-model comparisons.
- `serve_grounder.py` provides a standalone one-shot/resident JSONL chooser,
  independent of the Cua checkout. Responses identify the Hugging Face model,
  not the local cache path. Invalid inputs return an error in JSONL mode;
  subsequent requests remain usable. No actions execute in this process.
- The pinned jev-use adapter now defaults to the fine-tune. Its fixture callback
  supplies one scripted current step at a time: fill the verification field,
  then submit. Its menu descriptions explicitly name the operation, control,
  and supplied value. Tools, IDs, and arguments remain unchanged in the
  caller-owned candidate table. The callback requires a `goal=` current step.
- Added a separate 100-case Superkeet grounding suite and CPU/MPS measurements,
  with complete menus and stable dataset hashes. The historical intent/slot
  evaluator explicitly accepts only the original base checkpoints.

The Swift app now wires the resident process and native click/text-entry path
behind an experimental setting. It grounds literal single-step templates or
steps supplied by Foundation Models, with local eligibility, post-approval
freshness, and one-shot execution through the existing approval/audit router.
See [app setup and behavior](actions-mode.md#native-ui-grounder-experimental).
The measurements below describe the evaluation fixtures; they are not an
end-to-end app benchmark. The app does not ask this model to extract intent slots
or decompose arbitrary voice commands.

## Results reproduced locally

Host: Apple M5 Max, 128 GiB RAM, macOS 27, Python 3.12.13, GLiNER2 2.0.0,
PyTorch 2.14.0, Transformers 4.57.6, FP32, eight CPU threads, Cua Driver 0.28.2.

| Evaluation | Result | Warm p50 |
| --- | --- | ---: |
| Published 128-case test corpus, MPS | 128/128 | 35.5 ms |
| Separate Superkeet grounding cases, MPS | 98/100 | 27.9 ms |
| Same Superkeet cases, CPU | 98/100 | 89.1 ms |
| Pinned submit fixture, MPS | 20/20 | 22.6 ms |
| Pinned submit fixture, CPU | 20/20 | 84.2 ms |
| Live browser confirmation fixture | 6/6 verified actions | 53.0 ms |
| Live native macOS confirmation fixture | 6/6 verified actions | 51.5 ms |

Timings exclude imports/download/model load and the first inference. The repeated
submit fixture measures latency and repeatability, not general accuracy. Both
devices selected `abstain` on the upstream ambiguous visual fixture, which
offers only reserved choices.

Published corpus hash:
`c0da037e60294aaf06f014d722dab7c157dfc3afa3bd8b5676a9e02e4f944444`.
It was regenerated from the pinned code and seed 42 without retraining.

The separate Superkeet suite has twenty cases each for clicking, typing,
section matching, absent-target abstention, and incomplete-observation
reobservation. Candidate order is shuffled with a fixed seed. Wrong-operation,
wrong-value, wrong-control and wrong-section alternatives remain in the menus.
No expected target is inserted at evaluation time, and no model parameters or
confidence thresholds were tuned to the results. Both devices scored:

| Category | Correct |
| --- | ---: |
| Click | 20/20 |
| Type | 20/20 |
| Section matching | 20/20 |
| Absent target: abstain | 18/20 |
| Incomplete observation: reobserve | 20/20 |

The recorded smoke criterion is at least 90% in each category. The final dataset
hash is `6a5aa4a9146dd9efb1870c6cef9e93226743c1460f4437cadd8f4f09c2ac96bf`.
A pilot scored 97/100 but contained an annotation ambiguity: some unqualified
field instructions had two same-name, same-value targets, only one labeled
positive. Those distractors were corrected to distinctly named `Previous ...`
fields before the final evaluation. The pilot's hash and results are retained
in the evidence file. Both versions remain synthetic smoke sets, not broad
held-out real-user evaluations.

The two remaining misses requested a nonexistent “Missing approval note” field
and selected “Unrelated notes” instead. The selected probabilities were about
0.880 and 0.611. A threshold could reject these particular errors, but deriving
one from these test outcomes would not establish calibrated safety. The raw
errors are retained; application-side eligibility, freshness, approvals, and
independent verification remain necessary.

Live fixtures each ran three scenes with one fill and one click, using scripted
planner steps and an independent fixture-state oracle. These are six logical
instructions repeated on two surfaces, not twelve different multi-step tasks.
Old-capability probes were refused without changing fixture fields. The native
refusal explicitly reported a stale token; the browser reported route refusal
for the superseded ref. Each run closed only its owned fixture process.

Driver action medians were 3.64 seconds in the browser and 2.51 seconds natively.
This demonstrates a fast chooser, not the plan's sub-second voice-to-action
target. App/URL templates, intent extraction, multilingual grounding, and
real-command success remain unmeasured.

The patched jev-use loop also finished with `verified` via its independent
`/state` endpoint. The second CPU decision, including observation, took 143.6 ms;
the first included about 4.8 seconds of startup. An initial callback smoke with
the upstream's generic descriptions requested `reobserve` at submit. The final
bridge uses explicit operation/control/value descriptions and an explicit
current-step goal from fixture state, as required by this checkpoint. This
compatibility adjustment is separate from the unchanged 100-case evaluation.

## Reproduce

Follow [the experiment setup](../scripts/gliner/README.md) for the pinned
environment and standalone chooser. After installing its requirements:

```sh
.build/gliner-proof/venv/bin/python scripts/gliner/evaluate_grounder.py --device mps --output .build/gliner-proof/custom-eval-mps.json
.build/gliner-proof/venv/bin/python scripts/gliner/evaluate_grounder.py --device cpu --output .build/gliner-proof/custom-eval-cpu.json
.build/gliner-proof/venv/bin/python scripts/gliner/benchmark.py .build/gliner-proof/cua --output .build/gliner-proof/custom-latency.json
```

The installed package reproduces its published test and owned live fixtures.
Use fresh output paths; existing run directories are not overwritten:

```sh
.build/gliner-proof/venv/bin/gliner-cua cua-data --output .build/gliner-proof/published-data --seed 42
.build/gliner-proof/venv/bin/gliner-cua cua-evaluate --data .build/gliner-proof/published-data/test.jsonl --model lucataco/gliner2.5-cua-grounder-macos-v1 --revision 571da5981b95e29cbcc6b4fdefb0f07ac1bf9144 --device mps --max-tokens 4096 --threads 8 --output .build/gliner-proof/published-test
.build/gliner-proof/venv/bin/gliner-cua cua-live --surface browser --scene-set confirmation --model lucataco/gliner2.5-cua-grounder-macos-v1 --revision 571da5981b95e29cbcc6b4fdefb0f07ac1bf9144 --device mps --max-tokens 4096 --threads 8 --output .build/gliner-proof/browser-proof
.build/gliner-proof/venv/bin/gliner-cua cua-live --surface native --scene-set confirmation --model lucataco/gliner2.5-cua-grounder-macos-v1 --revision 571da5981b95e29cbcc6b4fdefb0f07ac1bf9144 --device mps --max-tokens 4096 --threads 8 --output .build/gliner-proof/native-proof
```

No hosted Jev requests or training jobs were run. Real-user transcripts were
not exported. Public aggregate evidence and the two synthetic misses are in
[custom-grounder-evaluation.json](custom-grounder-evaluation.json).

## Evaluation checks (before app integration)

- Superkeet Python suite: 27 passed.
- Pinned `gliner-cua` package suite: 59 passed, 2 optional model tests skipped.
- Standalone JSONL worker: offline valid requests, forbidden-field rejection,
  64 KB rejection, 4,096-token rejection, and subsequent-request recovery passed.
- Upstream `choose_action.py --gliner`: selected `submit-form` offline.
- Patched jev-use live loop: verified fill and submit; 12 upstream core tests passed.
- Pinned requirements installed successfully in a clean Python 3.12 environment.
- Strict SwiftLint and whitespace checks passed. No Swift files changed in this
  retry; the previous debug/release builds and Swift tests are recorded in the
  historical report.

## App integration checks

- Debug and release Swift builds passed.
- Swift suite: 357 tests, 5 optional integration tests skipped, zero failures.
  The run enabled the real-model smoke test with the pinned Python environment;
  Swift successfully warmed the offline MPS worker and selected the expected ID.
- The deterministic MCP fixture preserved complete structured observations
  independently of the text summary. Router tests covered approval-time target
  changes, renewed tokens, cancellation, and redacted audit metadata.
- Strict SwiftLint: zero violations. Python suite: 27 passed. Installer and
  packaging scripts passed shell syntax checks; `git diff --check` passed.

The app integration has automated fixture coverage and an offline model smoke;
the live native/browser results above remain the separate evaluation harness runs.
