"""Local GLiNER2.5 provider for the pinned jev-use Phase 0 experiment.

Only descriptions cross the model boundary. Executable actions remain in the
caller's immutable candidate table and are resolved by core.validate_choice.
"""
from __future__ import annotations

import contextlib
import functools
import json
import math
import os
import sys
from dataclasses import dataclass
from typing import Any, Mapping

GROUNDING_MODEL = "lucataco/gliner2.5-cua-grounder-macos-v1"
GROUNDING_REVISION = "571da5981b95e29cbcc6b4fdefb0f07ac1bf9144"
GROUNDING_CODE_REVISION = "b0a822ff90a6827247847dc40cd927b4be4f308a"
DEFAULT_MODEL = GROUNDING_MODEL
BASE_MODELS = tuple(f"fastino/gliner2.5-{size}-v1" for size in ("small", "base", "multi"))
MODELS = (*BASE_MODELS, GROUNDING_MODEL)
MODEL_REVISIONS = {
    MODELS[0]: "f1e4d8fdd6fe328f45dee6aca3e6a07c9db4296e",
    MODELS[1]: "78cea040597df251eedefa9d7ee2a756af39fe64",
    MODELS[2]: "235cf92d6d4318da9bfca0d08975c8fa7250d13b",
    GROUNDING_MODEL: GROUNDING_REVISION,
}


@dataclass(frozen=True)
class ProviderChoice:
    selected_id: str
    confidence: float
    probabilities: dict[str, float]
    model: str


@functools.lru_cache(maxsize=1)
def load_model(model_id: str, device: str) -> Any:
    if model_id not in MODELS or device not in {"cpu", "mps"}:
        raise ValueError("unsupported model or device")
    # Keep dependency and model diagnostics off the JSON protocol's stdout.
    with contextlib.redirect_stdout(sys.stderr):
        from gliner2 import AutoExtractor
        from huggingface_hub import snapshot_download

        directory = snapshot_download(
            model_id, revision=MODEL_REVISIONS[model_id],
            allow_patterns=["*.json", "encoder_config/*.json", "model.safetensors", "spm.model"],
            local_files_only=os.environ.get("SUPERKEET_GLINER_OFFLINE") == "1",
        )
        if model_id == GROUNDING_MODEL:
            from gliner_cua.cua_chooser import LocalCUAChooser

            # Use the training serializer, opaque labels, instruction, token
            # budget and softmax scorer from the pinned code package unchanged.
            return LocalCUAChooser(directory, device=device, max_tokens=4096, threads=8)
        model = AutoExtractor.from_pretrained(directory, map_location=device, local_files_only=True)
        model.eval()
    return model


def grounded_choice(request, *, model=None, device="cpu", semantic_context=None) -> ProviderChoice:
    if model is None:
        model = load_model(GROUNDING_MODEL, device)
    with contextlib.redirect_stdout(sys.stderr):
        response = model.choose(request, semantic_context=semantic_context)
    criteria = {item["id"]: item["description"] for item in request["candidates"]}
    probabilities = response.get("probabilities")
    confidence = response.get("confidence")
    if response.get("schema") != "cua.jev_choice_v1" or response.get("selected_id") not in criteria:
        raise ValueError("grounder returned invalid schema or unknown choice")
    if not isinstance(probabilities, dict) or set(probabilities) != set(criteria):
        raise ValueError("grounder did not score exactly the supplied candidates")
    values = [confidence, *probabilities.values()]
    if any(type(value) not in (float, int) or not math.isfinite(value) or not 0 <= value <= 1 for value in values):
        raise ValueError("grounder returned invalid probabilities")
    if not math.isclose(sum(probabilities.values()), 1, abs_tol=1e-6):
        raise ValueError("grounder probabilities do not sum to one")
    return ProviderChoice(response["selected_id"], confidence, probabilities, GROUNDING_MODEL)


