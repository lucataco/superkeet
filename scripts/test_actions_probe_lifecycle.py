import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

import actions_probe as probe


SYNTHETIC_DAEMON = r'''
import json, os, socket, sys, time
path, journal, mode = sys.argv[1:]
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(path)
server.listen()
session = None
state = "idle"

def emit(kind):
    event = {"type": kind, "session_id": session}
    if kind == "complete":
        event.update(text="Open Notes", status="ok", failed_segments=0, dropped_samples=0)
    elif kind == "partial":
        event.update(text="Open Notes", sequence=1, truncated=False)
    print(json.dumps(event), flush=True)

while True:
    connection, _ = server.accept()
    with connection:
        wire = b""
        while b"\n" not in wire:
            wire += connection.recv(4096)
        request = json.loads(wire)
        with open(journal, "a") as output:
            output.write(json.dumps(request) + "\n")
        command = request["command"]
        if command == "start":
            session = request["session_id"]
            state = "recording"
        elif command in ("stop", "cancel"):
            state = "transcribing"
        reply = {"protocol_version": 2, "status": "ok", "state": state,
                 "session_id": session if state != "idle" else None}
        connection.sendall(json.dumps(reply).encode() + b"\n")
    if command == "start":
        emit("session_started")
        if mode.startswith("premature"):
            emit("complete")
            if mode == "premature-exit":
                sys.exit(9)
    elif command == "stop":
        emit("transcribing")
        emit("complete")
        state = "idle"
    elif command == "shutdown":
        if mode.startswith("late-"):
            time.sleep(0.25)
            if mode == "late-malformed":
                print("malformed", flush=True)
            elif mode == "late-truncated":
                os.write(1, b'{"type":')
            else:
                emit("complete" if mode == "late-complete" else "partial")
        sys.exit(9 if mode == "exit-failure" else 0)
'''


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="p01-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.source = self.root / "manifest.json"
        self.source.write_text('{}\n')
        self.children = []
        self.addCleanup(self.reap_fixtures)

    def reap_fixtures(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=5)
            for stream in (child.stdin, child.stdout, child.stderr):
                if stream:
                    stream.close()

    def manifest(self):
        executable = probe.process_identity(os.getpid())["executable"]
        return probe.Manifest({
            "run_id": "12345678-1234-1234-1234-123456789abc",
            "privacy": {"retain_content": True}, "fixture_writes": True,
            "paths": {"socket": str(self.root / "engine.sock"), "pid_file": str(self.root / "engine.pid")},
            "artifacts": {"engine": {"path": executable, "sha256": probe.sha256(executable)},
                          "model": {"path": str(self.root)}},
            "input": {"kind": "microphone", "device": "synthetic-no-audio", "duration_seconds": 0.1,
                      "expected_phrases": ["Open Notes"]},
        }, "0" * 64, self.root, self.source)

    def microphone(self, mode):
        manifest = self.manifest()
        if mode.startswith("premature"):
            manifest.data["input"]["duration_seconds"] = 30
        original_spawn = probe.OwnedRun.spawn
        journal = self.root / "requests.ndjson"

        def spawn(run, argv, **kwargs):
            child = original_spawn(run, [argv[0], "-c", SYNTHETIC_DAEMON,
                                         manifest.data["paths"]["socket"], str(journal), mode])
            self.children.append(child)
            return child

        with patch.object(probe, "engine_protocol", return_value=2), patch.object(probe.OwnedRun, "spawn", spawn):
            with probe.OwnedRun(manifest, self.root / "run") as run:
                return run.legacy_microphone()

    def test_microphone_rejects_completion_before_requested_stop(self):
        with self.assertRaises(probe.ProbeError):
            self.microphone("premature-alive")
        self.assertFalse((self.root / "run/baseline.json").exists())
        requests = [json.loads(line)["command"] for line in (self.root / "requests.ndjson").read_text().splitlines()]
        self.assertNotIn("stop", requests)

    def test_microphone_rejects_premature_completion_and_abnormal_exit(self):
        with self.assertRaises(probe.ProbeError):
            self.microphone("premature-exit")
        self.assertFalse((self.root / "run/baseline.json").exists())

    def test_microphone_waits_for_successful_shutdown_and_eof(self):
        result = self.microphone("normal")
        self.assertEqual(result["state"], "VERIFIED")
        self.assertEqual(self.children[0].poll(), 0)
        requests = [json.loads(line)["command"] for line in (self.root / "requests.ndjson").read_text().splitlines()]
        self.assertEqual(requests, ["start", "stop", "shutdown"])

    def test_microphone_rejects_nonzero_shutdown_exit(self):
        with self.assertRaises(probe.ProbeError):
            self.microphone("exit-failure")
        self.assertFalse((self.root / "run/baseline.json").exists())

    def test_microphone_drains_delayed_duplicate_completion(self):
        with self.assertRaises(probe.ProbeError):
            self.microphone("late-complete")
        self.assertFalse((self.root / "run/baseline.json").exists())
        rows = [json.loads(line) for line in (self.root / "run/source-wire.ndjson").read_bytes().splitlines()]
        finals = [row for row in rows if row["type"] == "complete"]
        self.assertEqual(len(finals), 2)
        self.assertEqual(finals[0], finals[1])

    def test_microphone_drains_delayed_postterminal_partial(self):
        with self.assertRaises(probe.ProbeError):
            self.microphone("late-partial")
        self.assertFalse((self.root / "run/baseline.json").exists())

    def test_microphone_drains_delayed_malformed_frame(self):
        with self.assertRaises(probe.ProbeError):
            self.microphone("late-malformed")
        self.assertFalse((self.root / "run/baseline.json").exists())

    def test_microphone_drains_delayed_incomplete_frame(self):
        with self.assertRaises(probe.ProbeError):
            self.microphone("late-truncated")
        self.assertFalse((self.root / "run/baseline.json").exists())

    def reply(self, payload, command="start", require_ok=True):
        path = self.root / f"reply-{len(list(self.root.glob('reply-*')))}.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(path))
        server.listen(1)
        server.settimeout(5)
        failures = []

        def respond():
            try:
                with server:
                    connection, _ = server.accept()
                    with connection:
                        connection.recv(4096)
                        connection.sendall(payload)
            except BaseException as error:
                failures.append(error)

        worker = threading.Thread(target=respond)
        worker.start()
        try:
            request = {"command": command}
            if command != "shutdown":
                request["session_id"] = "12345678-1234-1234-1234-123456789abc"
            return probe.socket_request(path, request, require_ok=require_ok)
        finally:
            worker.join(6)
            self.assertFalse(worker.is_alive())
            self.assertFalse(failures, failures)

    def test_socket_accepts_real_legacy_acknowledgement_shapes(self):
        for protocol in (1, 2):
            for command, state, session in (("start", "recording", "12345678-1234-1234-1234-123456789abc"),
                                             ("stop", "transcribing", "12345678-1234-1234-1234-123456789abc"),
                                             ("cancel", "transcribing", "12345678-1234-1234-1234-123456789abc"),
                                             ("shutdown", "idle", None)):
                reply = {"protocol_version": protocol, "status": "ok", "state": state, "session_id": session}
                with self.subTest(protocol=protocol, command=command):
                    self.assertEqual(self.reply(json.dumps(reply).encode() + b"\n", command), reply)
        rejected = {"protocol_version": 2, "status": "error", "message": "No active recording"}
        self.assertEqual(self.reply(json.dumps(rejected).encode() + b"\n", "cancel", False), rejected)

    def test_socket_rejects_boolean_protocol_foreign_session_and_wrong_state(self):
        valid = {"protocol_version": 2, "status": "ok", "state": "recording",
                 "session_id": "12345678-1234-1234-1234-123456789abc"}
        for fields in ({"protocol_version": True}, {"session_id": "foreign"}, {"session_id": None},
                       {"state": "idle"}, {"state": "transcribing"}, {"state": []}, {"status": []}):
            with self.subTest(fields=fields):
                with self.assertRaises(probe.ProbeError):
                    self.reply(json.dumps({**valid, **fields}).encode() + b"\n")

    def test_socket_rejects_malformed_nonobject_and_trailing_replies(self):
        for payload in (b"[]\n", b"true\n", b"null\n", b"42\n", b'"text"\n', b"malformed\n",
                        b"{\xff}\n", b'{"protocol_version":2,"protocol_version":2}\n',
                        b'{"protocol_version":2,"status":"ok"}\n',
                        b'{"protocol_version":2,"status":"ok","state":"recording",'
                        b'"session_id":"12345678-1234-1234-1234-123456789abc"}\n{}\n'):
            with self.subTest(payload=payload):
                with self.assertRaises(probe.ProbeError):
                    self.reply(payload)

    def test_socket_rejects_parser_depth_failures_as_structured_errors(self):
        for opening, closing in ((b"[", b"]"), (b'{"value":', b"}")):
            payload = opening * 20000 + b"0" + closing * 20000 + b"\n"
            with self.subTest(opening=opening), self.assertRaises(probe.ProbeError):
                self.reply(payload)

    def test_protocol_query_interrupt_reaps_actual_child(self):
        executable = self.root / "protocol-fixture"
        pid_file = self.root / "protocol.pid"
        executable.write_text(f"#!{sys.executable}\nimport os, pathlib, time\n"
                              f"pathlib.Path({str(pid_file)!r}).write_text(str(os.getpid()))\ntime.sleep(30)\n")
        executable.chmod(0o700)
        original_popen = subprocess.Popen

        def launch(*args, **kwargs):
            child = original_popen(*args, **kwargs)
            self.children.append(child)
            return child

        def interrupt(_signal, _frame):
            raise KeyboardInterrupt()

        previous = signal.signal(signal.SIGALRM, interrupt)
        try:
            signal.setitimer(signal.ITIMER_REAL, 0.5)
            with patch.object(probe.subprocess, "Popen", launch):
                with self.assertRaises(KeyboardInterrupt):
                    probe.engine_protocol(str(executable))
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
            signal.signal(signal.SIGALRM, previous)
        self.assertTrue(pid_file.exists())
        self.assertIsNotNone(self.children[0].poll(), "interrupted capability query left its child running")
        self.assertTrue(self.children[0].stdout.closed)


if __name__ == "__main__":
    unittest.main()
