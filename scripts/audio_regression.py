#!/usr/bin/env python3
DESCRIPTION = """Render/replay auditable synthetic WAV fixtures, or replay supplied human WAVs.

Critical words/counts are hard gates independent of word error rate. An acoustic
failure is reported, never normalized away by a replacement or cleaner.
"""
import argparse
import array
import collections
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
NUMBERS = {"five": "5", "six": "6", "seven": "7", "eight": "8"}


def words(text):
    return [NUMBERS.get(word, word) for word in re.findall(r"[\w']+", text.lower())]


def word_errors(reference, actual):
    row = list(range(len(actual) + 1))
    for index, expected in enumerate(reference, 1):
        next_row = [index]
        for column, observed in enumerate(actual, 1):
            next_row.append(min(next_row[-1] + 1, row[column] + 1,
                                row[column - 1] + (expected != observed)))
        row = next_row
    return row[-1]


def render(case, directory, voice):
    path = directory / (case["id"] + ".wav")
    if path.exists():
        raise FileExistsError(f"Fixture already exists: {path}")
    with tempfile.TemporaryDirectory() as temp:
        source = Path(temp) / "source.wav"
        subprocess.run(["say", "-v", voice, "-r", "170", "-o", str(source),
                        "--file-format=WAVE", "--data-format=LEI16@16000", case["spoken"]], check=True)
        with wave.open(str(source), "rb") as audio:
            if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, 16000):
                raise ValueError("Expected 16 kHz mono PCM16")
            pcm = array.array("h", audio.readframes(audio.getnframes()))
    if case.get("trim_trailing_silence"):
        end = next((i + 1 for i in range(len(pcm) - 1, -1, -1) if abs(pcm[i]) > 32), 0)
        pcm = pcm[:end]
    if "period_seconds" in case:
        length = int(case["period_seconds"] * 16000)
        if len(pcm) > length:
            raise ValueError("Spoken fixture exceeds its period; do not truncate speech")
        pcm.extend([0] * (length - len(pcm)))
    pcm *= case.get("repeat", 1)
    with wave.open(str(path), "wb") as output:
        output.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
        output.writeframes(pcm.tobytes())
    return {"id": case["id"], "voice": voice, "source": "macOS say (synthetic)",
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "seconds": len(pcm) / 16000}


def evaluate(case, event, threshold):
    actual = words(event.get("text", ""))
    reference = words(case["spoken"]) * case.get("repeat", 1)
    counts = collections.Counter(actual)
    failures = [f"{word}: expected {count}, got {counts[word]}"
                for word, count in case["critical_counts"].items() if counts[word] != count]
    answer_words = ["5", "6", "7", "8"] if case["id"] == "list-from-five" else ["a", "agreed"]
    if "answer_count" in case and sum(counts[word] for word in answer_words) != case["answer_count"]:
        failures.append("Answer count does not match")
    wer = word_errors(reference, actual) / max(1, len(reference))
    if wer > threshold:
        failures.append(f"WER {wer:.1%} exceeds {threshold:.1%}")
    if event.get("status") != "ok" or event.get("failed_segments", 0) or event.get("dropped_samples", 0):
        failures.append("Engine did not complete without loss")
    return {"id": case["id"], "wer": wer, "failures": failures, "event": event}


def main():
    parser = argparse.ArgumentParser(description=DESCRIPTION)
    parser.add_argument("action", choices=["render", "run"])
    parser.add_argument("--fixtures", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=ROOT / "Tests/AudioRegression/cases.json")
    parser.add_argument("--engine", type=Path)
    parser.add_argument("--model-dir", type=Path)
    parser.add_argument("--voice", default="Samantha")
    parser.add_argument("--max-wer", type=float, default=0.15)
    parser.add_argument("--report", type=Path)
    parser.add_argument("--case", action="append")
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    cases = [case for case in manifest["cases"] if not args.case or case["id"] in args.case]
    if not cases:
        parser.error("No matching cases")
    if args.action == "render":
        args.fixtures.mkdir(parents=True, exist_ok=True)
        records = [render(case, args.fixtures, args.voice) for case in cases]
        (args.fixtures / "provenance.json").write_text(json.dumps(records, indent=2) + "\n")
        return
    if not args.engine or not args.model_dir:
        parser.error("run requires --engine and --model-dir")
    results = []
    for case in cases:
        path = args.fixtures / (case["id"] + ".wav")
        command = [str(args.engine.resolve()), "transcribe", str(path), "--session", "--format", "json", "--model-dir", str(args.model_dir)]
        completed = subprocess.run(command, check=True, capture_output=True, text=True, timeout=900)
        result = evaluate(case, json.loads(completed.stdout), args.max_wer)
        result["audio_sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        results.append(result)
        print(f"{case['id']}: WER {result['wer']:.1%}; " + ("PASS" if not result["failures"] else "; ".join(result["failures"])))
    report = {"fixture_provenance": manifest["provenance"], "results": results}
    if args.report:
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    raise SystemExit(1 if any(result["failures"] for result in results) else 0)


if __name__ == "__main__":
    main()
