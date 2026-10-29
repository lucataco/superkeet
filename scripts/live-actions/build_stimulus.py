#!/usr/bin/env python3
"""Build the speech stimulus for a scenario."""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import wave
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

RATE = 48000
TARGET_LUFS = -16.0
PEAK_DBTP = -1.0
MAX_ATTEMPTS = 3
ALIGN_SLACK_MS = 250
LIVE_SLACK_MS = 1000
TTS_URL = "https://api.replicate.com/v1/models/google/gemini-3.8-flash-tts/predictions"
WHISPERX_VERSION = "655845d6190ef70573c669245f245892cd039df4b880a1e3a65852c09252f5cc"
TRIM = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.02"


class GateError(RuntimeError):
    pass


def layout(lead_ms, clip_samples, pauses_ms, rate=RATE):
    windows, at = [], round(lead_ms * rate / 1000)
    for samples, pause in zip(clip_samples, pauses_ms):
        windows.append((at, at + samples))
        at += samples + round(pause * rate / 1000)
    return windows, at


def windows_ms(windows, rate=RATE):
    return [(round(s * 1000 / rate), round(e * 1000 / rate)) for s, e in windows]


def alignment_problems(clock, windows, slack_ms=ALIGN_SLACK_MS):
    problems = []
    timed = [(s, e, w) for s, e, w in clock if s is not None and e is not None]
    for start, end, word in timed:
        if not any(ws - slack_ms <= start and end <= we + slack_ms for ws, we in windows):
            problems.append(f"word {word!r} at {start}-{end} ms is outside every utterance window")
    for i, (ws, we) in enumerate(windows):
        if not any(ws - slack_ms <= e <= we + slack_ms for _, e, _ in timed):
            problems.append(f"utterance {i} window {ws}-{we} ms has no aligned word")
    return problems


def run(cmd, **kwargs):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs)


def replicate(url, body):
    token = os.environ.get("REPLICATE_API_TOKEN")
    if not token:
        raise SystemExit("REPLICATE_API_TOKEN is not set")
    auth = {"Authorization": f"Bearer {token}"}
    request = urllib.request.Request(
        url, json.dumps(body).encode(), {**auth, "Content-Type": "application/json", "Prefer": "wait=60"}
    )
    pred = json.load(urllib.request.urlopen(request))
    while pred["status"] not in ("succeeded", "failed", "canceled"):
        time.sleep(1.5)
        pred = json.load(urllib.request.urlopen(urllib.request.Request(pred["urls"]["get"], headers=auth)))
    if pred["status"] != "succeeded":
        raise RuntimeError(f"replicate {pred['status']}: {pred.get('error')}")
    return pred["output"]


def read_pcm(path):
    with wave.open(str(path)) as w:
        if (w.getframerate(), w.getnchannels(), w.getsampwidth()) != (RATE, 2, 2):
            raise ValueError(f"{path} is not 48 kHz stereo 16-bit")
        return w.readframes(w.getnframes())


def synthesize(text, voice, style, out_path):
    output = replicate(TTS_URL, {"input": {"text": text, "voice": voice, "style": style, "output_format": "wav"}})
    urls = output if isinstance(output, list) else [output]
    pcm = b""
    with tempfile.TemporaryDirectory() as tmp:
        for i, url in enumerate(urls):
            raw, fixed = Path(tmp, f"raw{i}.wav"), Path(tmp, f"fixed{i}.wav")
            urllib.request.urlretrieve(url, raw)
            trim = f"{TRIM},areverse,{TRIM},areverse"
            run(["ffmpeg", "-v", "error", "-y", "-i", raw, "-af", trim, "-ar", str(RATE), "-ac", "2", "-c:a", "pcm_s16le", fixed])
            pcm += read_pcm(fixed)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    write_pcm(out_path, pcm)


def write_pcm(path, pcm):
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm)


def measure_gain_db(wav):
    result = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", wav, "-af", f"loudnorm=I={TARGET_LUFS}:TP={PEAK_DBTP}:print_format=json", "-f", "null", "-"],
        capture_output=True, text=True, check=True,
    )
    stats = json.loads(re.findall(r"\{[^{}]*\}", result.stderr)[-1])
    loudness, true_peak = float(stats["input_i"]), float(stats["input_tp"])
    return min(TARGET_LUFS - loudness, PEAK_DBTP - true_peak), loudness


def replay(wav16):
    if not common.PARAKEET.is_file():
        raise SystemExit(f"{common.PARAKEET} not found; install Superkeet first")
    out = run([common.PARAKEET, "transcribe", wav16, "--session", "--partials", "--format", "json"])
    final, partials = None, []
    for line in out.stdout.splitlines():
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        if event.get("type") == "partial":
            partials.append((event["audio_ms"], event["text"]))
        elif event.get("type") == "complete":
            final = event["text"]
    if not final:
        raise GateError("the engine replay printed no final transcript")
    return final, partials


def align(wav16, out_clock):
    data = "data:audio/wav;base64," + base64.b64encode(Path(wav16).read_bytes()).decode()
    output = replicate(
        "https://api.replicate.com/v1/predictions",
        {"version": WHISPERX_VERSION, "input": {"audio_file": data, "align_output": True, "language": "en"}},
    )
    rows = []
    for segment in output["segments"]:
        for word in segment.get("words", []):
            start, end = word.get("start"), word.get("end")
            rows.append((round(start * 1000) if start is not None else None, round(end * 1000) if end is not None else None, word["word"]))
    common.write_clock(out_clock, rows)
    return rows


