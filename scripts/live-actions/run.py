#!/usr/bin/env python3
"""Play a scenario's speech into the real Superkeet app through BlackHole and record what appears on screen.

usage: run.py <scenario.json> [--runs N] [--seed S]

The rig points Superkeet at BlackHole 2ch, relaunches it, and for each run starts a unified-log capture, runs
the observer, reads the TextEdit documents back, and tears the target apps down. Everything it changed is
restored in a finally block and on SIGINT or SIGTERM. Evidence goes under .build/live-actions/runs/<timestamp>/.
"""

import argparse
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_stimulus  # noqa: E402
import common  # noqa: E402
import report  # noqa: E402

DOMAIN = common.APP_BUNDLE_ID
LOG_PREDICATE = f'subsystem == "{DOMAIN}" AND processImagePath == "{common.APP}/Contents/MacOS/Superkeet"'
OBSERVER_SRC = Path(__file__).resolve().parent / "observer.swift"
OBSERVER = common.BUILD / "observer"
RESTORE_FILE = common.BUILD / "restore.json"
ICLOUD = Path.home() / "Library/Mobile Documents/com~apple~TextEdit/Documents"
TEXTEDIT = "com.apple.TextEdit"
AUDIT = Path.home() / "Library/Application Support/Superkeet/action-audit.log"
LEAD_BASE_MS = 1500
JITTER_MS = 500
TAIL_MS = 6000
SETTLE_SECONDS = 25
children = []


def sh(cmd, timeout=30, check=False):
    return subprocess.run([str(c) for c in cmd], capture_output=True, text=True, timeout=timeout, check=check)


def osa(script, language="AppleScript"):
    return sh(["osascript", "-l", language, "-e", script], timeout=20).stdout.strip()


def say(message):
    print(f"[{datetime.now():%H:%M:%S}] {message}", flush=True)


def defaults_read(key):
    result = sh(["defaults", "read", DOMAIN, key])
    return result.stdout.strip() if result.returncode == 0 else None


class LogStream:
    """`log stream` of the installed app into a file, so a run can replay it with millisecond timestamps.

    The process filter matters. `swift test` runs of the same code log under the same subsystem."""

    def __init__(self, path):
        self.path = Path(path)
        self.proc = None

    def start(self):
        self.file = open(self.path, "wb")
        self.proc = subprocess.Popen(
            ["log", "stream", "--style", "ndjson", "--level", "debug", "--predicate", LOG_PREDICATE],
            stdout=self.file, stderr=subprocess.DEVNULL, start_new_session=True,
        )
        children.append(self.proc)
        deadline = time.time() + 5
        while self.path.stat().st_size == 0 and time.time() < deadline:
            time.sleep(0.05)
        time.sleep(0.3)

    def text(self):
        return self.path.read_text(errors="replace")

    def wait_for(self, needle, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in self.text():
                return True
            time.sleep(0.2)
        return False

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)
            try:
                self.proc.wait(3)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self.file.close()


def superkeet_running():
    return sh(["pgrep", "-f", str(common.APP / "Contents/MacOS/Superkeet")]).returncode == 0


def daemon_line():
    lines = sh(["pgrep", "-fl", "parakeet serve"]).stdout.strip().splitlines()
    return lines[0] if lines else None


def daemon_device():
    line = daemon_line()
    match = re.search(r"--device (.+?)(?= --[a-z-]+ |$)", line or "")
    return match.group(1) if match else None


def quit_superkeet():
    osa(f'if application id "{DOMAIN}" is running then tell application id "{DOMAIN}" to quit')
    deadline = time.time() + 10
    while (superkeet_running() or daemon_line()) and time.time() < deadline:
        time.sleep(0.2)
    if daemon_line():
        sh(["pkill", "-f", "parakeet serve --socket"])
        time.sleep(0.5)


def relaunch_superkeet(expect_device):
    """Quit and reopen the app until the daemon runs with expect_device (None means no --device flag)."""
    quit_superkeet()
    stream = LogStream(common.BUILD / "setup-log.ndjson")
    stream.start()
    try:
        sh(["open", common.APP], check=True)
        if not stream.wait_for("Speech engine ready", 60):
            raise RuntimeError("Superkeet did not log 'Speech engine ready' within 60 s")
    finally:
        stream.stop()
    time.sleep(1.0)
    if daemon_device() != expect_device:
        raise RuntimeError(f"daemon runs with --device {daemon_device()!r}, expected {expect_device!r}: {daemon_line()}")


def set_device(device):
    if device is None:
        sh(["defaults", "delete", DOMAIN, "audioInputDevice"])
    else:
        sh(["defaults", "write", DOMAIN, "audioInputDevice", "-string", device], check=True)