def choose_bounded(
    *,
    goal: str,
    observation: Mapping[str, Any],
    criteria: Mapping[str, str],
    model: Any = None,
    model_id: str = DEFAULT_MODEL,
    device: str = "cpu",
) -> ProviderChoice:
    """Use the fine-tune's grounding interface, or the historical base scorer.

    For the historical baseline, the single-label API returns only the winning score. Multi-label
    classification with threshold zero exposes every score without inventing
    probabilities for the other labels. These scores are not calibrated action
    safety probabilities; callers must still validate and verify every action.
    """
    if model_id == GROUNDING_MODEL:
        request = {
            "schema": "cua.jev_choice_request_v1", "goal": goal,
            "capture_id": observation.get("capture_id", "semantic-evaluation"),
            "regions": observation.get("regions", []), "history": observation.get("history", []),
            "candidates": [{"id": key, "description": value} for key, value in criteria.items()],
        }
        context = {key: value for key, value in observation.items() if key not in {"capture_id", "regions", "history"}}
        return grounded_choice(request, model=model, device=device, semantic_context=context or None)
    labels = list(criteria.values())
    if not 2 <= len(labels) <= 32 or not {"reobserve", "abstain"} <= criteria.keys():
        raise ValueError("invalid candidate table")
    if any(not isinstance(label, str) or not label.strip() or len(label) > 1000 for label in labels):
        raise ValueError("invalid candidate description")
    if len(set(labels)) != len(labels):
        raise ValueError("candidate descriptions must be distinct")
    text = f"Goal: {goal}\nObservation: {json.dumps(observation, ensure_ascii=False, sort_keys=True)}"
    if model is None:
        model = load_model(model_id, device)
    with contextlib.redirect_stdout(sys.stderr):
        result = model.classify_text(
            text,
            {"candidate": {"labels": labels, "multi_label": True, "cls_threshold": 0.0}},
            include_confidence=True,
            threshold=0.0,
        )
    rows = result.get("candidate") if isinstance(result, dict) else None
    if not isinstance(rows, list) or len(rows) != len(labels):
        raise ValueError("model did not return every candidate score")
    scores: dict[str, float] = {}
    for row in rows:
        if not isinstance(row, dict) or row.get("label") not in labels or row["label"] in scores:
            raise ValueError("model returned unknown or duplicate label")
        score = row.get("confidence")
        if isinstance(score, bool) or not isinstance(score, (int, float)) or not math.isfinite(score):
            raise ValueError("model returned invalid score")
        if not 0 <= score <= 1:
            raise ValueError("model returned out-of-range score")
        scores[row["label"]] = float(score)
    total = sum(scores.values())
    if total <= 0:
        raise ValueError("model returned zero score mass")
    probabilities = {key: scores[label] / total for key, label in criteria.items()}
    selected = max(probabilities, key=probabilities.get)
    # An exact tie supplies no basis for a mutation, independent of label order.
    if sum(value == probabilities[selected] for value in probabilities.values()) > 1:
        selected = "reobserve"
    return ProviderChoice(selected, scores[criteria[selected]], probabilities, model_id)


def choose_request(request: Mapping[str, Any], *, model: Any = None) -> dict[str, Any]:
    from choose_action import RESPONSE_SCHEMA, validate_request

    validated = validate_request(dict(request))
    choice = choose_bounded(
        goal=validated["goal"],
        observation={key: validated[key] for key in ("capture_id", "regions", "history")},
        criteria={item["id"]: item["description"] for item in validated["candidates"]},
        model=model,
        model_id=os.environ.get("SUPERKEET_GLINER_MODEL", DEFAULT_MODEL),
        device=os.environ.get("SUPERKEET_GLINER_DEVICE", "cpu"),
    )
    return {"schema": RESPONSE_SCHEMA, **vars(choice)}


def choose_live(candidates, snapshot, visual, history, *, goal=None):
    model_id = os.environ.get("SUPERKEET_GLINER_MODEL", DEFAULT_MODEL)
    device = os.environ.get("SUPERKEET_GLINER_DEVICE", "cpu")
    if model_id == GROUNDING_MODEL:
        # The fixture planner supplies one step; this is not a general-purpose
        # replacement for task decomposition or intent extraction.
        if not goal:
            raise ValueError("The custom grounder requires an explicit current planner step")
        from gliner_cua.cua_chooser import jev_use_adapter

        return jev_use_adapter(load_model(model_id, device), goal)(candidates, snapshot, visual, history)
    from jev_adapter import visual_decision_state

    criteria = {candidate.id: candidate.description for candidate in candidates}
    if len(criteria) != len(candidates):
        raise ValueError("duplicate candidate IDs")
    choice = choose_bounded(
        goal=goal or "Enter the verification token, then submit the form.",
        observation={
            "page": snapshot.get("page"),
            "outline": snapshot.get("outline"),
            "visual": visual_decision_state(visual),
            "history": [
                {"selected_id": item.get("candidate"), "outcome": item.get("event")}
                for item in history[-16:]
            ],
        },
        criteria=criteria,
        model_id=os.environ.get("SUPERKEET_GLINER_MODEL", DEFAULT_MODEL),
        device=os.environ.get("SUPERKEET_GLINER_DEVICE", "cpu"),
    )
    return choice.selected_id, choice.confidence, choice.probabilities
