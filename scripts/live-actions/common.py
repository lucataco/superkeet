"""Shared pure helpers for the live-actions rig: paths, scenario loading, phrase matching, stats."""

import hashlib
import json
import math
import re
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / ".build" / "live-actions"
APP = Path("/Applications/Superkeet.app")
PARAKEET = APP / "Contents/Resources/bin/parakeet"
APP_BUNDLE_ID = "com.superkeet.app"
LOOPBACK_DEVICE = "BlackHole 2ch"

PROBE_KINDS = ("frontmost", "new_window", "focused_text_contains")
FORBIDDEN_EVENTS = ("take_split", "planner_call", "duplicate_dispatch", "success_without_effect")
START_STATES = ("quit",)
SAFE_TARGETS = ("com.apple.TextEdit",)


def tokens(text):
    return re.findall(r"[^\W_]+", text.lower())


def phrase_variants(phrase):
    """Token sequences that count as the phrase. "TextEdit" also matches a transcript's "Text Edit"."""
    spaced = re.sub(r"(?<=[a-z])(?=[A-Z])", " ", phrase)
    variants = [tokens(phrase)]
    if tokens(spaced) != variants[0]:
        variants.append(tokens(spaced))
    return [v for v in variants if v]


def _find_run(haystack, needle):
    for i in range(len(haystack) - len(needle) + 1):
        if haystack[i:i + len(needle)] == needle:
            return i
    return None


def phrase_in_text(text, phrase):
    """True when the phrase occurs in text on word boundaries, so "ax.com" never satisfies "x.com"."""
    words = tokens(text)
    return any(_find_run(words, variant) is not None for variant in phrase_variants(phrase))


def missing_phrases(text, phrases):
    return [p for p in phrases if not phrase_in_text(text, p)]


def phrase_end_ms(clock, phrase):
    """End time of the first occurrence of phrase in a speech clock of (start_ms, end_ms, word) rows.

    A row can hold several tokens ("x.com?"), and they all share the row's times."""
    flat = []
    for start, end, word in clock:
        for tok in tokens(word):
            flat.append((tok, start, end))
    words = [t[0] for t in flat]
    best = None
    for variant in phrase_variants(phrase):
        at = _find_run(words, variant)
        if at is not None:
            last = at + len(variant) - 1
            end = flat[last][2]
            while end is None and last > 0:
                last -= 1
                end = flat[last][2]
            if end is not None and (best is None or end < best):
                best = end
    return best


def read_clock(path):
    rows = []
    for line in Path(path).read_text().splitlines():
        if not line.strip():
            continue
        start, end, word = line.split("\t", 2)
        rows.append((int(start) if start else None, int(end) if end else None, word))
    return rows


def write_clock(path, rows):
    Path(path).write_text("".join(f"{s if s is not None else ''}\t{e if e is not None else ''}\t{w}\n" for s, e, w in rows))


def load_scenario(path):
    scenario = json.loads(Path(path).read_text())
    problems = validate_scenario(scenario)
    if problems:
        raise ValueError(f"{path}: " + "; ".join(problems))
    return scenario


def validate_scenario(scenario):
    problems = []
    for key in ("name", "voice", "start_state", "utterances", "expect", "forbid"):
        if key not in scenario:
            problems.append(f"missing {key}")
    if problems:
        return problems
    for bundle, state in scenario["start_state"].items():
        if bundle not in SAFE_TARGETS:
            problems.append(f"start_state {bundle}: the rig may only drive {SAFE_TARGETS}")
        if state not in START_STATES:
            problems.append(f"start_state {bundle}: {state!r} is not one of {START_STATES}")
    script = " ".join(u["text"] for u in scenario["utterances"])
    for u in scenario["utterances"]:
        if not isinstance(u.get("pause_ms"), int) or u["pause_ms"] < 0:
            problems.append(f"utterance {u.get('text', '?')!r} needs a non-negative integer pause_ms")
    ids = set()
    for item in scenario["expect"]:
        if item["id"] in ids:
            problems.append(f"duplicate expect id {item['id']}")
        ids.add(item["id"])
        if len(item["probe"]) != 1 or next(iter(item["probe"])) not in PROBE_KINDS:
            problems.append(f"expect {item['id']}: probe must have exactly one of {PROBE_KINDS}")
        if not phrase_in_text(script, item["after"]):
            problems.append(f"expect {item['id']}: phrase {item['after']!r} is not in the utterances")
    for name in scenario["forbid"]:
        if name not in FORBIDDEN_EVENTS:
            problems.append(f"unknown forbid {name}")
    return problems


def scenario_targets(scenario):
    """Bundles the observer should watch: the apps the rig sets up plus any app a probe names."""
    probed = {v for e in scenario["expect"] for k, v in e["probe"].items() if k in ("frontmost", "new_window")}
    return sorted(set(scenario["start_state"]) | probed)


def parse_log(text):
    """Rows of (epoch_ms, category, message) from `log stream --style ndjson`. Other lines are skipped."""
    rows = []
    for line in text.splitlines():
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
            stamp = datetime.strptime(event["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z")
        except (ValueError, KeyError):
            continue
        rows.append((round(stamp.timestamp() * 1000), event.get("category", ""), event.get("eventMessage", "")))
    return rows


def audio_key(scenario, version="1"):
    """Hash of everything that changes the audio, so edits to expect or forbid reuse the cached stimulus."""
    body = {
        "v": version,
        "voice": scenario["voice"],
        "style": scenario.get("style", ""),
        "lead_ms": scenario.get("lead_ms", 0),
        "utterances": [[u["text"], u["pause_ms"]] for u in scenario["utterances"]],
    }
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:12]


def percentile(values, p):
    """Nearest-rank percentile. None counts as infinity, so a missed probe never improves the number."""
    if not values:
        return None
    ranked = sorted(math.inf if v is None else v for v in values)
    rank = max(1, math.ceil(p / 100 * len(ranked)))
    value = ranked[rank - 1]
    return None if value == math.inf else value
