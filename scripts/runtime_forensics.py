#!/usr/bin/env python3
"""Measure Superkeet and parakeet-cli startup and transcription on macOS."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import signal
import socket
import statistics
import subprocess
import time
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MODEL = Path.home() / "Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3"
DEFAULT_ENGINE = ROOT.parent.parent / "Formulae/parakeet-cli/target/release/parakeet"
DEFAULT_APP = ROOT / ".build/verification/Superkeet.app"
DEFAULT_FIXTURE = ROOT / "Tests/Fixtures/demo-actions/demo-audio.wav"
APP_SOCKET = Path.home() / "Library/Caches/com.superkeet.app/Runtime/parakeet.sock"


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_report(path, metadata, runs):
    path.parent.mkdir(parents=True, exist_ok=True)
    successful = [run for run in runs if run.get("error") is None]
    metrics = {
        "engine-startup": ["ready_seconds", "idle_cpu_percent", "ready_rss_mib"],
        "app-startup": ["process_seconds", "ready_seconds", "app_idle_cpu_percent", "engine_idle_cpu_percent", "app_ready_rss_mib", "engine_ready_rss_mib"],
        "transcribe": [
            "wall_seconds", "engine_inference_seconds", "vad_seconds", "mel_seconds", "encoder_seconds",
            "decoder_seconds", "user_seconds", "system_seconds", "max_rss_mib",
        ],
    }[metadata["mode"]]
    summary = summarize(successful, metrics)
    report = {"metadata": metadata, "summary": summary, "runs": runs}
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(path)


def summarize(runs, metrics):
    result = {"run_count": len(runs), "metrics": {}}
    for metric in metrics:
        values = [float(run[metric]) for run in runs if metric in run]
        if values:
            result["metrics"][metric] = {
                "median": statistics.median(values),
                "min": min(values),
                "max": max(values),
            }
    return result


def socket_command(path, command, timeout=0.25):
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(timeout)
        client.connect(str(path))
        client.sendall(command.encode() + b"\n")
        chunks = []
        while True:
            chunk = client.recv(65536)
            if not chunk or chunk.endswith(b"\n"):
                chunks.append(chunk)
                break
            chunks.append(chunk)
    return json.loads(b"".join(chunks))


def wait_for_ready(process, socket_path, timeout=60):
    started = time.perf_counter()
    deadline = started + timeout
    while time.perf_counter() < deadline:
        if process is not None and process.poll() is not None:
            raise RuntimeError(f"process exited during startup with code {process.returncode}")
        try:
            response = socket_command(socket_path, "status")
            if response.get("status") == "ok" and response.get("state") == "idle":
                if response.get("protocol_version") != 2:
                    raise RuntimeError(f"unexpected protocol response: {response}")
                return time.perf_counter() - started, response
        except (OSError, TimeoutError, json.JSONDecodeError):
            pass
        time.sleep(0.005)
    raise TimeoutError(f"engine did not become ready at {socket_path}")


def rss_mib(pid):
    output = subprocess.check_output(["ps", "-p", str(pid), "-o", "rss="], text=True)
    return int(output.strip()) / 1024


def idle_cpu(pid, seconds):
    output = subprocess.check_output(
        ["top", "-l", "2", "-s", str(seconds), "-pid", str(pid), "-stats", "pid,cpu,mem,time"],
        text=True,
    )
    rows = [line.split() for line in output.splitlines() if line.startswith(str(pid) + " ")]
    if not rows:
        raise RuntimeError(f"top returned no sample for pid {pid}")
    return float(rows[-1][1])


def stop_engine(process, socket_path):
    if process.poll() is not None:
        return
    try:
        socket_command(socket_path, "shutdown")
    except (OSError, TimeoutError, json.JSONDecodeError):
        process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


def engine_startup_once(index, directory, engine, model, idle_seconds):
    directory.mkdir(parents=True, exist_ok=True)
    socket_path = directory / "daemon.sock"
    pid_path = directory / "daemon.pid"
    record = {"run": index, "error": None}
    with (directory / "stdout.log").open("w") as stdout, (directory / "stderr.log").open("w") as stderr:
        started = time.perf_counter()
        process = subprocess.Popen(
            [str(engine), "serve", "--socket", str(socket_path), "--pid-file", str(pid_path), "--model-dir", str(model)],
            stdout=stdout,
            stderr=stderr,
        )
        record["pid"] = process.pid
        try:
            record["ready_seconds"], response = wait_for_ready(process, socket_path)
            record["protocol_response"] = response
            record["ready_rss_mib"] = rss_mib(process.pid)
            record["idle_cpu_percent"] = idle_cpu(process.pid, idle_seconds)
            record["work_verified"] = True
        except Exception as error:
            record["error"] = str(error)
        finally:
            stop_engine(process, socket_path)
            record["exit_code"] = process.returncode
    return record


def running_app_pids():
    result = subprocess.run(["pgrep", "-x", "Superkeet"], text=True, capture_output=True)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip())
    return [int(value) for value in result.stdout.split()]


def stop_app(pid):
    if pid is None:
        return
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    deadline = time.perf_counter() + 15
    while time.perf_counter() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return
        time.sleep(0.05)
    raise RuntimeError(f"Superkeet pid {pid} did not exit after SIGTERM")


def app_startup_once(index, directory, app, idle_seconds):
    directory.mkdir(parents=True, exist_ok=True)
    record = {"run": index, "error": None}
    if running_app_pids():
        record["error"] = "refusing to start while another Superkeet process exists"
        return record
    try:
        response = socket_command(APP_SOCKET, "status")
    except (OSError, TimeoutError, json.JSONDecodeError):
        response = None
    if response is not None:
        record["error"] = f"refusing to start while an engine already answers at {APP_SOCKET}: {response}"
        return record
    started = time.perf_counter()
    subprocess.run(["open", str(app)], check=True)
    app_pid = None
    try:
        while app_pid is None and time.perf_counter() - started < 10:
            pids = running_app_pids()
            if pids:
                if len(pids) != 1:
                    raise RuntimeError(f"unexpected Superkeet pids: {pids}")
                app_pid = pids[0]
            else:
                time.sleep(0.005)
        if app_pid is None:
            raise TimeoutError("Superkeet process did not appear")
        record["app_pid"] = app_pid
        record["process_seconds"] = time.perf_counter() - started
        ready_start = time.perf_counter()
        while time.perf_counter() - ready_start < 60:
            try:
                response = socket_command(APP_SOCKET, "status")
                if response.get("status") == "ok" and response.get("state") == "idle":
                    break
            except (OSError, TimeoutError, json.JSONDecodeError):
                pass
            if not running_app_pids():
                raise RuntimeError("Superkeet exited during startup")
            time.sleep(0.005)
        else:
            raise TimeoutError(f"engine did not become ready at {APP_SOCKET}")
        record["ready_seconds"] = time.perf_counter() - started
        record["protocol_response"] = response
        engine_pid = int((APP_SOCKET.parent / "parakeet.pid").read_text().strip())
        record["engine_pid"] = engine_pid
        record["app_ready_rss_mib"] = rss_mib(app_pid)
        record["engine_ready_rss_mib"] = rss_mib(engine_pid)
        record["app_idle_cpu_percent"] = idle_cpu(app_pid, idle_seconds)
        record["engine_idle_cpu_percent"] = idle_cpu(engine_pid, idle_seconds)
        record["work_verified"] = True
    except Exception as error:
        record["error"] = str(error)
    finally:
        stop_app(app_pid)
        record["app_exited"] = app_pid is not None and app_pid not in running_app_pids()
    return record


def validate_transcript(result):
    text = result.get("text", "")
    checks = {
        "status_ok": result.get("status") == "ok",
        "no_failed_segments": result.get("failed_segments") == 0,
        "no_dropped_samples": result.get("dropped_samples") == 0,
        "audio_duration_present": float(result.get("duration", 0)) > 0,
        "inference_present": float(result.get("inference_time", 0)) > 0,
        "known_speech_present": "Norbert Wiener" in text and "notes app" in text,
    }
    failed = [name for name, passed in checks.items() if not passed]
    if failed:
        raise RuntimeError(f"transcript validation failed: {', '.join(failed)}")
    return checks


def transcribe_once(index, directory, engine, model, fixture, coreml=False):
    directory.mkdir(parents=True, exist_ok=True)
    record = {"run": index, "error": None}
    command = [
        "/usr/bin/time", "-l", str(engine), "transcribe", str(fixture), "--session",
        "--format", "json", "--model-dir", str(model),
    ]
    if coreml:
        command.append("--coreml")
    started = time.perf_counter()
    completed = subprocess.run(command, text=True, capture_output=True, timeout=120)
    record["wall_seconds"] = time.perf_counter() - started
    (directory / "stdout.json").write_text(completed.stdout)
    (directory / "stderr-time.txt").write_text(completed.stderr)
    record["exit_code"] = completed.returncode
    try:
        if completed.returncode != 0:
            raise RuntimeError(f"transcription exited {completed.returncode}: {completed.stderr[-500:]}")
        result = json.loads(completed.stdout)
        record["validation"] = validate_transcript(result)
        record["engine_inference_seconds"] = result["inference_time"]
        for stage, seconds in result.get("stages", {}).items():
            record[f"{stage}_seconds"] = seconds
        record["audio_seconds"] = result["duration"]
        record["transcript_sha256"] = hashlib.sha256(result["text"].encode()).hexdigest()
        timing = re.search(r"^\s*([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys", completed.stderr, re.MULTILINE)
        memory = re.search(r"^\s*(\d+)\s+maximum resident set size", completed.stderr, re.MULTILINE)
        if not timing or not memory:
            raise RuntimeError("could not parse /usr/bin/time resource report")
        record["user_seconds"] = float(timing.group(2))
        record["system_seconds"] = float(timing.group(3))
        record["max_rss_mib"] = int(memory.group(1)) / (1024 * 1024)
        record["work_verified"] = True
    except Exception as error:
        record["error"] = str(error)
    return record


def metadata_for(args, engine):
    return {
        "schema_version": 1,
        "mode": args.mode,
        "started_at": utc_now(),
        "host": platform.platform(),
        "machine": platform.machine(),
        "core_count": os.cpu_count(),
        "load_average": os.getloadavg(),
        "engine": str(engine),
        "engine_sha256": sha256(engine),
        "engine_protocol": subprocess.check_output([str(engine), "protocol-version"], text=True).strip(),
        "model_dir": str(args.model_dir),
        "model_variant": (args.model_dir / ".variant").read_text().strip() if (args.model_dir / ".variant").exists() else "unknown",
        "fixture": str(args.fixture) if args.mode == "transcribe" else None,
        "fixture_sha256": sha256(args.fixture) if args.mode == "transcribe" else None,
        "coreml": args.coreml if args.mode == "transcribe" else None,
        "app": str(args.app) if args.mode == "app-startup" else None,
        "app_version": plistlib.loads((args.app / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"] if args.mode == "app-startup" else None,
        "requested_runs": args.runs,
        "idle_seconds_per_metric": args.idle_seconds,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["engine-startup", "app-startup", "transcribe"])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--idle-seconds", type=int, default=2)
    parser.add_argument("--engine", type=Path, default=DEFAULT_ENGINE)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--fixture", type=Path, default=DEFAULT_FIXTURE)
    parser.add_argument("--coreml", action="store_true")
    args = parser.parse_args()
    if args.runs < 1 or args.idle_seconds < 1:
        parser.error("--runs and --idle-seconds must be positive")
    if args.coreml and args.mode != "transcribe":
        parser.error("--coreml is only valid with transcribe")
    engine = args.app.resolve() / "Contents/Resources/bin/parakeet" if args.mode == "app-startup" else args.engine.resolve()
    if not engine.is_file() or not os.access(engine, os.X_OK):
        parser.error(f"engine is not executable: {engine}")
    if not args.model_dir.is_dir():
        parser.error(f"model directory does not exist: {args.model_dir}")
    if args.mode == "app-startup" and not args.app.is_dir():
        parser.error(f"app bundle does not exist: {args.app}")
    if args.mode == "transcribe" and not args.fixture.is_file():
        parser.error(f"fixture does not exist: {args.fixture}")

    metadata = metadata_for(args, engine)
    runs = []
    write_report(args.output, metadata, runs)
    for index in range(1, args.runs + 1):
        directory = args.output.parent / f"run-{index:02d}"
        if args.mode == "engine-startup":
            record = engine_startup_once(index, directory, engine, args.model_dir, args.idle_seconds)
        elif args.mode == "app-startup":
            record = app_startup_once(index, directory, args.app.resolve(), args.idle_seconds)
        else:
            record = transcribe_once(index, directory, engine, args.model_dir, args.fixture.resolve(), args.coreml)
        runs.append(record)
        write_report(args.output, metadata, runs)
        print(json.dumps({"mode": args.mode, **record}))
    if any(run["error"] for run in runs):
        raise SystemExit(1)
    if args.mode == "transcribe" and len({run["transcript_sha256"] for run in runs}) != 1:
        raise SystemExit("transcript differed across runs")


if __name__ == "__main__":
    main()
