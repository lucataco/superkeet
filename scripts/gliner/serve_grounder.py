"""Run the pinned custom grounder as a one-shot or resident JSONL chooser.

No Driver actions are executed here. The caller owns and validates the table.
"""
import argparse

from gliner_adapter import GROUNDING_MODEL, grounded_choice, load_model


class Grounder:
    def __init__(self, device):
        self.model = load_model(GROUNDING_MODEL, device)

    def choose(self, raw):
        from gliner_cua.cua_contract import parse_request

        request = parse_request(raw).wire()
        choice = grounded_choice(request, model=self.model)
        return {"schema": "cua.jev_choice_v1", **vars(choice)}


if __name__ == "__main__":
    from gliner_cua.cua_chooser import serve

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", choices=("cpu", "mps"), default="cpu")
    parser.add_argument("--jsonl", action="store_true")
    args = parser.parse_args()
    serve(Grounder(args.device), jsonl=args.jsonl)
