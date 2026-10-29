#!/usr/bin/env python3
"""Collect isolated Actions feasibility evidence without production routing."""

import argparse
import ctypes
from contextlib import ExitStack
import dataclasses
import enum
import fcntl
import hashlib
import json
import math
import os
import pwd
import re
import selectors
import signal
import socket
import stat
import statistics
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/Fixtures/actions-prototype"
MAX_LINE = 8 * 1024 * 1024
SCENARIOS = {
    "legacy-wav": ("wav", "legacy-session"),
    "legacy-microphone": ("microphone", "legacy-session"),
    "notes-target": (None, "legacy-session"),
    "chrome-fixture": (None, "legacy-session"),
    "chrome-public-smoke": (None, "legacy-session"),
    "continuous-demo": (None, "continuous-turns-v1"),
    "reducer-replay": ("protocol-events", "reducer-replay"),
    "native-adapters": (None, "native-adapters"),
    "integrated-prototype": (None, "integrated-prototype"),
    "legacy-gui-outcome": (None, "legacy-session"),
}


class State(str, enum.Enum):
    VERIFIED = "VERIFIED"
    BLOCKED = "BLOCKED"
    UNSUPPORTED = "UNSUPPORTED"


class ProbeError(Exception):
    def __init__(self, code, reason):
        self.code, self.reason = code, reason
        super().__init__(reason)


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result
    def number(value):
        result = float(value)
        if not math.isfinite(result):
            raise ValueError("nonfinite JSON")
        return result
    return json.loads(data, object_pairs_hook=pairs, parse_float=number,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite JSON")))


def validate_schema(value, schema):
    if "oneOf" in schema:
        matches = 0
        for option in schema["oneOf"]:
            try:
                validate_schema(value, option)
                matches += 1
            except ValueError:
                pass
        if matches != 1:
            raise ValueError("expected exactly one schema variant")
    kinds = {"object": dict, "array": list, "string": str, "integer": int,
             "number": (int, float), "boolean": bool, "null": type(None)}
    if "type" in schema:
        kind = schema["type"]
        if not isinstance(value, kinds[kind]) or (kind in ("integer", "number") and isinstance(value, bool)):
            raise ValueError("wrong JSON type")
    if "const" in schema and (type(value) is not type(schema["const"]) or value != schema["const"]):
        raise ValueError("wrong constant")
    if "enum" in schema and not any(type(value) is type(option) and value == option for option in schema["enum"]):
        raise ValueError("unknown enum")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        if not set(schema.get("required", [])).issubset(value):
            raise ValueError("missing field")
        if schema.get("additionalProperties") is False and set(value) - set(properties):
            raise ValueError("unknown field")
        for key in value.keys() & properties.keys():
            validate_schema(value[key], properties[key])
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0) or len(value) > schema.get("maxItems", 100000):
            raise ValueError("array bound")
        for item in value:
            validate_schema(item, schema.get("items", {}))
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", MAX_LINE):
            raise ValueError("string bound")
        if "pattern" in schema and re.fullmatch(schema["pattern"], value) is None:
            raise ValueError("string pattern")
    if type(value) in (int, float):
        if value < schema.get("minimum", -float("inf")) or value > schema.get("maximum", float("inf")):
            raise ValueError("number bound")


def verify_contract_inventory():
    index = strict_json((FIXTURES / "contract-index.json").read_bytes())
    if not isinstance(index, dict) or not index or len(index) > 1000:
        raise ProbeError(2, "invalid-contract-inventory")
    for relative, expected in index.items():
        path = Path(relative)
        if path.is_absolute() or ".." in path.parts or not isinstance(expected, str):
            raise ProbeError(2, "invalid-contract-member")
        member = safe_path(str(FIXTURES / path))
        if not member.is_file() or sha256(member) != expected:
            raise ProbeError(2, "contract-member-hash-mismatch")


def sha256(path):
    path = Path(path)
    if path.is_dir():
        rows = []
        for file in sorted(path.rglob("*")):
            if file.is_symlink():
                raise ProbeError(2, "symlink-artifact")
            if file.is_file():
                rows.append([file.relative_to(path).as_posix(), sha256(file)])
        if not rows:
            raise ProbeError(2, "empty-model-inventory")
        return hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_path(value):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise ProbeError(2, "absolute-path-required")
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ProbeError(2, "symlink-path")
    return path


def within(path, parent):
    return path != parent and parent in path.parents


