#!/usr/bin/env python3
"""Score live-actions runs and write report.md and verdict.json.

usage: report.py <runs-dir> [--loopback-ms N]

A runs dir holds scenario.json, speech-clock.tsv, and one run-NN/ folder per run with observer.ndjson,
log.ndjson, audit.ndjson, documents.json, and meta.json. Latency is the time the probe first passes minus
the end of the phrase that asked for it, less the calibrated loopback delay. Negative means the action
landed before the speaker finished the phrase.
"""

import argparse
import json
import re
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common  # noqa: E402

DISPATCH = "Pause detected; dispatching the utterance"
DEFAULT_P90_BUDGET_MS = 1000
NON_DOCUMENT_TITLES = ("", "Open")
TYPED = re.compile(r"Typed [“\"](.+?)[”\"]")
QUOTES = str.maketrans({"’": "'", "‘": "'", "“": '"', "”": '"'})


def squash(text):
    """Compare text the way a reader does. TextEdit turns straight quotes into curly ones."""
    return re.sub(r"\s+", " ", text.translate(QUOTES)).strip().lower()


def read_ndjson(path):
    path = Path(path)
    if not path.exists():
        return []
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def audio_origin_ms(events):
    play = next((e for e in events if e["event"] == "audio_play"), None)
    if play is None:
        return None
    if "t" in play:
        return play["t"]
    return round(datetime.fromisoformat(play["wall"].replace("Z", "+00:00")).timestamp() * 1000)


def rel_ms(event, origin):
    if "t" in event:
        return event["t"] - origin
    return event.get("ms")


def load_run(run_dir):
    run_dir = Path(run_dir)
    events = read_ndjson(run_dir / "observer.ndjson")
    docs = json.loads((run_dir / "documents.json").read_text()) if (run_dir / "documents.json").exists() else {}
    meta = json.loads((run_dir / "meta.json").read_text()) if (run_dir / "meta.json").exists() else {}
    log_path = run_dir / "log.ndjson"
    return {
        "name": run_dir.name, "events": events, "meta": meta,
        "log": common.parse_log(log_path.read_text(errors="replace")) if log_path.exists() else [],
        "audit": read_ndjson(run_dir / "audit.ndjson"),
        "documents": docs.get("final") if docs.get("final") is not None else docs.get("tail"),
    }


def timeline(events, origin):
    """Observer events with a millisecond offset from the first sample, in order. Events without a time are dropped."""
    rows = [(rel_ms(e, origin), e) for e in events]
    return sorted(((ms, e) for ms, e in rows if ms is not None), key=lambda r: r[0])


def probe_ms(kind, value, rows):
    """Offset at which the probe first holds, and a note when it already held before playback started."""
    if kind == "frontmost":
        hits = [ms for ms, e in rows if (e["event"] == "frontmost" and e.get("bundle") == value) or e["event"] == "target_frontmost"]
    elif kind == "new_window":
        seen, hits = set(), []
        for ms, e in rows:
            if e["event"] != "target_windows" or e.get("bundle", value) != value:
                continue
            titles = {t for t in e.get("titles", []) if t not in NON_DOCUMENT_TITLES}
            if ms >= 0 and titles - seen:
                hits.append(ms)
                break
            seen |= titles
    else:
        needle = value.lower()
        hits = [ms for ms, e in rows if e["event"] == "target_text" and any(needle in t.lower() for t in e.get("texts", [e.get("text", "")]))]
    if not hits:
        return None, None
    after = [ms for ms in hits if ms >= 0]
    note = f"{kind} already true {min(hits)} ms before playback" if hits[0] < 0 else None
    return (after[0] if after else None), note


def document_text(run):
    if run["documents"] is not None:
        return "\n".join(d["text"] for d in run["documents"])
    texts = [t for e in run["events"] if e["event"] == "target_text" for t in e.get("texts", [e.get("text", "")])]
    return texts[-1] if texts else ""


def typed_claims(run, rows):
    """Texts that the audit log or the HUD says were typed. A HUD card from the previous run can still be on
    screen when playback starts, so only HUD updates after the first sample count."""
    claims = set()
    for row in run["audit"]:
        if row.get("toolName") == "type_text" and row.get("outcome", "").startswith("succeeded"):
            match = TYPED.search(row.get("detail") or "")
            claims.add(match.group(1) if match else None)
    for ms, e in rows:
        if e["event"] == "hud" and ms >= 0:
            claims.update(TYPED.findall(e.get("text", "")))
    return {c for c in claims if c}


def duplicate_dispatches(audit):
    seen = Counter()
    for row in audit:
        if row.get("risk") == "mutating" and (row.get("outcome") == "speculative" or row.get("outcome", "").startswith("succeeded")):
            match = TYPED.search(row.get("detail") or "")
            seen[(row.get("toolName"), row.get("arguments"), match.group(1) if match else None)] += 1
    return sum(n - 1 for n in seen.values())