def converge_device(device, relaunch_if_stopped):
    """Make the defaults key and the running daemon agree with device. Safe to call twice."""
    set_device(device)
    running = superkeet_running()
    if (running or relaunch_if_stopped) and not (running and daemon_device() == device):
        relaunch_superkeet(device)


def remember_original():
    """Record the user's audioInputDevice once. restore.json survives a crash, so the next run restores from it."""
    if RESTORE_FILE.exists():
        return json.loads(RESTORE_FILE.read_text())
    current = defaults_read("audioInputDevice")
    if current == common.LOOPBACK_DEVICE:
        say(f"WARNING: audioInputDevice is already {current} and no restore record exists. Treating the original as unset.")
        current = None
    state = {"audioInputDevice": current, "superkeet_was_running": superkeet_running()}
    RESTORE_FILE.parent.mkdir(parents=True, exist_ok=True)
    RESTORE_FILE.write_text(json.dumps(state))
    return state


def restore(state):
    converge_device(state["audioInputDevice"], state["superkeet_was_running"])
    RESTORE_FILE.unlink(missing_ok=True)
    say(f"restored audioInputDevice to {state['audioInputDevice']!r}, daemon device {daemon_device()!r}")


def textedit_running():
    return sh(["pgrep", "-x", "TextEdit"]).returncode == 0


def textedit_documents():
    raw = osa(
        'const app = Application("com.apple.TextEdit");'
        "JSON.stringify(app.running() ? app.documents().map(d => ({name: d.name(), text: d.text()})) : null)",
        "JavaScript",
    )
    return json.loads(raw) if raw else None


def quit_textedit():
    script = f'if application id "{TEXTEDIT}" is running then tell application id "{TEXTEDIT}" to '
    osa(script + "close every document saving no")
    osa(script + "quit")
    deadline = time.time() + 5
    while textedit_running() and time.time() < deadline:
        time.sleep(0.2)
    if textedit_running():
        sh(["pkill", "-x", "TextEdit"])
        time.sleep(0.5)


def prepare_start_state(scenario):
    for bundle, state in scenario["start_state"].items():
        if bundle == TEXTEDIT and state == "quit" and textedit_running():
            holding = [d["name"] for d in (textedit_documents() or []) if d["text"].strip()]
            if holding:
                raise SystemExit(f"TextEdit holds text in {holding}. Close it yourself first; the rig will not discard your work.")
            quit_textedit()


def icloud_files():
    return set(os.listdir(ICLOUD)) if ICLOUD.exists() else set()


def trash_new_icloud_files(before):
    moved = []
    for name in sorted(icloud_files() - before):
        target = Path.home() / ".Trash" / f"live-actions-{int(time.time())}-{name}"
        shutil.move(str(ICLOUD / name), target)
        moved.append(name)
    return moved


def audit_rows_since(start_epoch_s):
    if not AUDIT.exists():
        return []
    rows = []
    for line in AUDIT.read_text(errors="replace").splitlines():
        try:
            stamp = datetime.strptime(json.loads(line)["timestamp"], "%Y-%m-%dT%H:%M:%SZ")
        except (ValueError, KeyError):
            continue
        if stamp.replace(tzinfo=timezone.utc).timestamp() >= start_epoch_s:
            rows.append(line)
    return rows


def count_messages(log, prefix):
    return sum(1 for _, _, message in common.parse_log(log.text()) if message.startswith(prefix))


def settle(log, hotkey):
    """Wait for every dispatched utterance to finish its action session, then make sure no listening session is left."""
    deadline = time.time() + SETTLE_SECONDS
    settled = False
    while time.time() < deadline:
        if count_messages(log, "Action session finished") >= count_messages(log, "Pause detected"):
            settled = True
            break
        time.sleep(0.5)
    for _ in range(2):
        if count_messages(log, "Listening session started") <= count_messages(log, "Listening session ended"):
            break
        sh([OBSERVER, "press", "--hotkey-code", hotkey["code"], "--hotkey-flags", hotkey["flags"]])
        time.sleep(1.0)
    return settled