@dataclasses.dataclass(frozen=True)
class Manifest:
    data: dict
    digest: str
    root: Path
    source: Path

    @classmethod
    def load(cls, source):
        source = safe_path(str(source))
        raw = source.read_bytes()
        if len(raw) > 1024 * 1024:
            raise ProbeError(2, "manifest-size")
        data = strict_json(raw)
        validate_schema(data, strict_json((FIXTURES / "schemas/run-v1.json").read_bytes()))
        uuid.UUID(data["run_id"])
        root = safe_path(data["paths"]["root"])
        home = safe_path(data["account"]["home"])
        if data["account"]["uid"] in (0, 501) or not within(root, home):
            raise ProbeError(2, "primary-or-unsafe-account")
        for value in data["paths"].values():
            path = safe_path(value)
            if path != root and not within(path, root):
                raise ProbeError(2, "path-outside-run-root")
        for artifact in data["artifacts"].values():
            safe_path(artifact["path"])
        item = data["input"]
        if "path" in item:
            safe_path(item["path"])
        if data["contract_sha256"] != sha256(FIXTURES / "contract-index.json"):
            raise ProbeError(2, "contract-hash-mismatch")
        verify_contract_inventory()
        return cls(data, hashlib.sha256(raw).hexdigest(), root, source)

    def environment(self, desktop=False):
        account = self.data["account"]
        if os.getuid() in (0, 501) or os.getuid() != os.geteuid() or os.getuid() != account["uid"]:
            raise ProbeError(3, "disposable-account-required")
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        if home != Path(account["home"]) or Path(os.environ.get("HOME", "")) != home:
            raise ProbeError(2, "account-home-mismatch")
        if desktop and (sys.platform != "darwin" or os.stat("/dev/console").st_uid != os.getuid()):
            raise ProbeError(3, "disposable-console-required")
        for path in (home, self.root, self.source):
            safe_path(str(path))
            if not path.exists() or path.stat().st_uid != os.getuid():
                raise ProbeError(2, "path-owner-mismatch")
        if self.root.stat().st_mode & 0o077:
            raise ProbeError(2, "private-run-root-required")
        for role, artifact in self.data["artifacts"].items():
            build = artifact["build_receipt"]
            if sha256(safe_path(build["path"])) != build["sha256"]:
                raise ProbeError(2, "build-receipt-hash-mismatch")
            provenance = strict_json(Path(build["path"]).read_bytes())
            if provenance.get("source_sha") != artifact["source_sha"] or provenance.get("binary_sha256") != artifact["sha256"]:
                raise ProbeError(2, "build-input-provenance-mismatch")
            path = safe_path(artifact["path"])
            if sha256(path) != artifact["sha256"]:
                raise ProbeError(2, "artifact-hash-mismatch")
            if role != "model" and not os.access(path, os.X_OK):
                raise ProbeError(2, "artifact-not-executable")
        enrollment = self.data["account"]["operator_receipt"]
        if sha256(safe_path(enrollment["path"])) != enrollment["sha256"]:
            raise ProbeError(2, "operator-receipt-mismatch")
        item = self.data["input"]
        if "path" in item and sha256(item["path"]) != item["sha256"]:
            raise ProbeError(2, "input-hash-mismatch")

    def output(self, value):
        out = safe_path(str(value))
        if not within(out, self.root) or out.exists():
            raise ProbeError(2, "new-isolated-output-required")
        if not out.parent.is_dir() or out.parent.stat().st_uid != os.getuid():
            raise ProbeError(2, "output-parent-owner")
        return out


class BSDInfo(ctypes.Structure):
    _fields_ = [(name, ctypes.c_uint32) for name in (
        "flags", "status", "xstatus", "pid", "ppid", "uid", "gid", "ruid", "rgid", "svuid", "svgid", "rfu")]
    _fields_ += [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)]
    _fields_ += [(name, ctypes.c_uint32) for name in ("nfiles", "pgid", "pjobc", "tdev", "tpgid", "nice")]
    _fields_ += [("start_sec", ctypes.c_uint64), ("start_usec", ctypes.c_uint64)]


def process_identity(pid):
    if sys.platform != "darwin":
        raise ProbeError(3, "macos-process-identity-required")
    lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    info, buffer = BSDInfo(), ctypes.create_string_buffer(4096)
    if lib.proc_pidinfo(pid, 3, 0, ctypes.byref(info), ctypes.sizeof(info)) != ctypes.sizeof(info):
        raise ProbeError(2, "process-not-observable")
    if lib.proc_pidpath(pid, buffer, len(buffer)) <= 0:
        raise ProbeError(2, "process-path-not-observable")
    executable = buffer.value.decode()
    return {"pid": pid, "uid": info.uid, "ppid": info.ppid,
            "start_us": info.start_sec * 1000000 + info.start_usec,
            "executable": executable, "sha256": sha256(executable)}


def matches_process(expected):
    try:
        actual = process_identity(expected["pid"])
        return all(actual[key] == expected[key] for key in ("pid", "uid", "start_us", "executable", "sha256"))
    except (ProbeError, OSError):
        return False