def first_words_ms(rows, scenario, first_word_end):
    """When live words first reached the HUD: the first update that shows two consecutive script words
    that were not on screen before, minus the end of the first spoken word. Independent of the HUD layout."""
    script_words = common.tokens(" ".join(u["text"] for u in scenario["utterances"]))
    script = set(zip(script_words, script_words[1:]))
    previous = set()
    for ms, e in rows:
        if e["event"] != "hud":
            continue
        words = common.tokens(e.get("text", ""))
        now = set(zip(words, words[1:]))
        if ms >= 0 and (now & script) - previous:
            return ms - first_word_end
        previous = now
    return None


def analyze_run(run, scenario, clock, loopback_ms=0):
    origin = audio_origin_ms(run["events"])
    out = {"name": run["name"], "errors": list(run["meta"].get("errors", [])), "expect": {}, "forbidden": {}, "details": []}
    if origin is None:
        out["errors"].append("no audio_play event; the observer did not play the stimulus")
        origin = 0
    rows = timeline(run["events"], origin)
    speech_end = max((e for _, e, _ in clock if e is not None), default=0)
    for item in scenario["expect"]:
        (kind, value), = item["probe"].items()
        end = common.phrase_end_ms(clock, item["after"])
        at, note = probe_ms(kind, value, rows)
        if note:
            out["errors"].append(f"{item['id']}: {note}")
        out["expect"][item["id"]] = {
            "phrase_end_ms": end, "probe_ms": at,
            "latency_ms": None if at is None else at - end - loopback_ms,
        }
    dispatches = [t - origin for t, cat, msg in run["log"] if msg == DISPATCH]
    early = [d for d in dispatches if d < speech_end]
    planner = [t - origin for t, cat, msg in run["log"] if cat == "ActionPlanner" and msg.startswith("Planning with")]
    missing = [c for c in sorted(typed_claims(run, rows)) if squash(c.rstrip("…")) not in squash(document_text(run))]
    out["forbidden"] = {
        "take_split": len(early),
        "planner_call": len(planner),
        "duplicate_dispatch": duplicate_dispatches(run["audit"]),
        "success_without_effect": len(missing),
    }
    if early:
        out["details"].append(f"dispatched the utterance at {early} ms, before speech ended at {speech_end} ms")
    if planner:
        out["details"].append(f"planner started at {planner} ms")
    if missing:
        claimed = [ms for ms, e in rows if e["event"] == "hud" and TYPED.search(e.get("text", ""))]
        when = f", first shown in the HUD at {claimed[0]} ms" if claimed else ""
        out["details"].append(f"typed claims {missing}{when} but the documents read back {document_text(run)!r}")
    for fired in run["meta"].get("planner_guard_fired_at", []):
        out["details"].append(f"the rig cancelled the app at {fired - origin} ms because the planner started; later expectations are unmeasured")
    first_word = next((c for c in clock if c[1] is not None), None)
    during = [ms for ms, e in rows if e["event"] == "hud" and first_word and first_word[0] <= ms <= speech_end]
    out["hud"] = {
        "first_words_ms": first_words_ms(rows, scenario, first_word[1]) if first_word else None,
        "updates_during_speech": len(during),
        "max_gap_ms": max((b - a for a, b in zip(during, during[1:])), default=None),
    }
    out["documents"] = None if run["documents"] is None else len(run["documents"])
    stats = next((e for e in run["events"] if e["event"] == "poll_stats"), {})
    out["max_poll_ms"] = {k: stats[k]["max_poll_ms"] for k in ("workspace", "targets", "hud") if k in stats}
    out["icloud_files"] = run["meta"].get("icloud_files", [])
    out["settled"] = run["meta"].get("settled")
    out["loadavg"] = run["meta"].get("loadavg_after")
    out["jitter_ms"] = run["meta"].get("jitter_ms")
    return out


