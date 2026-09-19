# Custom GLiNER bounded-choice experiment

This is the Phase 0 provider and evaluation harness for `PLAN.md`. The default
is `lucataco/gliner2.5-cua-grounder-macos-v1`, pinned to
`571da5981b95e29cbcc6b4fdefb0f07ac1bf9144`, using `gliner-cua` code at
`b0a822ff90a6827247847dc40cd927b4be4f308a`. It supplies a runnable resident
chooser used by the optional native-grounding app integration (setup below).
See [results and implementation status](../../docs/custom-grounder-evaluation.md).

The adapter adds `--provider gliner` and `choose_action.py --gliner` to Cua's
jev-use example at commit `201732fffd81a40818be7ce2e04269aec962bc42`.
`prepare_proof.py` requires that exact commit and unmodified example sources.
It fails on drift or repeated installation rather than overwriting work.
The custom bridge also gives the fixture's fill/click candidates explicit
operation, value, and control descriptions. Their IDs, tools, and arguments
are preserved. The loop supplies a `goal=` keyword containing the current
fixture step; calling the custom callback without it fails before loading.

## Set up a fresh experiment

Run from the Superkeet repository root. Downloads and private results stay
under the ignored `.build/` directory; Hugging Face uses its normal local cache.
The pinned requirements were tested on Apple Silicon, Python 3.12, macOS 27,
and Cua Driver 0.28.2. Install Cua Driver separately before the live proof.

```sh
git clone --depth 1 --filter=blob:none --no-checkout https://github.com/trycua/cua.git .build/gliner-proof/cua
git -C .build/gliner-proof/cua fetch --depth 1 origin 201732fffd81a40818be7ce2e04269aec962bc42
git -C .build/gliner-proof/cua sparse-checkout set libs/cua-driver/examples/jev-use
git -C .build/gliner-proof/cua checkout --detach 201732fffd81a40818be7ce2e04269aec962bc42
uv venv --python 3.12 .build/gliner-proof/venv
uv pip sync --python .build/gliner-proof/venv/bin/python scripts/gliner/requirements.txt
python3 scripts/gliner/prepare_proof.py .build/gliner-proof/cua
```

GLiNER2.5 needs `AutoExtractor`, not the legacy `GLiNER2` loader. `protobuf`
and `sentencepiece` are explicitly installed: without protobuf, Transformers
masks the exception that GLiNER's tokenizer compatibility loader handles.
The provider pins each checkpoint revision, downloads only runtime files,
loads from the resulting local snapshot, and caches one model per process.
Model/dependency messages go to stderr so stdout remains valid JSON.

## Contract proof and live browser proof

The first command downloads the custom merged model (about 1.17 GB) if it is not cached. Subsequent runs can set
`SUPERKEET_GLINER_OFFLINE=1` to prohibit Hub downloads. No inference API is used.

```sh
.build/gliner-proof/venv/bin/python .build/gliner-proof/cua/libs/cua-driver/examples/jev-use/python/choose_action.py --gliner < .build/gliner-proof/cua/libs/cua-driver/examples/jev-use/fixtures/jev-choice-request-v1.json
```

For the live proof, start this server in a separate terminal:

```sh
.build/gliner-proof/venv/bin/python .build/gliner-proof/cua/libs/cua-driver/examples/jev-use/fixture_server.py --port 18765
```

Then run the mock and local providers sequentially; each resets the fixture
and creates an isolated browser profile. Do not run them against the same
fixture simultaneously. Stop the fixture server with Ctrl-C when finished.

```sh
.build/gliner-proof/venv/bin/python .build/gliner-proof/cua/libs/cua-driver/examples/jev-use/python/run.py --provider mock --fixture-url http://127.0.0.1:18765 --log .build/gliner-proof/mock.jsonl
.build/gliner-proof/venv/bin/python .build/gliner-proof/cua/libs/cua-driver/examples/jev-use/python/run.py --provider gliner --fixture-url http://127.0.0.1:18765 --log .build/gliner-proof/custom-grounder-cpu.jsonl
```

The original loop owns candidates, validates the selected ID, executes at most
one candidate per round, and checks the fixture's independent `/state` endpoint.
Only IDs and descriptions cross the model boundary. The custom callback supplies
one scripted current fixture step (fill, then submit), using its exact trained
serializer and instruction. This is not a demonstration of task planning. The live example is a
synthetic experiment; its lack of a calibrated confidence threshold is not an
app execution policy.

Environment options:

- `SUPERKEET_GLINER_MODEL`: `lucataco/gliner2.5-cua-grounder-macos-v1` (default).
  Historical baselines: `fastino/gliner2.5-small-v1`,
  `fastino/gliner2.5-base-v1`, or `fastino/gliner2.5-multi-v1`.
- `SUPERKEET_GLINER_DEVICE`: `cpu` (default) or `mps`.
- `SUPERKEET_GLINER_OFFLINE=1`: require already cached checkpoint files.

## Resident chooser

The standalone runner does not need a Cua checkout and never executes actions:

```sh
.build/gliner-proof/venv/bin/python scripts/gliner/serve_grounder.py --jsonl --device mps
```

Send one compact `cua.jev_choice_request_v1` JSON object per line. The process
loads the model once, validates each request, and returns `cua.jev_choice_v1`
with the checkpoint ID. Invalid lines return `cua.chooser_error_v1`; the next
line is still processed. Omit `--jsonl` for one request on stdin. After download,
`SUPERKEET_GLINER_OFFLINE=1` enforces cached-only loading.

The custom model uses the package's exact `driver_action` instruction,
`planner_step` serializer, ordered opaque labels and escaping, FP32 logits and
temperature-1 softmax. Requests exceeding 64 KB or 4,096 encoded tokens are
rejected without dropping candidates. `confidence` is the selected softmax
probability; it is not the old adapter's independent sigmoid score.

## Evaluate and test

```sh
.build/gliner-proof/venv/bin/python scripts/gliner/benchmark.py .build/gliner-proof/cua --output .build/gliner-proof/benchmark.json
.build/gliner-proof/venv/bin/python scripts/gliner/evaluate_grounder.py --output .build/gliner-proof/custom-eval.json
python3 -m unittest discover -s scripts -p 'test_*.py'
```

The benchmark measures 20 warm decisions after a discarded warm-up on each
device combination for the custom model. Repeat `--model` to benchmark other checkpoints. It also exercises the ambiguous visual fixture.
These are model-only times; use the live JSONL for observation-inclusive times.

`evaluate_grounder.py` uses 100 separate Superkeet grounding cases, with twenty
each for clicking, typing, section disambiguation, absent targets, and loading
observations. Candidate positions are shuffled with a fixed seed; all menus,
including wrong-value and wrong-operation distractors, remain intact. The new
smoke gate requires at least 90% per category; errors count as failures and make
the script exit nonzero. Results include the dataset hash and both code/model
revisions. These cases use scripted current instructions, not raw voice commands.
The final dataset corrected a pilot annotation ambiguity: an unqualified field
request had two equally matching controls. The pilot and correction are recorded
in the evaluation report; the held-out quality claims remain limited to synthetic
cases, and no thresholds or model parameters were tuned to the results.

The historical `evaluate.py` (base checkpoints only) uses 100 hand-authored synthetic commands, balanced
across the ten action classes, plus 30 synthetic click tables. Twenty click
tables include distractors and rotated candidate positions; ten ambiguous
tables offer only `reobserve` and `abstain`. This verifies the candidate builder's
ambiguity boundary, not learned ambiguity detection. Intent extraction uses
one fixed structure schema with a closed action field and described entity
slots. Slot scoring is micro F1 over exact `(slot, case-folded source span)`
pairs; browser names belong in `browser`, not also in `app`. Extra slots count
as false positives. Unsupported actions must select `other`.

Results are deliberately separate from unit tests: the custom quality gate is
recorded in `passed_grounding_gate`, and the historical intent/slot gate in
`passed_quality_gate`, rather than being hidden by a passing mock test.
No transcripts or actual user screen contents are committed. These synthetic
English cases do not establish real-command or multilingual accuracy.

The upstream contract tests additionally need the example's TypeSafe SDK
(`typesafe-sdk==0.6.0`); the GLiNER provider does not require it or an API key.
## App runtime integration

From the repository root, install the pinned app runtime with
`bash scripts/install_grounder.sh` (Python 3.12 required). Then enable the
experimental native grounder in Settings ▸ Actions and check/warm the runtime.
See [Actions Mode](../../docs/actions-mode.md#native-ui-grounder-experimental)
for supported command templates, approval behavior, and verification limits.

The Swift worker's optional offline smoke test uses the installed environment:

```bash
SUPERKEET_TEST_GROUNDER_PYTHON="$HOME/Library/Application Support/Superkeet/Grounder/venv/bin/python3" \
  swift test --filter GLiNERChooserTests/testInstalledModelSmokeWhenRequested
```