class DesktopLease:
    def __init__(self, directory=None):
        self.directory = directory
        self.fd = None

    def __enter__(self):
        directory = self.directory or Path(subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip())
        directory = Path(directory).resolve(strict=True)
        if directory.stat().st_uid != os.getuid():
            raise ProbeError(2, "lease-parent-owner")
        path = directory / "com.superkeet.actions-probe.desktop.lock"
        self.fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        facts = os.fstat(self.fd)
        if facts.st_uid != os.getuid() or not stat.S_ISREG(facts.st_mode) or facts.st_nlink != 1:
            os.close(self.fd)
            self.fd = None
            raise ProbeError(2, "lease-file-identity")
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            os.close(self.fd)
            self.fd = None
            raise ProbeError(3, "desktop-lease-busy") from error
        return self

    def __exit__(self, *_):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


@dataclasses.dataclass
class LegacyTrace:
    session: str
    count: int = 0
    sequence: int = 0
    final: dict = None
    started: bool = False
    transcribing: bool = False

    def accept(self, event):
        if not isinstance(event, dict) or self.final is not None or event.get("session_id") != self.session:
            raise ProbeError(1, "invalid-session-or-post-terminal-event")
        kind = event.get("type")
        for key in ("audio_ms", "sequence", "failed_segments", "dropped_samples"):
            if key in event and (type(event[key]) is not int or event[key] < 0):
                raise ProbeError(1, "invalid-numeric-event-metadata")
        if "truncated" in event and type(event["truncated"]) is not bool:
            raise ProbeError(1, "invalid-truncation-metadata")
        if kind not in ("session_started", "partial", "transcribing", "complete"):
            raise ProbeError(1, "unknown-legacy-event")
        if "status" in event and (kind != "complete" or event["status"] not in ("ok", "partial", "empty", "error")):
            raise ProbeError(1, "invalid-status-metadata")
        if kind == "session_started":
            if self.count or self.started:
                raise ProbeError(1, "duplicate-or-late-session-start")
            self.started = True
        if kind == "transcribing":
            if self.transcribing:
                raise ProbeError(1, "duplicate-transcribing")
            self.transcribing = True
        if kind == "partial":
            if self.transcribing:
                raise ProbeError(1, "partial-after-transcribing")
            sequence = event.get("sequence")
            if type(sequence) is not int or sequence != self.sequence + 1 or not isinstance(event.get("text"), str):
                raise ProbeError(1, "invalid-partial-sequence")
            self.sequence = sequence
        if kind == "complete":
            if not isinstance(event.get("text"), str) or event.get("status") != "ok":
                raise ProbeError(1, "unsuccessful-completion")
            if any(type(event.get(key)) is not int or event[key] != 0 for key in ("failed_segments", "dropped_samples")):
                raise ProbeError(1, "loss-or-missing-counters")
            self.final = event
        self.count += 1
        if self.count > 100000:
            raise ProbeError(1, "event-count-limit")

    def finish(self, expected):
        if self.final is None or not expected:
            raise ProbeError(1, "completion-or-assertions-missing")
        text = self.final["text"].casefold()
        if any(phrase.casefold() not in text for phrase in expected):
            raise ProbeError(1, "required-phrase-missing")
        return {"id": "legacy-phrase-coverage", "passed": True,
                "phrase_count": len(expected), "event_count": self.count,
                "scope": "phrase-coverage-not-exact-transcript-or-desktop"}