def summarize(results, scenario):
    n = len(results)
    expectations = {}
    for item in scenario["expect"]:
        latencies = [r["expect"][item["id"]]["latency_ms"] for r in results]
        p50, p90 = common.percentile(latencies, 50), common.percentile(latencies, 90)
        p90_budget = item.get("budget_p90_ms", DEFAULT_P90_BUDGET_MS)
        expectations[item["id"]] = {
            "after": item["after"], "budget_ms": item["budget_ms"], "budget_p90_ms": p90_budget,
            "p50_ms": p50, "p90_ms": p90, "missed": sum(v is None for v in latencies),
            "within_budget": sum(v is not None and v <= item["budget_ms"] for v in latencies),
            "pass": p50 is not None and p90 is not None and p50 <= item["budget_ms"] and p90 <= p90_budget,
        }
    forbidden = {}
    for name in common.FORBIDDEN_EVENTS:
        counts = [r["forbidden"][name] for r in results]
        forbidden[name] = {"runs_affected": sum(c > 0 for c in counts), "total": sum(counts), "rate": sum(c > 0 for c in counts) / n if n else 0,
                           "forbidden_by_scenario": name in scenario["forbid"]}
    errors = [f"{r['name']}: {e}" for r in results for e in r["errors"]]
    leaks = [f"{r['name']}: {f}" for r in results for f in r["icloud_files"]]
    reasons = [f"{k} misses its budget" for k, v in expectations.items() if not v["pass"]]
    reasons += [f"{k} in {v['runs_affected']}/{n} runs" for k, v in forbidden.items() if v["forbidden_by_scenario"] and v["total"]]
    reasons += errors + [f"iCloud autosave {leak}" for leak in leaks]
    return {"scenario": scenario["name"], "runs": n, "pass": not reasons, "reasons": reasons,
            "expectations": expectations, "forbidden": forbidden}


def ms(value):
    return "miss" if value is None else f"{value:+d}" if isinstance(value, int) else str(value)


def render(results, verdict, scenario, loopback_ms):
    lines = [f"# Live actions report: {scenario['name']}", "",
             f"{verdict['runs']} runs. Verdict: **{'PASS' if verdict['pass'] else 'FAIL'}**."]
    lines += [f"- {reason}" for reason in verdict["reasons"]]
    lines += ["", f"Latency is probe time minus phrase end, in ms, less a loopback delay of {loopback_ms} ms (not calibrated unless set with --loopback-ms). Negative means before the phrase ended.",
              "", "## Expectations", "", "| id | after | budget p50/p90 | p50 | p90 | within budget | missed |", "|---|---|---|---|---|---|---|"]
    for key, v in verdict["expectations"].items():
        lines.append(f"| {key} | {v['after']} | {v['budget_ms']}/{v['budget_p90_ms']} | {ms(v['p50_ms'])} | {ms(v['p90_ms'])} | {v['within_budget']}/{verdict['runs']} | {v['missed']} |")
    lines += ["", "## Forbidden events", "", "| event | runs affected | rate | total | forbidden by scenario |", "|---|---|---|---|---|"]
    for key, v in verdict["forbidden"].items():
        lines.append(f"| {key} | {v['runs_affected']}/{verdict['runs']} | {v['rate']:.0%} | {v['total']} | {'yes' if v['forbidden_by_scenario'] else 'no'} |")
    ids = list(verdict["expectations"])
    lines += ["", "## Runs", "", "| run | jitter | " + " | ".join(ids) + " | split | planner | duplicate | no effect | docs | first words | max poll ms (ws/ax/hud) | load |",
              "|---|---|" + "---|" * (len(ids) + 8)]
    for r in results:
        cells = [ms(r["expect"][i]["latency_ms"]) for i in ids]
        f, h = r["forbidden"], r["hud"]
        lines.append(f"| {r['name']} | {r['jitter_ms']} | " + " | ".join(cells) +
                     f" | {f['take_split']} | {f['planner_call']} | {f['duplicate_dispatch']} | {f['success_without_effect']} | {r['documents'] if r['documents'] is not None else '-'} | {ms(h['first_words_ms'])} | {'/'.join(str(v) for v in r['max_poll_ms'].values()) or '-'} | {r['loadavg']} |")
    lines += ["", "## Evidence for flagged events", ""]
    for r in results:
        for detail in r["details"] + r["errors"]:
            lines.append(f"- {r['name']}: {detail}")
        if r["icloud_files"]:
            lines.append(f"- {r['name']}: **autosaved into iCloud and moved to ~/.Trash:** {r['icloud_files']}")
        if r["settled"] is False:
            lines.append(f"- {r['name']}: an action session was still running when the rig stopped waiting")
    return "\n".join(lines) + "\n"


def write(root, loopback_ms=0):
    root = Path(root)
    scenario = json.loads((root / "scenario.json").read_text())
    clock = common.read_clock(root / "speech-clock.tsv")
    results = [analyze_run(load_run(d), scenario, clock, loopback_ms) for d in sorted(root.glob("run-*"))]
    verdict = summarize(results, scenario)
    verdict["loopback_ms"] = loopback_ms
    (root / "verdict.json").write_text(json.dumps({**verdict, "per_run": results}, indent=1))
    markdown = render(results, verdict, scenario, loopback_ms)
    (root / "report.md").write_text(markdown)
    print(markdown)
    return verdict


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("runs_dir")
    parser.add_argument("--loopback-ms", type=int, default=0, help="measured delay from playback to the app hearing it")
    args = parser.parse_args()
    write(args.runs_dir, args.loopback_ms)
