"""Dependency-free contract tests; no model download or desktop interaction."""
import math
import unittest
from unittest.mock import patch

from gliner.gliner_adapter import BASE_MODELS, GROUNDING_MODEL, choose_bounded, choose_live
from gliner.prepare_proof import replace_once
from gliner.synthetic_cases import GROUPS, intent_cases
from gliner.grounding_cases import grounding_cases


class FakeModel:
    def __init__(self, result):
        self.result = result
        self.request = None

    def classify_text(self, text, tasks, **kwargs):
        self.request = (text, tasks, kwargs)
        return self.result


class GLiNERAdapterTests(unittest.TestCase):
    criteria = {"submit": "Submit the form", "reobserve": "Observe again", "abstain": "Stop"}

    def choose(self, scores):
        model = FakeModel({"candidate": [
            {"label": label, "confidence": score} for label, score in zip(self.criteria.values(), scores)
        ]})
        return choose_bounded(goal="Submit", observation={}, criteria=self.criteria, model=model, model_id=BASE_MODELS[0])

    def test_selects_supplied_id_and_normalizes_full_vector(self):
        result = self.choose([0.8, 0.1, 0.1])
        self.assertEqual(result.selected_id, "submit")
        self.assertAlmostEqual(sum(result.probabilities.values()), 1)
        self.assertEqual(result.confidence, 0.8)

    def test_reserved_candidates_can_win(self):
        self.assertEqual(self.choose([0.1, 0.8, 0.1]).selected_id, "reobserve")
        self.assertEqual(self.choose([0.1, 0.1, 0.8]).selected_id, "abstain")

    def test_ties_reobserve(self):
        self.assertEqual(self.choose([0.9, 0.1, 0.9]).selected_id, "reobserve")

    def test_invalid_scores_fail_closed(self):
        for scores in ([0, 0, 0], [math.nan, 0, 1], [math.inf, 0, 1], [-1, 0, 1], [2, 0, 1], [True, 0, 1]):
            with self.subTest(scores=scores), self.assertRaises(ValueError):
                self.choose(scores)

    def test_unknown_duplicate_and_missing_labels_fail_closed(self):
        for labels in ([], ["Invented", "Observe again", "Stop"], ["Stop", "Stop", "Submit the form"]):
            model = FakeModel({"candidate": [{"label": label, "confidence": 0.5} for label in labels]})
            with self.subTest(labels=labels), self.assertRaises(ValueError):
                choose_bounded(goal="Submit", observation={}, criteria=self.criteria, model=model, model_id=BASE_MODELS[0])

    def test_duplicate_descriptions_fail_closed(self):
        with self.assertRaises(ValueError):
            choose_bounded(goal="Submit", observation={}, criteria={"reobserve": "same", "abstain": "same"}, model_id=BASE_MODELS[0])

    def test_missing_reserved_ids_fail_closed(self):
        with self.assertRaises(ValueError):
            choose_bounded(goal="Submit", observation={}, criteria={"submit": "Submit", "abstain": "Stop"}, model_id=BASE_MODELS[0])

    def test_patch_rejects_drift(self):
        self.assertEqual(replace_once("one two", "one", "three"), "three two")
        for source in ("missing", "one one"):
            with self.assertRaises(ValueError):
                replace_once(source, "one", "three")

    def test_synthetic_cases_have_unique_ids_and_literal_slot_annotations(self):
        cases = intent_cases()
        self.assertEqual(len(cases), 100)
        self.assertEqual(len({case["id"] for case in cases}), 100)
        self.assertTrue(all(len(group) == 10 for group in GROUPS.values()))
        for case in cases:
            for value in case["slots"].values():
                self.assertIn(value, case["text"])