def validate_protocol3_trace(rows):
    schema = strict_json((FIXTURES / "schemas/protocol3-event-v1.json").read_bytes())
    session, clock, published = None, None, -1
    revisions, finals, candidates = {}, {}, {}
    accepted, accounted, loss_count = 0, 0, 0
    final_failures, final_drops, bad_final = 0, 0, False
    accounted_turns, loss_ranges, loss_partitions = set(), [], []
    terminal = None
    for index, row in enumerate(rows, 1):
        validate_schema(row, schema)
        kind = row["type"]
        if terminal or row["event_id"] != index or row["published_ns"] < published:
            raise ValueError("event order or terminal violation")
        if index == 1:
            if kind != "session_started":
                raise ValueError("session start required")
            session, clock = row["session_id"], row["clock_id"]
        elif kind == "session_started":
            raise ValueError("duplicate start")
        if row["session_id"] != session or row["clock_id"] != clock:
            raise ValueError("foreign session or clock")
        published = row["published_ns"]
        for field in ("source_range", "context_range"):
            if field in row and row[field]["start"] >= row[field]["end"]:
                raise ValueError("empty or reversed source range")
        turn = row.get("turn_id")
        if kind == "audio_progress":
            if row["accepted_through"] < accepted:
                raise ValueError("source frontier regressed")
            accepted = row["accepted_through"]
        elif kind in ("turn_preview", "turn_final"):
            previous = revisions.get(turn, 0)
            if turn in finals or row["revision_id"] <= previous or row["source_range"]["end"] > accepted:
                raise ValueError("invalid speech revision or range")
            if kind == "turn_preview" and row["replaces_revision"] != previous:
                raise ValueError("unknown replacement base")
            revisions[turn] = row["revision_id"]
            if kind == "turn_final":
                owned = row["source_range"]
                if any(owned["start"] < other["end"] and other["start"] < owned["end"] for other in finals.values()):
                    raise ValueError("overlapping authoritative ownership")
                if row["status"] == "ok" and (row["failed_segments"] or row["dropped_samples"]):
                    raise ValueError("false successful final")
                finals[turn] = owned
                final_failures += row["failed_segments"]
                final_drops += row["dropped_samples"]
                bad_final = bad_final or row["status"] != "ok"
        elif kind == "turn_candidate":
            if turn in finals or row["candidate_revision"] <= candidates.get(turn, 0):
                raise ValueError("stale candidate")
            candidates[turn] = row["candidate_revision"]
        elif kind == "turn_retracted":
            if turn in finals or candidates.get(turn) != row["candidate_revision"]:
                raise ValueError("unknown or finalized candidate")
            del candidates[turn]
        elif kind == "source_accounted":
            owned = row["source_range"]
            if owned["start"] != accounted or owned["end"] > accepted:
                raise ValueError("source partition gap or overlap")
            if row["kind"] == "speech":
                if finals.get(turn) != owned or turn in accounted_turns:
                    raise ValueError("speech owner mismatch")
                accounted_turns.add(turn)
            else:
                if turn or any(owned["start"] < final["end"] and final["start"] < owned["end"] for final in finals.values()):
                    raise ValueError("non-speech cannot own finalized speech")
                if row["kind"] == "loss":
                    loss_partitions.append((owned["start"], owned["end"]))
            accounted = owned["end"]
        elif kind == "loss":
            if row["source_range"]["end"] > accepted:
                raise ValueError("loss beyond accepted source")
            owned = row["source_range"]
            if row["dropped_samples"] != owned["end"] - owned["start"]:
                raise ValueError("loss sample count mismatch")
            loss_ranges.append((owned["start"], owned["end"]))
            loss_count += row["dropped_samples"]
        elif kind == "session_terminal":
            if row["accepted_through"] != accepted or accounted != accepted or row["dropped_samples"] != loss_count:
                raise ValueError("incomplete terminal accounting")
            if accounted_turns != set(finals) or sorted(loss_ranges) != sorted(loss_partitions):
                raise ValueError("unreconciled speech or loss ownership")
            if row["failed_segments"] < final_failures or row["dropped_samples"] < final_drops:
                raise ValueError("unreconciled final counters")
            if row["status"] == "finished" and (loss_count or row["failed_segments"] or bad_final):
                raise ValueError("false successful terminal")
            terminal = row
    if terminal is None:
        raise ValueError("terminal required")
    return {"event_count": len(rows), "turn_count": len(finals), "status": terminal["status"]}


def redacted_event(event):
    allowed = ("type", "session_id", "sequence", "status", "failed_segments", "dropped_samples", "audio_ms", "truncated")
    types = {"type": str, "session_id": str, "sequence": int, "status": str,
             "failed_segments": int, "dropped_samples": int, "audio_ms": int, "truncated": bool}
    result = {key: event[key] for key in allowed if key in event and type(event[key]) is types[key]}
    if event.get("type") != "complete" or event.get("status") not in ("ok", "partial", "empty", "error"):
        result.pop("status", None)
    if isinstance(event.get("text"), str):
        result["text_length"] = len(event["text"])
    return result


