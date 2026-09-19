"""Measure real GLiNER decisions against the pinned synthetic contract fixtures."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import sys
import time

from gliner_adapter import DEFAULT_MODEL, MODELS, MODEL_REVISIONS, choose_bounded, load_model
from prepare_proof import EXAMPLE


def benchmark(checkout: Path, output: Path, iterations: int, models: list[str]) -> None:
    example = checkout / EXAMPLE
    sys.path.insert(0, str(example / "python"))
    from core import build_candidates, parse_visual_regions, validate_choice

    request = json.loads((example / "fixtures/jev-choice-request-v1.json").read_text())
    payload = json.loads((example / "fixtures/parse-visual-regions-ambiguous-v1.json").read_text())
    visual = parse_visual_regions(payload, expected_capture_id="capture-ambiguous", expected_pid=7, expected_window_id=9)
    snapshot = {"target_id": "synthetic", "tab_id": "synthetic", "refs": [
        {"role": "textbox", "name": "verification value", "ref": "e1", "value": "expected"}
    ]}
    candidates = build_candidates(snapshot, "expected", visual, capture_bound_click=True)
    results = []
    for model_id in models:
        for device in ("cpu", "mps"):
            entry = {"model": model_id, "revision": MODEL_REVISIONS[model_id], "device": device, "iterations": iterations}
            try:
                start = time.perf_counter()
                model = load_model(model_id, device)
                entry["load_ms"] = (time.perf_counter() - start) * 1000
                timings = []
                choices = []
                for index in range(iterations + 1):
                    start = time.perf_counter()
                    result = choose_bounded(
                        goal=request["goal"],
                        observation={key: request[key] for key in ("capture_id", "regions", "history")},
                        criteria={item["id"]: item["description"] for item in request["candidates"]},
                        model=model, model_id=model_id, device=device,
                    )
                    elapsed = (time.perf_counter() - start) * 1000
                    if index:
                        timings.append(elapsed)
                        choices.append(result.selected_id)
                ambiguous = choose_bounded(
                    goal=request["goal"], observation={"regions": payload["regions"]},
                    criteria={candidate.id: candidate.description for candidate in candidates},
                    model=model, model_id=model_id, device=device,
                )
                validate_choice(ambiguous.selected_id, candidates, current_capture_id="capture-ambiguous")
                entry.update(
                    warm_p50_ms=statistics.median(timings),
                    warm_p95_ms=sorted(timings)[max(0, int(len(timings) * 0.95) - 1)],
                    submit_correct=sum(choice == "submit-form" for choice in choices),
                    ambiguous_selected=ambiguous.selected_id,
                    confidence=result.confidence,
                    probabilities=result.probabilities,
                )
                del model
            except Exception as error:
                entry["error"] = f"{type(error).__name__}: {error}"
            load_model.cache_clear()
            results.append(entry)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(results, indent=2) + "\n")
            sys.stdout.write(json.dumps(entry) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--model", choices=MODELS, action="append", help="Repeat to compare checkpoints; default is the fine-tune")
    args = parser.parse_args()
    if args.iterations < 1:
        parser.error("iterations must be positive")
    benchmark(args.checkout.resolve(), args.output, args.iterations, args.model or [DEFAULT_MODEL])