class FakeGrounder:
    def __init__(self, selected="submit", probabilities=None):
        self.selected = selected
        self.probabilities = probabilities or {"submit": 0.9, "reobserve": 0.05, "abstain": 0.05}
        self.request = None
        self.context = None

    def choose(self, request, *, semantic_context=None):
        self.request, self.context = request, semantic_context
        return {"schema": "cua.jev_choice_v1", "selected_id": self.selected, "model": "fixture",
                "confidence": 0.9, "probabilities": self.probabilities}


class CustomGrounderTests(unittest.TestCase):
    def test_live_callback_requires_planner_step_before_loading(self):
        with patch.dict("os.environ", {"SUPERKEET_GLINER_MODEL": GROUNDING_MODEL}):
            with self.assertRaisesRegex(ValueError, "planner step"):
                choose_live([], {}, None, [])

    def test_preserves_current_step_and_candidate_order(self):
        model = FakeGrounder()
        criteria = {"abstain": "Stop", "submit": "Click Submit", "reobserve": "Observe again"}
        choice = choose_bounded(goal="Click Submit", observation={"capture_id": "capture-7", "page": "Fixture"},
                                criteria=criteria, model=model)
        self.assertEqual(choice.model, GROUNDING_MODEL)
        self.assertEqual(choice.selected_id, "submit")
        self.assertEqual(model.request["goal"], "Click Submit")
        self.assertEqual(model.request["capture_id"], "capture-7")
        self.assertEqual([candidate["id"] for candidate in model.request["candidates"]], list(criteria))
        self.assertEqual(set(model.request), {"schema", "goal", "capture_id", "regions", "history", "candidates"})
        self.assertEqual(model.context, {"page": "Fixture"})
        self.assertTrue(all(set(candidate) == {"id", "description"} for candidate in model.request["candidates"]))

    def test_preserves_duplicate_descriptions_with_distinct_ids(self):
        model = FakeGrounder(probabilities={"a": 0.4, "b": 0.4, "reobserve": 0.1, "abstain": 0.1}, selected="a")
        criteria = {"a": "Click Submit", "b": "Click Submit", "reobserve": "Observe", "abstain": "Stop"}
        choice = choose_bounded(goal="Click Submit", observation={}, criteria=criteria, model=model)
        self.assertEqual(set(choice.probabilities), set(criteria))
        self.assertEqual(len(model.request["candidates"]), 4)

    def test_invalid_provider_output_cannot_become_a_choice(self):
        criteria = {"submit": "Click Submit", "reobserve": "Observe", "abstain": "Stop"}
        for model in [
            FakeGrounder(selected="invented"),
            FakeGrounder(probabilities={"submit": 1}),
            FakeGrounder(probabilities={"submit": math.nan, "reobserve": 0, "abstain": 0}),
            FakeGrounder(probabilities={"submit": 0.1, "reobserve": 0.1, "abstain": 0.1}),
            FakeGrounder(probabilities={"submit": True, "reobserve": 0, "abstain": 0}),
        ]:
            with self.subTest(model=model), self.assertRaises(ValueError):
                choose_bounded(goal="Click Submit", observation={}, criteria=criteria, model=model)

    def test_grounding_cases_are_deterministic_and_keep_negative_choices(self):
        cases = grounding_cases()
        self.assertEqual(cases, grounding_cases())
        self.assertEqual(len(cases), 100)
        self.assertEqual(len({case["id"] for case in cases}), 100)
        for kind in ("click", "type", "section", "abstain", "reobserve"):
            self.assertEqual(sum(case["kind"] == kind for case in cases), 20)
        positions = set()
        for case in cases:
            ids = [candidate["id"] for candidate in case["request"]["candidates"]]
            self.assertTrue({"abstain", "reobserve"} <= set(ids))
            self.assertEqual(len(ids), len(set(ids)))
            self.assertTrue(set(case["positive_ids"]) <= set(ids))
            self.assertGreaterEqual(len(ids), 6)
            positions.add(ids.index(case["positive_ids"][0]))
        self.assertGreater(len(positions), 4)


if __name__ == "__main__":
    unittest.main()