def write_json(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write("\n")


class OwnedRun:
    def __init__(self, manifest, out):
        self.manifest, self.out = manifest, out
        self.children, self.processing_ns, self.assertions = [], [], []
        self.descendants = []
        self.unresolved_descendants = set()
        self.events = None
        self.raw = None
        self.wire = None
        self.started = time.monotonic_ns()
        self.seq = 0
        self.source_bytes = 0

    def __enter__(self):
        self.out.mkdir(mode=0o700)
        (self.out / "manifest.json").write_bytes(self.manifest.source.read_bytes())
        self.events = (self.out / "events.ndjson").open("x")
        if self.manifest.data["privacy"]["retain_content"]:
            self.raw = (self.out / "source-events.ndjson").open("x")
            self.wire = (self.out / "source-wire.ndjson").open("xb")
        return self

    def spawn(self, argv, **kwargs):
        executable = safe_path(argv[0])
        role = next((name for name, artifact in self.manifest.data["artifacts"].items()
                     if artifact["path"] == str(executable)), None)
        expected = self.manifest.data["artifacts"].get(role)
        if expected is None or sha256(executable) != expected["sha256"]:
            raise ProbeError(2, "unbound-or-changed-executable")
        child = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, **kwargs)
        try:
            identity = process_identity(child.pid)
        except BaseException:
            child.terminate()
            child.wait(timeout=5)
            raise
        identity["argv"] = argv
        identity["role"] = role
        self.children.append((child, identity))
        write_json(self.out / f"process-{child.pid}.json", identity)
        if identity["ppid"] != os.getpid() or identity["uid"] != os.getuid():
            raise ProbeError(2, "child-ownership-mismatch")
        if identity["executable"] != str(executable) or identity["sha256"] != expected["sha256"]:
            raise ProbeError(2, "launched-executable-identity-mismatch")
        return child

    def record(self, event):
        start = time.monotonic_ns()
        self.seq += 1
        row = {"schema_version": 1, "sequence": self.seq, "run_id": self.manifest.data["run_id"],
               "received_ns": start, "clock": "host-monotonic-ns", "event": redacted_event(event)}
        self.events.write(json.dumps(row, separators=(",", ":")) + "\n")
        self.events.flush()
        if self.raw:
            self.raw.write(json.dumps({"received_ns": start, "event": event}) + "\n")
            self.raw.flush()
        self.processing_ns.append(time.monotonic_ns() - start)

    def collect(self, child, trace, timeout, until_complete=False, tick=None):
        pending = b""
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            while True:
                self.track_descendants()
                if tick:
                    tick()
                if time.monotonic() > deadline:
                    raise ProbeError(4, "engine-deadline")
                for key, _ in selector.select(min(0.2, max(0, deadline - time.monotonic()))):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        if pending:
                            raise ProbeError(1, "incomplete-final-frame")
                        if trace.final is None:
                            raise ProbeError(1, "missing-completion")
                        return
                    self.source_bytes += len(chunk)
                    if self.wire:
                        self.wire.write(chunk)
                    if self.source_bytes > 64 * 1024 * 1024:
                        raise ProbeError(1, "source-stream-byte-limit")
                    pending += chunk
                    while b"\n" in pending:
                        line, pending = pending.split(b"\n", 1)
                        if not line or len(line) > MAX_LINE:
                            raise ProbeError(1, "invalid-frame-size")
                        try:
                            event = strict_json(line)
                        except (ValueError, UnicodeError) as error:
                            raise ProbeError(1, "malformed-engine-json") from error
                        start = time.monotonic_ns()
                        trace.accept(event)
                        self.record(event)
                        self.processing_ns[-1] = time.monotonic_ns() - start
                    if len(pending) > MAX_LINE:
                        raise ProbeError(1, "frame-size-limit")
                    if until_complete and trace.final is not None:
                        if pending:
                            raise ProbeError(1, "post-completion-bytes")
                        return

    def legacy_wav(self):
        data = self.manifest.data
        item = data["input"]
        engine = data["artifacts"]["engine"]["path"]
        protocol = engine_protocol(engine)
        argv = [engine, "transcribe", item["path"], "--session", "--format", "json",
                "--model-dir", data["artifacts"]["model"]["path"]]
        if protocol == 2:
            argv.append("--partials")
        child = self.spawn(argv)
        trace = LegacyTrace("replay")
        self.collect(child, trace, 180)
        if child.wait(timeout=5) != 0:
            raise ProbeError(1, "engine-exit-failure")
        self.assertions.append(trace.finish(item["expected_phrases"]))
        return self.baseline(trace)

    def legacy_microphone(self):
        data = self.manifest.data
        if not data["fixture_writes"]:
            raise ProbeError(2, "fixture-write-permission-required")
        engine = data["artifacts"]["engine"]["path"]
        protocol = engine_protocol(engine)
        socket_path = Path(data["paths"]["socket"])
        pid_file = Path(data["paths"]["pid_file"])
        if socket_path.exists() or pid_file.exists() or len(str(socket_path).encode()) > 100:
            raise ProbeError(2, "occupied-or-long-runtime-path")
        child = self.spawn([engine, "serve", "--socket", str(socket_path), "--pid-file", str(pid_file),
                            "--model-dir", data["artifacts"]["model"]["path"],
                            "--device", data["input"]["device"]],
                           env={**os.environ, "PARAKEET_PARENT_PID": str(os.getpid())})
        ready_deadline = time.monotonic() + 45
        while not socket_path.exists():
            if child.poll() is not None or time.monotonic() > ready_deadline:
                raise ProbeError(3, "microphone-daemon-not-ready")
            time.sleep(0.05)
        session = str(uuid.uuid4())
        request = {"command": "start", "session_id": session}
        if protocol == 2:
            request["partials"] = True
        socket_request(socket_path, request)
        stop_at = time.monotonic() + data["input"]["duration_seconds"]
        stopped = False

        def stop_when_due():
            nonlocal stopped
            if not stopped and time.monotonic() >= stop_at:
                socket_request(socket_path, {"command": "stop", "session_id": session})
                stopped = True

        trace = LegacyTrace(session)
        try:
            self.collect(child, trace, data["input"]["duration_seconds"] + 120,
                         until_complete=True, tick=stop_when_due)
            if not trace.started:
                raise ProbeError(1, "microphone-start-event-missing")
            self.assertions.append(trace.finish(data["input"]["expected_phrases"]))
            return self.baseline(trace)
        finally:
            if child.poll() is None and matches_process(self.children[-1][1]):
                socket_request(socket_path, {"command": "cancel", "session_id": session}, require_ok=False)
                socket_request(socket_path, {"command": "shutdown"}, require_ok=False)

    def baseline(self, trace):
        result = {"state": State.VERIFIED.value, "scope": "legacy-engine-only",
                  "input_kind": self.manifest.data["input"]["kind"], "event_count": trace.count,
                  "elapsed_ns": time.monotonic_ns() - self.started,
                  "recorder_ns": self.processing_ns,
                  "audio_availability": "UNAVAILABLE", "asr_publication": "receive-time-only",
                  "intent_commitment": "UNAVAILABLE", "dispatch": "UNAVAILABLE", "verified_effect": "UNAVAILABLE",
                  "continuous_capture": "UNSUPPORTED", "native_outcome": "UNVERIFIED"}
        write_json(self.out / "baseline.json", result)
        return result

    def track_descendants(self):
        active = {identity["pid"]: identity for child, identity in self.children
                  if child.poll() is None and matches_process(identity)}
        active.update({identity["pid"]: identity for identity in self.descendants if matches_process(identity)})
        if not active:
            return
        rows = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid="], text=True)
        tree = [tuple(map(int, row.split())) for row in rows.splitlines() if len(row.split()) == 2]
        changed = True
        while changed:
            changed = False
            for pid, ppid in tree:
                if ppid not in active or pid in active or not matches_process(active[ppid]):
                    continue
                try:
                    identity = process_identity(pid)
                except (ProbeError, OSError):
                    self.unresolved_descendants.add((pid, ppid))
                    continue
                if identity["uid"] == os.getuid() and identity["ppid"] == ppid:
                    active[pid] = identity
                    self.descendants.append(identity)
                    write_json(self.out / f"descendant-{pid}.json", identity)
                    changed = True

    def __exit__(self, *_):
        cleanup = []
        try:
            self.track_descendants()
        except (OSError, ValueError, subprocess.SubprocessError):
            cleanup.append({"state": "descendant-accounting-incomplete"})
        for child, identity in reversed(self.children):
            if child.poll() is not None and identity.get("role") not in ("engine", "helper"):
                cleanup.append({"pid": child.pid, "state": "parent-exited-before-descendant-reconciliation"})
            if child.poll() is None:
                if not matches_process(identity):
                    cleanup.append({"pid": child.pid, "state": "identity-mismatch-not-signalled"})
                    continue
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    if matches_process(identity):
                        child.kill()
                        child.wait(timeout=5)
            cleanup.append({"pid": child.pid, "state": "exited" if child.poll() is not None else "unresolved"})
            if child.stdout:
                child.stdout.close()
        for identity in reversed(self.descendants):
            pid = identity["pid"]
            if matches_process(identity):
                try:
                    os.kill(pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 3
                while matches_process(identity) and time.monotonic() < deadline:
                    time.sleep(0.05)
                if matches_process(identity):
                    os.kill(pid, signal.SIGKILL)
                cleanup.append({"pid": pid, "state": "unresolved" if matches_process(identity) else "exited"})
            else:
                cleanup.append({"pid": pid, "state": "exited-or-identity-changed-not-signalled"})
        cleanup.extend({"pid": pid, "ppid": ppid, "state": "descendant-identity-unavailable"}
                       for pid, ppid in sorted(self.unresolved_descendants))
        for stream in (self.events, self.raw, self.wire):
            if stream:
                stream.close()
        write_json(self.out / "cleanup.json", cleanup)
        if any(row["state"] not in ("exited", "exited-or-identity-changed-not-signalled") for row in cleanup):
            raise ProbeError(4, "cleanup-incomplete")


def socket_request(path, request, require_ok=True):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(str(path))
        connection.sendall(json.dumps(request).encode() + b"\n")
        response = b""
        while b"\n" not in response:
            chunk = connection.recv(4096)
            if not chunk or len(response) + len(chunk) > MAX_LINE:
                raise ProbeError(4, "invalid-socket-reply")
            response += chunk
        reply = strict_json(response.split(b"\n", 1)[0])
        if reply.get("protocol_version") not in (1, 2) or (require_ok and reply.get("status") != "ok"):
            raise ProbeError(3, "legacy-request-not-accepted")
        return reply


def engine_protocol(engine):
    result = subprocess.run([engine, "protocol-version"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            timeout=10, check=False)
    if result.returncode != 0 or result.stdout.strip() not in (b"1", b"2"):
        raise ProbeError(3, "legacy-engine-capability-unavailable")
    return int(result.stdout.strip())


def capability_preflight(manifest):
    data = manifest.data
    requested = data["requested_capability"]
    if requested != "legacy-session":
        return {"state": State.BLOCKED.value, "requested": requested, "reason": "future-driver-unavailable"}
    protocol = engine_protocol(data["artifacts"]["engine"]["path"])
    return {"state": State.VERIFIED.value, "scope": "legacy-engine-protocol-only", "protocol": protocol,
            "native": State.BLOCKED.value, "native_reason": "requires-disposable-AX-and-screenshot-proof"}


def receipt(manifest, out, code, reason, assertions):
    write_json(out / "assertions.json", assertions)
    payload = {"schema_version": 1, "run_id": manifest.data["run_id"],
               "manifest_sha256": manifest.digest, "probe_sha256": sha256(Path(__file__)),
               "harness_inventory": {name: sha256(Path(__file__).with_name(name))
                                     for name in ("actions_probe.py", "actions_probe_browser.py")},
               "contract_sha256": manifest.data["contract_sha256"], "exit_code": code,
               "state": "PASS" if code == 0 else "BLOCKED" if code == 3 else "INCOMPLETE" if code in (4, 130) else "FAIL",
               "reason": reason, "program_verified": False}
    validate_schema(payload, strict_json((FIXTURES / "schemas/receipt-v1.json").read_bytes()))
    write_json(out / "receipt.json", payload)
    write_json(out / "evidence-index.json", {p.name: sha256(p) for p in sorted(out.iterdir()) if p.is_file()})


def execute(args, manifest, out):
    data = manifest.data
    scenario = args.scenario if hasattr(args, "scenario") else None
    if scenario:
        kind, capability = SCENARIOS[scenario]
        if kind is not None and data["input"]["kind"] != kind:
            raise ProbeError(2, "scenario-input-kind-mismatch")
        if capability != data["requested_capability"]:
            raise ProbeError(2, "scenario-capability-mismatch")
    manifest.environment(desktop=scenario in ("notes-target", "chrome-fixture", "chrome-public-smoke", "legacy-microphone"))
    manifest.output(str(out))
    code, reason, assertions = 0, "requested-scope-complete", []
    run = None
    try:
        with ExitStack() as stack:
            if scenario in ("notes-target", "chrome-fixture", "chrome-public-smoke", "legacy-microphone"):
                stack.enter_context(DesktopLease())
            run = stack.enter_context(OwnedRun(manifest, out))
            preflight = capability_preflight(manifest)
            write_json(out / "preflight.json", preflight)
            if preflight["state"] != State.VERIFIED.value:
                raise ProbeError(3, "future-capability-unavailable")
            if args.command == "preflight":
                assertions.append({"id": "legacy-protocol-available", "passed": True})
            elif scenario == "legacy-wav":
                run.legacy_wav()
            elif scenario == "legacy-microphone":
                run.legacy_microphone()
            elif scenario == "notes-target":
                observe_notes(run)
            elif scenario in ("chrome-fixture", "chrome-public-smoke"):
                from actions_probe_browser import observe_chrome
                observe_chrome(run, public=scenario == "chrome-public-smoke")
            else:
                raise ProbeError(3, "scenario-driver-unavailable")
    except ProbeError as error:
        code, reason = error.code, error.reason
    except KeyboardInterrupt:
        code, reason = 130, "interrupted"
    except (OSError, ValueError, subprocess.SubprocessError):
        code, reason = 4, "external-operation-incomplete"
    finally:
        if run is not None:
            assertions.extend(run.assertions)
    if out.exists():
        receipt(manifest, out, code, reason, assertions)
    return code, reason


def observe_notes(run):
    data = run.manifest.data
    if "native_target" not in data or "helper" not in data["artifacts"]:
        raise ProbeError(3, "explicit-native-target-and-helper-required")
    target = data["native_target"]
    if not matches_process(target) or target["uid"] != os.getuid():
        raise ProbeError(2, "stale-native-process")
    if not data["privacy"]["retain_content"]:
        raise ProbeError(3, "native-content-proof-requires-local-opt-in")
    helper = data["artifacts"]["helper"]["path"]
    child = run.spawn([helper, "--observe", "--pid", str(target["pid"]), "--uid", str(target["uid"]),
                       "--start-us", str(target["start_us"]), "--samples", "2", "--interval-ms", "250", "--include-content"])
    output, _ = child.communicate(timeout=15)
    if len(output) > 1024 * 1024:
        raise ProbeError(4, "native-output-limit")
    rows = [strict_json(line) for line in output.splitlines()]
    schema = strict_json((FIXTURES / "schemas/native-observation-v1.json").read_bytes())
    for row in rows:
        validate_schema(row, schema)
    write_json(run.out / "native-observations.json", rows)
    if child.returncode != 0 or len(rows) != 2 or any(row.get("state") != "OBSERVED" or not row.get("editable") for row in rows):
        state = State.UNSUPPORTED.value if rows and rows[-1].get("state") == "UNSUPPORTED" else State.BLOCKED.value
        write_json(run.out / "native-target-proof.json", {"state": state,
                   "reason": "native-editable-not-proven", "observations": "native-observations.json"})
        run.assertions.append({"id": "native-editable-observed", "passed": False, "state": state})
        raise ProbeError(3, "native-editable-not-proven")
    if rows[0].get("generation") != rows[1].get("generation"):
        raise ProbeError(1, "native-target-drift")
    write_json(run.out / "native-target-proof.json", {"state": State.BLOCKED.value,
               "reason": "screenshot-and-title-body-correlation-require-independent-live-verifier",
               "observations": "native-observations.json", "input_consumed": False})
    raise ProbeError(3, "native-proof-incomplete-without-independent-screenshot")


def compare(args, manifest, out):
    baseline = Manifest.load(args.baseline_manifest)
    baseline.environment(desktop=True)
    manifest.environment(desktop=True)
    manifest.output(str(out))
    if args.scenario != "legacy-wav" or baseline.data["input"] != manifest.data["input"] or baseline.root != manifest.root:
        raise ProbeError(3, "comparable-real-driver-unavailable")
    for role in ("engine", "model"):
        if baseline.data["artifacts"][role]["sha256"] != manifest.data["artifacts"][role]["sha256"]:
            raise ProbeError(2, "P01-requires-same-rebuilt-engine-and-model")
    active = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True)
    if any(Path(line.strip()).name in ("swift-build", "swift-frontend", "cargo", "rustc") for line in active.splitlines()):
        raise ProbeError(3, "performance-blocked-by-concurrent-build")
    out.mkdir(mode=0o700)
    samples, failures = [], 0
    with DesktopLease():
        for pair in range(10):
            for arm in (("A", "B") if pair % 2 == 0 else ("B", "A")):
                selected = baseline if arm == "A" else manifest
                sample_out = out / f"pair-{pair + 1:02d}-{arm}"
                sample_args = argparse.Namespace(command="run", scenario="legacy-wav")
                code, _ = execute(sample_args, selected, sample_out)
                failures += code != 0
                sample = {"pair": pair + 1, "arm": arm, "exit_code": code, "receipt": str(sample_out / "receipt.json")}
                if (sample_out / "baseline.json").exists():
                    sample.update(strict_json((sample_out / "baseline.json").read_bytes()))
                samples.append(sample)
    result = assess_samples(samples)
    result["failures"] = failures
    result["scope"] = "same-engine-file-replay-repeatability-not-app-or-native-regression"
    result["native_performance"] = "BLOCKED"
    result["program_verified"] = False
    write_json(out / "comparison.json", result)
    write_json(out / "samples.json", samples)
    receipt(manifest, out, 1 if failures or not result["budgets_passed"] else 0, "comparison-scope-only", [])
    return (1 if failures or not result["budgets_passed"] else 0), "comparison-scope-only"


def assess_samples(samples):
    arms = {arm: [row["elapsed_ns"] / 1e6 for row in samples if row["arm"] == arm and row["exit_code"] == 0] for arm in ("A", "B")}
    summaries = {arm: {"median_ms": statistics.median(values), "range_ms": [min(values), max(values)]}
                 for arm, values in arms.items() if values}
    processing = [value for row in samples for value in row.get("recorder_ns", [])]
    complete = (len(samples) == 20 and all(len(arms[arm]) == 10 for arm in arms)
                and all(row.get("event_count", 0) > 0 and row["event_count"] == len(row.get("recorder_ns", []))
                        for row in samples))
    regression = False
    if len(summaries) == 2:
        a, b = (summaries[arm]["median_ms"] for arm in ("A", "B"))
        regression = b - a > 100 and b > a * 1.2
    return {"arms": summaries, "sample_count": len(samples), "event_count": len(processing),
            "recorder_median_ns": statistics.median(processing) if processing else None,
            "budgets_passed": bool(complete and processing and not regression and statistics.median(processing) <= 2000000)}


def main(argv=None):
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("preflight", "run", "observe", "compare"):
        sub = commands.add_parser(name)
        sub.add_argument("--manifest", type=Path, required=True)
        sub.add_argument("--out", type=Path, required=True)
        if name != "preflight":
            sub.add_argument("--scenario", choices=SCENARIOS, required=True)
        if name == "compare":
            sub.add_argument("--baseline-manifest", type=Path, required=True)
    args = parser.parse_args(argv)
    previous = signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    try:
        manifest = Manifest.load(args.manifest)
        if args.command == "observe" and args.scenario not in ("notes-target", "chrome-fixture", "chrome-public-smoke"):
            raise ProbeError(2, "observation-scenario-required")
        code, reason = compare(args, manifest, args.out) if args.command == "compare" else execute(args, manifest, args.out)
    except ProbeError as error:
        code, reason = error.code, error.reason
    except (ValueError, KeyError, OSError):
        code, reason = 2, "invalid-manifest-or-path"
    except KeyboardInterrupt:
        code, reason = 130, "interrupted"
    finally:
        signal.signal(signal.SIGTERM, previous)
    sys.stdout.write(json.dumps({"exit_code": code, "reason": reason, "program_verified": False}) + "\n")
    return code


if __name__ == "__main__":
    sys.exit(main())
