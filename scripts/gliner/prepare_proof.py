"""Install the adapter into an unmodified, exact-SHA jev-use checkout."""
from __future__ import annotations

import argparse
from pathlib import Path
import shutil
import subprocess

CUA_REVISION = "201732fffd81a40818be7ce2e04269aec962bc42"
EXAMPLE = Path("libs/cua-driver/examples/jev-use")


def replace_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise ValueError("pinned upstream source no longer matches the adapter patch")
    return text.replace(old, new, 1)


def prepare(checkout: Path) -> None:
    revision = subprocess.check_output(["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True).strip()
    if revision != CUA_REVISION:
        raise ValueError(f"expected Cua commit {CUA_REVISION}, got {revision}")
    python = checkout / EXAMPLE / "python"
    runner = (python / "run.py").read_text()
    chooser = (python / "choose_action.py").read_text()
    core = (python / "core.py").read_text()
    # Complete human-readable actions in the same format as the fine-tune's
    # training menus. IDs, tools and arguments remain exactly as upstream built.
    core = replace_once(core, '"Replace the verification field with the required token.",',
                        'f\'Type "{token}" into textbox "verification value".\',')
    core = replace_once(core, '"Submit the form now that the verification field contains the token.",',
                        '\'Click button "Submit".\',')
    runner = replace_once(runner, 'choices=("mock", "live")', 'choices=("mock", "live", "gliner")')
    runner = replace_once(
        runner,
        '                else:\n                    choice, confidence, probabilities = await asyncio.to_thread(',
        '                elif args.provider == "gliner":\n'
        '                    from gliner_adapter import choose_live as choose_gliner\n'
        '                    field = next((ref for ref in snapshot.get("refs", [])\n'
        '                                  if ref.get("role") == "textbox"\n'
        '                                  and ref.get("name") == "verification value"), None)\n'
        '                    current_goal = (\'Click button "Submit".\' if field and field.get("value") == token\n'
        '                                    else f\'Type "{token}" into textbox "verification value".\')\n'
        '                    choice, confidence, probabilities = await asyncio.to_thread(\n'
        '                        choose_gliner, candidates, snapshot, visual, history, goal=current_goal\n'
        '                    )\n'
        '                else:\n                    choice, confidence, probabilities = await asyncio.to_thread(',
    )
    chooser = replace_once(chooser, '([], ["--mock"])', '([], ["--mock"], ["--gliner"])')
    chooser = replace_once(chooser, 'usage: choose_action.py [--mock]', 'usage: choose_action.py [--mock | --gliner]')
    chooser = replace_once(
        chooser,
        '        response = choose_request(request, mock=sys.argv[1:] == ["--mock"])',
        '        if sys.argv[1:] == ["--gliner"]:\n'
        '            from gliner_adapter import choose_request as choose_gliner_request\n'
        '            response = choose_gliner_request(request)\n'
        '        else:\n'
        '            response = choose_request(request, mock=sys.argv[1:] == ["--mock"])',
    )
    # Validate every replacement before writing anything; never overwrite edits.
    subprocess.run(["git", "-C", str(checkout), "diff", "--exit-code", "--", str(EXAMPLE)], check=True)
    destination = python / "gliner_adapter.py"
    if destination.exists():
        raise ValueError("adapter already exists; use a fresh checkout")
    shutil.copyfile(Path(__file__).with_name("gliner_adapter.py"), destination)
    (python / "run.py").write_text(runner)
    (python / "choose_action.py").write_text(chooser)
    (python / "core.py").write_text(core)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    prepare(parser.parse_args().checkout.resolve())
