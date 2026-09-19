"""Run Phase 0 synthetic intent/slot and bounded click-choice quality gates."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import statistics
import sys
import time

from gliner_adapter import BASE_MODELS, choose_bounded, load_model
from synthetic_cases import GROUPS, intent_cases

SLOT_DESCRIPTIONS = {
    "app": "Name of a non-browser application to operate, such as Calculator or Notes.",
    "browser": "Name of the web browser explicitly requested by the user, such as Safari or Helium.",
    "url": "Website URL or domain to navigate to, only for a navigation command.",
    "query": "Words to search for on the web, excluding the search instruction.",
    "target": "Label of the UI element to click or fill, or keyboard key to press.",
    "text": "Exact text to type or enter, excluding the instruction and destination.",
}


def intent_schema(model):
    schema = model.create_schema().structure("command").field(
        "action", dtype="str", choices=list(GROUPS),
        description="The requested action. Use open_url for opening a website, even when a browser is also named."
    )
    for name, description in SLOT_DESCRIPTIONS.items():
        schema = schema.field(name, dtype="str", description=description)
    return schema


def slot_pairs(record):
    return {(name, value.strip().casefold()) for name in SLOT_DESCRIPTIONS
            if isinstance(value := record.get(name), str) and value.strip()}


def evaluate(model_id, device, output):
    model = load_model(model_id, device)
    schema = intent_schema(model)
    correct = true_positive = false_positive = false_negative = 0
    timings, details = [], []
    for case in intent_cases():
        started = time.perf_counter()
        result = model.extract(case["text"], schema)
        timings.append((time.perf_counter() - started) * 1000)
        records = result.get("command", [])
        record = records[0] if len(records) == 1 else {}
        correct += record.get("action") == case["action"]
        expected, actual = slot_pairs(case["slots"]), slot_pairs(record)
        true_positive += len(expected & actual)
        false_positive += len(actual - expected)
        false_negative += len(expected - actual)
        details.append({**case, "predicted": record})
    denominator = 2 * true_positive + false_positive + false_negative
    slot_f1 = 2 * true_positive / denominator if denominator else 1.0

    click_details = []
    labels = ["Save", "Cancel", "Submit", "Continue", "Done", "Close", "Search", "Next", "Back", "Settings"]
    for index in range(30):
        target = labels[index % len(labels)]
        ambiguous = index >= 20
        alternatives = [target, labels[(index + 1) % 10], labels[(index + 2) % 10]]
        rotation = index % 3
        alternatives = alternatives[rotation:] + alternatives[:rotation]
        app = "Notes" if index < 10 else "Safari"
        # Mirror the template boundary: ambiguity withholds executable candidates.
        criteria = {} if ambiguous else {
            f"element-{offset}": f"Click the {label} button in {app}."
            for offset, label in enumerate(alternatives)
        }
        criteria.update(reobserve="Get a fresh observation.", abstain="Stop if no supplied action is safe.")
        regions = [f"Button: {target}", f"Button: {target}"] if ambiguous else [f"Button: {label}" for label in alternatives]
        result = choose_bounded(goal=f"Click {target} in {app}", observation={"app": app, "elements": regions}, criteria=criteria, model=model, model_id=model_id)
        expected_id = f"element-{alternatives.index(target)}"
        passed = result.selected_id in {"reobserve", "abstain"} if ambiguous else result.selected_id == expected_id
        click_details.append({"target": target, "app": app, "ambiguous": ambiguous, "passed": passed, **vars(result)})
    click_accuracy = sum(item["passed"] for item in click_details[:20]) / 20
    ambiguous_safe = all(item["passed"] for item in click_details[20:])
    summary = {
        "model": model_id, "device": device, "dataset": "synthetic-v1", "intent_count": len(details),
        "action_accuracy": correct / len(details), "slot_micro_f1": slot_f1,
        "intent_warm_p50_ms": statistics.median(timings[1:]),
        "click_top1": click_accuracy, "ambiguous_safe": ambiguous_safe,
        "passed_quality_gate": correct / len(details) >= 0.9 and slot_f1 >= 0.85 and click_accuracy >= 0.9 and ambiguous_safe,
        "real_command_accuracy_verified": False,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"summary": summary, "intent_cases": details, "click_cases": click_details}, indent=2) + "\n")
    sys.stdout.write(json.dumps(summary) + "\n")
    sys.stdout.flush()
    load_model.cache_clear()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--model", choices=BASE_MODELS)
    args = parser.parse_args()
    for model_id in [args.model] if args.model else BASE_MODELS:
        evaluate(model_id, args.device, args.output_dir / f"{model_id.split('/')[-1]}.json")
