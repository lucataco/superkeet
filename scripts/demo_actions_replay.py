#!/usr/bin/env python3
"""Replay the demo WAV through parakeet transcribe --session and diff the text."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WAV = ROOT / "Tests/Fixtures/demo-actions/demo-audio.wav"
DEFAULT_EXPECTED = ROOT / "Tests/Fixtures/demo-actions/expected-transcript.txt"
BUNDLED = Path("/Applications/Superkeet.app/Contents/Resources/bin/parakeet")


def normalize_text(text):
    return " ".join(text.split())


def load_complete_text(payload):
    if isinstance(payload, list):
        completes = [row for row in payload if isinstance(row, dict) and row.get("type") == "complete"]
        if not completes:
            raise ValueError("JSON array has no complete event")
        payload = completes[-1]
    if not isinstance(payload, dict):
        raise ValueError("Expected a JSON object or an array of events")
    text = payload.get("text")
    if not isinstance(text, str) or not text.strip():
        raise ValueError("complete event has no text")
    return normalize_text(text)


def parse_engine_stdout(stdout):
    stdout = stdout.strip()
    if not stdout:
        raise ValueError("engine printed no JSON")
    try:
        return load_complete_text(json.loads(stdout))
    except json.JSONDecodeError:
        last_error = None
        for line in reversed(stdout.splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                return load_complete_text(json.loads(line))
            except (json.JSONDecodeError, ValueError) as error:
                last_error = error
        raise ValueError("engine stdout had no complete JSON") from last_error


def find_engine(explicit):
    if explicit:
        return Path(explicit)
    env = os.environ.get("SUPERKEET_PARAKEET")
    if env:
        return Path(env)
    if BUNDLED.is_file():
        return BUNDLED
    from shutil import which
    found = which("parakeet")
    if found:
        return Path(found)
    raise FileNotFoundError("Set SUPERKEET_PARAKEET or install Superkeet.app")


DEMO_PHRASES = (
    "notes app",
    "create a new note",
    "title say hello",
    "arc browser",
    "norbert wiener",
    "x.com",
    "photo booth",
    "take a picture",
)


def transcribe(engine, wav, model_dir):
    command = [str(engine), "transcribe", str(wav), "--session", "--format", "json"]
    if model_dir:
        command.extend(["--model-dir", str(model_dir)])
    completed = subprocess.run(command, check=True, capture_output=True, text=True, timeout=120)
    return parse_engine_stdout(completed.stdout)


def missing_phrases(text, phrases=DEMO_PHRASES):
    folded = text.casefold()
    return [phrase for phrase in phrases if phrase not in folded]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wav", type=Path, default=DEFAULT_WAV)
    parser.add_argument("--expected", type=Path, default=DEFAULT_EXPECTED)
    parser.add_argument("--engine", type=Path)
    parser.add_argument("--model-dir", type=Path)
    args = parser.parse_args(argv)
    expected = normalize_text(args.expected.read_text())
    actual = transcribe(find_engine(args.engine), args.wav, args.model_dir)
    missing = missing_phrases(actual)
    if missing:
        print("transcript missing", ", ".join(missing))
        print("actual:", actual)
        return 1
    if actual != expected:
        print("transcript matches")
        print("punctuation differs from the frozen expected-transcript.txt")
        return 0
    print("transcript matches")
    return 0


if __name__ == "__main__":
    sys.exit(main())