def live_gate_problems(partials, clock, phrases, slack_ms=LIVE_SLACK_MS):
    problems = []
    for phrase in phrases:
        end = common.phrase_end_ms(clock, phrase)
        if end is not None and not any(at <= end + slack_ms and common.phrase_in_text(text, phrase) for at, text in partials):
            problems.append((phrase, f"no partial showed {phrase!r} by {end + slack_ms} ms (phrase ends at {end} ms)"))
    return problems


def check_phrases(scenario, transcript, partials, clock, windows):
    phrases = [e["after"] for e in scenario["expect"]]
    problems = [(p, f"engine transcript lacks {p!r}") for p in common.missing_phrases(transcript, phrases)]
    problems += [(p, f"speech clock lacks {p!r}") for p in phrases if common.phrase_end_ms(clock, p) is None]
    problems += [(None, m) for m in alignment_problems(clock, windows)]
    return problems + live_gate_problems(partials, clock, phrases)


def carrying(scenario, problems):
    words = [p for p, _ in problems]
    return [i for i, u in enumerate(scenario["utterances"])
            if None in words or any(p and common.phrase_in_text(u["text"], p) for p in words)]


def clip_path(scenario, utterance, take):
    key = hashlib.sha256(json.dumps([scenario["voice"], scenario.get("style", ""), utterance["text"], take]).encode()).hexdigest()[:16]
    return common.BUILD / "cache" / "clips" / f"{key}.wav"


def assemble(scenario, clips, paths):
    pcms = [read_pcm(c) for c in clips]
    placed, total = layout(scenario.get("lead_ms", 0), [len(p) // 4 for p in pcms], [u["pause_ms"] for u in scenario["utterances"]])
    joined = bytearray(b"\0" * (total * 4))
    for (start, _), pcm in zip(placed, pcms):
        joined[start * 4:start * 4 + len(pcm)] = pcm
    raw = paths["dir"] / "joined-raw.wav"
    write_pcm(raw, bytes(joined))
    gain_db, loudness = measure_gain_db(raw)
    run(["ffmpeg", "-v", "error", "-y", "-i", raw, "-af", f"volume={gain_db:.3f}dB", "-ar", str(RATE), "-ac", "2", "-c:a", "pcm_s16le", paths["wav48"]])
    run(["ffmpeg", "-v", "error", "-y", "-i", paths["wav48"], "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", paths["wav16"]])
    raw.unlink()
    return placed, total, gain_db, loudness


def build(scenario_path, fresh=False):
    scenario = common.load_scenario(scenario_path)
    out = common.BUILD / "cache" / f"{scenario['name']}-{common.audio_key(scenario)}"
    paths = {"dir": out, "wav48": out / "stimulus-48k.wav", "wav16": out / "stimulus-16k.wav",
             "clock": out / "speech-clock.tsv", "meta": out / "stimulus.json", "takes": out / "takes.json"}
    if not fresh and all(paths[k].exists() for k in ("wav48", "wav16", "clock", "meta")):
        meta = json.loads(paths["meta"].read_text())
        problems = check_phrases(scenario, meta["transcript"], meta["partials"], common.read_clock(paths["clock"]), meta["windows_ms"])
        if problems:
            raise GateError("; ".join(m for _, m in problems))
        return paths

    out.mkdir(parents=True, exist_ok=True)
    count = len(scenario["utterances"])
    takes = [int(time.time())] * count if fresh else (json.loads(paths["takes"].read_text()) if paths["takes"].exists() else [0] * count)
    for attempt in range(MAX_ATTEMPTS):
        paths["takes"].write_text(json.dumps(takes))
        clips = [clip_path(scenario, u, take) for u, take in zip(scenario["utterances"], takes)]
        missing = [(u, c) for u, c in zip(scenario["utterances"], clips) if not c.exists()]
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(pool.map(lambda uc: synthesize(uc[0]["text"], scenario["voice"], scenario.get("style", ""), uc[1]), missing))
        placed, total, gain_db, loudness = assemble(scenario, clips, paths)
        transcript, partials = replay(paths["wav16"])
        wins = windows_ms(placed)
        problems = [(p, f"engine transcript lacks {p!r}") for p in common.missing_phrases(transcript, [e["after"] for e in scenario["expect"]])]
        clock = []
        if not problems:
            clock = align(paths["wav16"], paths["clock"])
            problems = check_phrases(scenario, transcript, partials, clock, wins)
        if not problems:
            break
        print(f"attempt {attempt + 1} failed: " + "; ".join(m for _, m in problems), file=sys.stderr)
        for i in carrying(scenario, problems):
            takes[i] += 1
    else:
        raise GateError(f"gates failed after {MAX_ATTEMPTS} attempts: " + "; ".join(m for _, m in problems))

    paths["meta"].write_text(json.dumps({
        "name": scenario["name"], "duration_ms": round(total * 1000 / RATE), "windows_ms": wins,
        "gain_db": round(gain_db, 2), "input_lufs": round(loudness, 2), "takes": takes,
        "transcript": transcript, "partials": partials,
    }, indent=1))
    return paths


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("scenario")
    parser.add_argument("--fresh", action="store_true", help="ignore cached audio and synthesize again")
    args = parser.parse_args()
    paths = build(args.scenario, args.fresh)
    meta = json.loads(paths["meta"].read_text())
    clock = common.read_clock(paths["clock"])
    print(f"{paths['wav48']} ({meta['duration_ms']} ms, gain {meta['gain_db']} dB from {meta['input_lufs']} LUFS)")
    for item in common.load_scenario(args.scenario)["expect"]:
        print(f"  {item['id']}: {item['after']!r} ends at {common.phrase_end_ms(clock, item['after'])} ms")


if __name__ == "__main__":
    main()
