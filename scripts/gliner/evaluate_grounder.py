"""Evaluate the custom grounder on fixed Superkeet menus, with no menu filtering."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import statistics
import sys
import time

from gliner_adapter import GROUNDING_CODE_REVISION, GROUNDING_MODEL, GROUNDING_REVISION, grounded_choice, load_model
from grounding_cases import grounding_cases


def evaluate(device, output):
    cases = grounding_cases()
    dataset_hash = hashlib.sha256(json.dumps(cases, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    model = load_model(GROUNDING_MODEL, device)
    totals, correct = Counter(), Counter()
    timings, details = [], []
    for case in cases:
        started = time.perf_counter()
        totals[case["kind"]] += 1
        detail = {**case}
        try:
            choice = grounded_choice(case["request"], model=model, device=device)
            passed = choice.selected_id in case["positive_ids"]
            correct[case["kind"]] += passed
            detail.update(response=vars(choice), passed=passed)
        except Exception as error:
            detail.update(error=f"{type(error).__name__}: {error}", passed=False)
        timings.append((time.perf_counter() - started) * 1000)
        details.append(detail)
    summary = {
        "model": GROUNDING_MODEL, "revision": GROUNDING_REVISION, "code_revision": GROUNDING_CODE_REVISION,
        "device": device, "dataset": "superkeet-grounding-v1", "dataset_sha256": dataset_hash,
        "count": len(cases), "correct": sum(correct.values()), "accuracy": sum(correct.values()) / len(cases),
        "by_kind": {kind: {"correct": correct[kind], "count": count} for kind, count in totals.items()},
        "warm_p50_ms": statistics.median(timings[1:]),
        "warm_p95_ms": sorted(timings[1:])[int(len(timings[1:]) * 0.95)],
        "errors": sum("error" in detail for detail in details),
        "passed_grounding_gate": all(correct[kind] / count >= 0.9 for kind, count in totals.items()),
        "intent_extraction_evaluated": False, "real_command_accuracy_verified": False,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"summary": summary, "cases": details}, indent=2) + "\n")
    sys.stdout.write(json.dumps(summary, indent=2) + "\n")
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", choices=("cpu", "mps"), default="mps")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = evaluate(args.device, args.output)
    raise SystemExit(0 if result["passed_grounding_gate"] else 1)
