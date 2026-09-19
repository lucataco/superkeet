"""Synthetic grounding regression suite, separate from the model's published corpus.

No model output is used to construct menus or expected choices. These are
scripted current steps, not tests of speech intent extraction or task planning.
"""
import random

CONTROLS = [
    ("Release headline", "Publish preview", "Orchard"),
    ("Archive shelf", "Index collection", "Maple"),
    ("Scene caption", "Render draft", "Sunrise"),
    ("Recipe annotation", "Save recipe", "Cinnamon"),
    ("Exhibit title", "Preview exhibit", "Mosaic"),
    ("Playlist note", "Queue selection", "Rainfall"),
    ("Invoice memo", "Review invoice", "Acorn"),
    ("Meeting topic", "Confirm agenda", "Sequoia"),
    ("Research label", "Export citations", "Cedar"),
    ("Delivery note", "Check delivery", "Willow"),
    ("Sketch name", "Duplicate sketch", "Harbor"),
    ("Project alias", "Inspect project", "Meadow"),
    ("Audio caption", "Preview audio", "Breeze"),
    ("Garden zone", "Save planting", "Fern"),
    ("Trip nickname", "Show itinerary", "Summit"),
    ("Batch label", "Validate batch", "Copper"),
    ("Catalog note", "Preview catalog", "Linen"),
    ("Journal heading", "Save journal", "Solstice"),
    ("Report subtitle", "Generate preview", "Brook"),
    ("Workspace label", "Apply layout", "Aspen"),
]


def grounding_cases():
    rows = []
    rng = random.Random(18092026)
    for index, (field, button, value) in enumerate(CONTROLS):
        for kind in ("click", "type", "section", "abstain", "reobserve"):
            if kind == "click":
                goal = f'Click the "{button}" button.'
                descriptions = [
                    (f'Click button "{button}"', True),
                    (f'Click button "Cancel {button}"', False),
                    (f'Type "{value}" into textbox "{field}"', False),
                    ('Click button "Help"', False),
                ]
            else:
                section = " in the Review section" if kind == "section" else ""
                other_field = (f'Type "{value}" into textbox "{field}" in the Draft section'
                               if kind == "section" else f'Type "{value}" into textbox "Previous {field}"')
                goal = f'Enter "{value}" in the "{field}" field{section}.'
                descriptions = [
                    (f'Type "{value}" into textbox "{field}"{section}', kind not in {"abstain", "reobserve"}),
                    (f'Type "Wrong value" into textbox "{field}"{section}', False),
                    (f'Click textbox "{field}"{section}', False),
                    (other_field, False),
                    (f'Type "{value}" into textbox "Unrelated notes"', False),
                ]
                if kind == "abstain":
                    goal = f'Enter "{value}" in the "Missing approval note" field.'
                elif kind == "reobserve":
                    goal += " The page is still loading and the observation is incomplete. Obtain a fresh observation first."
            descriptions += [
                ("Obtain a fresh observation because the current observation is incomplete or loading.", kind == "reobserve"),
                ("Do not act because no supplied action matches the planner instruction.", kind == "abstain"),
            ]
            menu = []
            positives = []
            for offset, (description, correct) in enumerate(descriptions):
                candidate_id = f"action-{index}-{offset}"
                if offset == len(descriptions) - 2:
                    candidate_id = "reobserve"
                elif offset == len(descriptions) - 1:
                    candidate_id = "abstain"
                menu.append({"id": candidate_id, "description": description})
                if correct:
                    positives.append(candidate_id)
            rng.shuffle(menu)
            rows.append({
                "id": f"superkeet-grounding-{kind}-{index}", "kind": kind,
                "request": {"schema": "cua.jev_choice_request_v1", "goal": goal,
                            "capture_id": f"capture-{kind}-{index}", "regions": [], "history": [],
                            "candidates": menu},
                "positive_ids": positives,
            })
    return rows