def one_run(scenario, stimulus, run_dir, rng, hotkey):
    run_dir.mkdir(parents=True)
    prepare_start_state(scenario)
    before = icloud_files()
    log = LogStream(run_dir / "log.ndjson")
    log.start()
    meta = {"started": datetime.now().isoformat(timespec="milliseconds"), "jitter_ms": rng.randint(0, JITTER_MS),
            "loadavg_before": round(os.getloadavg()[0], 2)}
    meta["lead_ms"] = LEAD_BASE_MS + meta["jitter_ms"]
    documents = {"tail": None, "final": None}
    start_epoch = time.time()
    cmd = [OBSERVER, "play", "--wav", stimulus["wav48"], "--out-device", common.LOOPBACK_DEVICE,
           "--hotkey-code", hotkey["code"], "--hotkey-flags", hotkey["flags"], "--lead-ms", meta["lead_ms"], "--tail-ms", TAIL_MS]
    for bundle in common.scenario_targets(scenario):
        cmd += ["--target", bundle]
    duration_s = json.loads(stimulus["meta"].read_text())["duration_ms"] / 1000
    try:
        with open(run_dir / "observer.ndjson", "w") as out:
            proc = subprocess.Popen([str(c) for c in cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            children.append(proc)
            watchdog = threading.Timer(duration_s + meta["lead_ms"] / 1000 + TAIL_MS / 1000 + 60, proc.kill)
            watchdog.start()
            for line in proc.stdout:
                out.write(line)
                out.flush()
                if '"event":"tail_done"' in line:
                    sh(["cua-driver", "call", "get_desktop_state", json.dumps({"screenshot_out_file": str(run_dir / "hud-end.png"), "max_image_dimension": 1800})], timeout=20)
                    documents["tail"] = textedit_documents()
                    proc.stdin.write("stop\n")
                    proc.stdin.flush()
            proc.wait()
            watchdog.cancel()
        meta["observer_exit"] = proc.returncode
        meta["loadavg_after"] = round(os.getloadavg()[0], 2)
        time.sleep(1.0)
        meta["settled"] = settle(log, hotkey)
        time.sleep(0.8)
        documents["final"] = textedit_documents()
    finally:
        log.stop()
        (run_dir / "documents.json").write_text(json.dumps(documents))
        (run_dir / "audit.ndjson").write_text("\n".join(audit_rows_since(int(start_epoch) - 1)) + "\n")
        quit_textedit()
        time.sleep(1.5)
        meta["icloud_files"] = trash_new_icloud_files(before)
        (run_dir / "meta.json").write_text(json.dumps(meta, indent=1))
    if meta["icloud_files"]:
        say(f"ERROR: TextEdit autosaved {meta['icloud_files']} into iCloud during this run. Moved to ~/.Trash.")
    return meta


def compile_observer():
    if OBSERVER.exists() and OBSERVER.stat().st_mtime >= OBSERVER_SRC.stat().st_mtime:
        return
    OBSERVER.parent.mkdir(parents=True, exist_ok=True)
    say("compiling the observer")
    sh(["swiftc", "-O", "-swift-version", "5", "-suppress-warnings", OBSERVER_SRC, "-o", OBSERVER], timeout=300, check=True)


def preflight():
    if not common.APP.exists():
        raise SystemExit(f"{common.APP} is not installed")
    for key in ("actionsEnabled", "hasCompletedOnboarding"):
        if defaults_read(key) != "1":
            raise SystemExit(f"{key} is not enabled in {DOMAIN}; finish onboarding and enable Actions Mode first")
    compile_observer()
    check = sh([OBSERVER, "check", "--out-device", common.LOOPBACK_DEVICE])
    if check.returncode != 0:
        raise SystemExit(f"observer check failed. Needs Accessibility for this terminal and the BlackHole 2ch device.\n{check.stdout}")
    if not shutil.which("cua-driver"):
        say("WARNING: cua-driver not found; the end-of-run HUD screenshot will be missing")


def read_hotkey():
    code, flags = defaults_read("commandHotkeyKeyCode"), defaults_read("commandHotkeyModifierFlags")
    if code is None or flags is None:
        raise SystemExit("commandHotkeyKeyCode or commandHotkeyModifierFlags is not set; open Superkeet settings once")
    return {"code": code, "flags": flags}


def on_signal(signum, _frame):
    raise KeyboardInterrupt(f"signal {signum}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("scenario")
    parser.add_argument("--runs", type=int, default=1)
    parser.add_argument("--seed", type=int)
    args = parser.parse_args()
    scenario = common.load_scenario(args.scenario)
    preflight()
    hotkey = read_hotkey()
    stimulus = build_stimulus.build(args.scenario)
    root = common.BUILD / "runs" / datetime.now().strftime("%Y%m%d-%H%M%S")
    root.mkdir(parents=True)
    shutil.copy(args.scenario, root / "scenario.json")
    shutil.copy(stimulus["clock"], root / "speech-clock.tsv")
    rng = random.Random(args.seed)
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    original = remember_original()
    leaks = 0
    try:
        converge_device(common.LOOPBACK_DEVICE, True)
        say(f"daemon: {daemon_line()}")
        for i in range(1, args.runs + 1):
            say(f"run {i}/{args.runs}")
            leaks += bool(one_run(scenario, stimulus, root / f"run-{i:02d}", rng, hotkey)["icloud_files"])
            time.sleep(2)
    except KeyboardInterrupt as stop:
        say(f"interrupted ({stop}); restoring")
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
        quit_textedit()
        restore(original)
    report.write(root)
    say(f"report: {root / 'report.md'}")
    sys.exit(3 if leaks else 0)


if __name__ == "__main__":
    main()
