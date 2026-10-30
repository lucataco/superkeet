#!/usr/bin/env python3
"""Regenerates Tests/Fixtures/demo-actions/replay-partials.ndjson.

Replays the demo recording through `parakeet transcribe --session --partials`
the way a Superkeet listening session hears it:

1. One pass over the whole file finds the pauses. A take ends when no new
   partial arrives for ENDPOINT seconds after the last one (the same rule as
   `ListeningSessionPolicy.fallbackEndpointTimeout`, used when the engine
   sends no ticks).
2. Each take is cut out with ffmpeg and replayed on its own, so its partials
   restart at sequence 1 and contain only that utterance, exactly as a fresh
   `start` on the daemon would. The next take begins GAP seconds after the
   endpoint, the time the engine needs to finish and reopen the microphone.

Output lines, in time order:
  {"type":"take","take":n,"start_ms":…,"end_ms":…}
  {"type":"tick","take":n,"at_ms":<recording time>,"trailing_silence_ms":…}
  {"type":"partial","take":n,"at_ms":<recording time>,"sequence":…,"text":…}
  {"type":"final","take":n,"at_ms":<endpoint time>,"text":…}

A tick comes before the partial for the same audio, as the engine sends them. Takes are
still cut with the wall-clock rule above, so a take's ticks stop where its clip ends.

Needs the parakeet binary (0.1.12+, for `tick` events), the model, and ffmpeg.
The Swift replay test only reads the committed output, so CI needs none of them.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Tests", "Fixtures", "demo-actions")
DEFAULT_MODEL = os.path.expanduser("~/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3")


def parse_events(output):
    partials, ticks, final = [], [], ""
    for line in output.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        if event.get("type") == "partial":
            if "audio_ms" not in event:
                sys.exit("This engine does not report audio_ms; use parakeet-cli 0.1.9 or newer.")
            partials.append(event)
        elif event.get("type") == "tick":
            ticks.append(event)
        elif "text" in event:
            final = event["text"]
    return partials, ticks, final


def replay(engine, model_dir, wav):
    output = subprocess.run(
        [engine, "transcribe", wav, "--session", "--partials", "--format", "json", "--model-dir", model_dir],
        check=True, capture_output=True, text=True,
    ).stdout
    return parse_events(output)


def timeline(start_ms, partials, ticks):
    events = [(tick["audio_ms"], 0, {"type": "tick", "at_ms": start_ms + tick["audio_ms"],
                                     "trailing_silence_ms": tick["trailing_silence_ms"]}) for tick in ticks]
    events += [(partial["audio_ms"], 1, {"type": "partial", "at_ms": start_ms + partial["audio_ms"],
                                         "sequence": partial["sequence"], "text": partial["text"]})
               for partial in partials]
    return [line for _, _, line in sorted(events, key=lambda event: event[:2])]


PROGRESS_WORDS = 4


def progress_key(text):
    """Mirrors ListeningSessionPolicy.progressKey: the last few words, case and punctuation aside."""
    words = re.findall(r"[^\W_]+", text.lower())
    return " ".join(words[-PROGRESS_WORDS:])


def first_endpoint(partials, endpoint_ms, clip_ms):
    """Relative time the first pause ends the take, or None if the clip ran out first. Mirrors
    ListeningSessionController: only an ending not yet heard in this take restarts the timer."""
    seen, last_new = set(), None
    for event in partials:
        key = progress_key(event["text"])
        if key in seen:
            continue
        seen.add(key)
        at = event["audio_ms"]
        if last_new is not None and at - last_new >= endpoint_ms:
            return last_new + endpoint_ms
        last_new = at
    if last_new is not None and clip_ms - last_new >= endpoint_ms:
        return last_new + endpoint_ms
    return None


def cut(wav, start_ms, end_ms, path):
    subprocess.run(
        ["ffmpeg", "-v", "error", "-y", "-i", wav, "-ss", f"{start_ms / 1000:.3f}", "-to", f"{end_ms / 1000:.3f}",
         "-ar", "16000", "-ac", "1", path],
        check=True,
    )


def find_takes(engine, model_dir, wav, endpoint_ms, gap_ms, duration_ms, scratch, window_ms=15_000):
    """Finds each utterance the way a live session does: a fresh take from where the
    microphone reopened, ended by the first pause heard in that take."""
    takes, start = [], 0
    while start < duration_ms - endpoint_ms:
        window = window_ms
        while True:
            end = min(duration_ms, start + window)
            probe = os.path.join(scratch, "probe.wav")
            cut(wav, start, end, probe)
            partials, _, _ = replay(engine, model_dir, probe)
            if not partials:
                return takes
            relative = first_endpoint(partials, endpoint_ms, end - start)
            if relative is not None:
                takes.append((start, start + relative))
                start = start + relative + gap_ms
                break
            if end >= duration_ms:
                takes.append((start, duration_ms))
                return takes
            window *= 2
    return takes


def wav_duration_ms(wav):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", wav],
        check=True, capture_output=True, text=True,
    ).stdout
    return int(float(out.strip()) * 1000)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", required=True, help="path to the parakeet binary")
    parser.add_argument("--model-dir", default=DEFAULT_MODEL)
    parser.add_argument("--wav", default=os.path.join(FIXTURES, "demo-audio.wav"))
    parser.add_argument("--endpoint", type=float, default=1.0, help="pause that ends a take, seconds")
    parser.add_argument("--gap", type=float, default=0.35, help="engine turnaround between takes, seconds")
    parser.add_argument("--out", default=os.path.join(FIXTURES, "replay-partials.ndjson"))
    args = parser.parse_args()

    duration = wav_duration_ms(args.wav)
    lines = []
    with tempfile.TemporaryDirectory() as scratch:
        takes = find_takes(args.engine, args.model_dir, args.wav, int(args.endpoint * 1000), int(args.gap * 1000),
                           duration, scratch)
        for index, (start, end) in enumerate(takes):
            clip = os.path.join(scratch, f"take-{index}.wav")
            cut(args.wav, start, end, clip)
            partials, ticks, final = replay(args.engine, args.model_dir, clip)
            if not ticks:
                sys.exit("This engine sends no tick events; use parakeet-cli 0.1.12 or newer.")
            lines.append({"type": "take", "take": index, "start_ms": start, "end_ms": end})
            for event in timeline(start, partials, ticks):
                lines.append({**event, "take": index})
            lines.append({"type": "final", "take": index, "at_ms": end, "text": final})
            print(f"take {index}: {start / 1000:.2f}-{end / 1000:.2f}s  {final!r}", file=sys.stderr)

    with open(args.out, "w", encoding="utf-8") as handle:
        for line in lines:
            handle.write(json.dumps(line, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"wrote {len(lines)} lines to {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()
