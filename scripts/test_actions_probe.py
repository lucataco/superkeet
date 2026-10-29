import copy
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import actions_probe as probe


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name).resolve()
        self.addCleanup(self.directory.cleanup)
        self.manifest = {
            "schema_version": 1, "run_id": "12345678-1234-1234-1234-123456789abc",
            "account": {"uid": 502, "home": "/Users/actions-test", "disposable": True,
                        "no_personal_data": True, "operator_receipt": {"path": "/fixture/enrollment.json", "sha256": "a" * 64}},
            "paths": {"root": "/Users/actions-test/runs/one", "socket": "/Users/actions-test/runs/one/engine.sock",
                      "pid_file": "/Users/actions-test/runs/one/engine.pid", "chrome_profile": "/Users/actions-test/runs/one/chrome"},
            "artifacts": {role: {"path": "/fixture/" + role, "sha256": "b" * 64, "source_sha": "c" * 40,
                                  "build_receipt": {"path": "/fixture/build.json", "sha256": "d" * 64}}
                          for role in ("engine", "model")},
            "input": {"kind": "wav", "path": "/fixture/audio.wav", "sha256": "e" * 64,
                      "expected_phrases": ["Notes", "Norbert Wiener"]},
            "requested_capability": "legacy-session", "fixture_writes": False,
            "privacy": {"retain_content": False}, "expected": {},
            "contract_sha256": probe.sha256(probe.FIXTURES / "contract-index.json"),
        }

    def load(self, value=None):
        path = self.root / "manifest.json"
        path.write_text(json.dumps(self.manifest if value is None else value))
        return probe.Manifest.load(path)

    def final(self, **fields):
        return {"type": "complete", "session_id": "replay", "text": "Open Notes. Search Norbert Wiener.",
                "status": "ok", "failed_segments": 0, "dropped_samples": 0, **fields}

    def test_valid_manifest_has_one_input(self):
        self.assertEqual(self.load().data["input"]["kind"], "wav")

    def test_manifest_rejects_primary_uid_before_effects(self):
        for uid in (0, 501):
            with self.subTest(uid=uid):
                self.manifest["account"]["uid"] = uid
                with self.assertRaises((probe.ProbeError, ValueError)):
                    self.load()

    def test_extra_fields_and_mixed_input_fail(self):
        for mutate in (lambda m: m.update(unknown=True),
                       lambda m: m["input"].update(device="default"),
                       lambda m: m["input"].update(kind="protocol-events"),
                       lambda m: m["account"].update(disposable=False),
                       lambda m: m["account"].update(uid=True),
                       lambda m: m["privacy"].update(retain_content="yes")):
            value = copy.deepcopy(self.manifest)
            mutate(value)
            with self.assertRaises(ValueError):
                self.load(value)

    def test_required_fields_cannot_be_removed(self):
        for field in self.manifest:
            value = copy.deepcopy(self.manifest)
            del value[field]
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.load(value)

    def test_input_variants_validate_separately(self):
        self.manifest["input"] = {"kind": "microphone", "device": "default", "duration_seconds": 5,
                                  "expected_phrases": ["hello"]}
        self.assertEqual(self.load().data["input"]["kind"], "microphone")
        self.manifest["input"] = {"kind": "protocol-events", "path": "/fixture/events.ndjson", "sha256": "a" * 64}
        self.assertEqual(self.load().data["input"]["kind"], "protocol-events")

    def test_paths_refuse_escape_relative_and_traversal(self):
        for path in ("relative", "/Users/actions-test/runs/one/../outside", "/Users/lucataco/private", "/Users/actions-test/runs/one-ish/socket"):
            value = copy.deepcopy(self.manifest)
            value["paths"]["socket"] = path
            with self.subTest(path=path), self.assertRaises((probe.ProbeError, ValueError)):
                self.load(value)

    def test_symlink_path_refused(self):
        link = self.root / "link"
        link.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(probe.ProbeError):
            probe.safe_path(str(link / "child"))

    def test_output_must_be_new_and_under_root(self):
        manifest = probe.Manifest(self.manifest, "f" * 64, self.root, self.root / "m")
        self.assertEqual(manifest.output(self.root / "new"), self.root / "new")
        for path in (self.root, self.root / ".." / "outside", self.root.parent / "escape"):
            with self.assertRaises(probe.ProbeError):
                manifest.output(path)

    def test_forged_home_does_not_bypass_real_uid(self):
        manifest = self.load()
        with patch.object(probe.os, "getuid", return_value=501), patch.dict(os.environ, HOME="/Users/actions-test"):
            with self.assertRaisesRegex(probe.ProbeError, "disposable-account-required"):
                manifest.environment(desktop=True)

    def test_contract_change_refused(self):
        self.manifest["contract_sha256"] = "0" * 64
        with self.assertRaisesRegex(probe.ProbeError, "contract-hash-mismatch"):
            self.load()

    def test_duplicate_keys_and_nonfinite_json_refused(self):
        for raw in ('{"a":1,"a":2}', '{"a":NaN}', '{"a":Infinity}', '{"a":1e999}'):
            with self.assertRaises(ValueError):
                probe.strict_json(raw)

    def test_complete_is_required_even_with_all_phrases(self):
        trace = probe.LegacyTrace("replay")
        trace.accept({"type": "partial", "session_id": "replay", "sequence": 1, "text": "Notes Norbert Wiener"})
        with self.assertRaises(probe.ProbeError):
            trace.finish(["Notes"])

    def test_actual_success_requires_loss_fields_and_phrases(self):
        trace = probe.LegacyTrace("replay")
        trace.accept(self.final())
        self.assertTrue(trace.finish(["notes", "Norbert Wiener"])["passed"])
        with self.assertRaises(probe.ProbeError):
            trace.finish(["absent phrase"])
        with self.assertRaises(probe.ProbeError):
            trace.finish([])

    def test_error_complete_and_missing_loss_counters_fail(self):
        for fields in ({"status": "error"}, {"failed_segments": 1}, {"dropped_samples": 2},
                       {"dropped_samples": None}, {"failed_segments": False}, {"text": None}):
            with self.subTest(fields=fields), self.assertRaises(probe.ProbeError):
                probe.LegacyTrace("replay").accept(self.final(**fields))
        event = self.final()
        del event["dropped_samples"]
        with self.assertRaises(probe.ProbeError):
            probe.LegacyTrace("replay").accept(event)

    def test_stale_sessions_unknown_events_and_sequence_gaps_fail(self):
        for event in (self.final(session_id="foreign"), {"type": "invented", "session_id": "replay"},
                      {"type": "partial", "session_id": "replay", "sequence": 2, "text": "words"}):
            with self.assertRaises(probe.ProbeError):
                probe.LegacyTrace("replay").accept(event)

    def test_duplicate_terminal_or_post_terminal_event_fails(self):
        trace = probe.LegacyTrace("replay")
        trace.accept(self.final())
        with self.assertRaises(probe.ProbeError):
            trace.accept(self.final())

    def test_redacted_trace_excludes_literal_content_and_messages(self):
        event = self.final(message="PRIVATE_ERROR", url="https://search/?q=SECRET")
        redacted = json.dumps(probe.redacted_event(event))
        for text in ("PRIVATE_ERROR", "SECRET", "Norbert", "Notes"):
            self.assertNotIn(text, redacted)
        self.assertIn("text_length", redacted)

    def test_free_form_status_cannot_leak_through_metadata(self):
        event = {"type": "partial", "session_id": "replay", "sequence": 1,
                 "text": "PRIVATE_WORDS", "status": "PRIVATE_STATUS"}
        with self.assertRaisesRegex(probe.ProbeError, "invalid-status-metadata"):
            probe.LegacyTrace("replay").accept(event)
        self.assertNotIn("PRIVATE", json.dumps(probe.redacted_event(event)))

    def test_schema_enum_rejects_boolean_integer_alias(self):
        with self.assertRaises(ValueError):
            probe.validate_schema(True, {"enum": [0, 1, 2, 3, 4, 130]})

    def test_changed_contract_member_refuses_even_with_unchanged_index(self):
        fixture_copy = self.root / "fixtures"
        shutil.copytree(probe.FIXTURES, fixture_copy)
        (fixture_copy / "browser/search.html").write_text("WRONG FIXTURE")
        with patch.object(probe, "FIXTURES", fixture_copy):
            with self.assertRaisesRegex(probe.ProbeError, "contract-member-hash-mismatch"):
                self.load()

    def test_desktop_lease_covers_owned_cleanup(self):
        order = []

        class Lease:
            def __enter__(self):
                order.append("lease-acquire")
            def __exit__(self, *_):
                order.append("lease-release")

        class Run:
            def __init__(self, *_):
                self.assertions = []
            def __enter__(self):
                order.append("owned-enter")
                return self
            def __exit__(self, *_):
                order.append("owned-cleanup")

        with patch.object(probe.Manifest, "environment"), patch.object(probe.Manifest, "output"), \
             patch.object(probe, "OwnedRun", Run), patch.object(probe, "DesktopLease", Lease), \
             patch.object(probe, "capability_preflight", return_value={"state": "VERIFIED"}), \
             patch.object(probe, "write_json"), patch.object(probe, "receipt"), \
             patch("actions_probe_browser.observe_chrome", side_effect=lambda *_args, **_kwargs: order.append("chrome-live")):
            probe.execute(SimpleNamespace(command="run", scenario="chrome-fixture"), self.load(), self.root / "out")
        self.assertEqual(order, ["lease-acquire", "owned-enter", "chrome-live", "owned-cleanup", "lease-release"])

    def test_exited_browser_parent_cannot_certify_descendant_cleanup(self):
        manifest = self.load()
        child = SimpleNamespace(pid=123, poll=lambda: 0, stdout=None)
        with self.assertRaisesRegex(probe.ProbeError, "cleanup-incomplete"):
            with probe.OwnedRun(manifest, self.root / "orphan") as run:
                run.children.append((child, {"pid": 123, "role": "chrome"}))
        rows = json.loads((self.root / "orphan/cleanup.json").read_text())
        self.assertTrue(any(row["state"] == "parent-exited-before-descendant-reconciliation" for row in rows))

    def test_unobservable_discovered_descendant_prevents_cleanup_success(self):
        state = {"code": None}
        child = SimpleNamespace(pid=123, stdout=None, poll=lambda: state["code"],
                                terminate=lambda: state.update(code=0), wait=lambda timeout: state["code"])
        with patch.object(probe, "matches_process", return_value=True), \
             patch.object(probe.subprocess, "check_output", return_value="123 1\n124 123\n"), \
             patch.object(probe, "process_identity", side_effect=probe.ProbeError(2, "process-not-observable")):
            with self.assertRaisesRegex(probe.ProbeError, "cleanup-incomplete"):
                with probe.OwnedRun(self.load(), self.root / "unobservable") as run:
                    run.children.append((child, {"pid": 123, "role": "chrome"}))
        rows = json.loads((self.root / "unobservable/cleanup.json").read_text())
        self.assertIn({"pid": 124, "ppid": 123, "state": "descendant-identity-unavailable"}, rows)

    def test_recorded_descendant_is_reconciled_after_parent_exit(self):
        manifest = self.load()
        parent = SimpleNamespace(pid=123, poll=lambda: 0, stdout=None)
        descendant = {"pid": 456, "uid": 502, "ppid": 1, "start_us": 5,
                      "executable": "/fixture/helper", "sha256": "a" * 64}
        alive = {456}
        signalled = []

        def signal_owned(pid, _signal):
            signalled.append(pid)
            alive.discard(pid)

        with patch.object(probe, "matches_process", side_effect=lambda identity: identity["pid"] in alive), \
             patch.object(probe.subprocess, "check_output", return_value="456 1\n"), \
             patch.object(probe.os, "kill", side_effect=signal_owned):
            with self.assertRaisesRegex(probe.ProbeError, "cleanup-incomplete"):
                with probe.OwnedRun(manifest, self.root / "reparented") as run:
                    run.children.append((parent, {"pid": 123, "role": "chrome"}))
                    run.descendants.append(descendant)
        self.assertEqual(signalled, [456])
        self.assertFalse(alive)

    def test_stale_pid_never_matches(self):
        with patch.object(probe, "process_identity", return_value={"pid": 42, "uid": 502, "start_us": 11,
                          "executable": "/fixture/engine", "sha256": "a" * 64}):
            self.assertFalse(probe.matches_process({"pid": 42, "uid": 502, "start_us": 10,
                             "executable": "/fixture/engine", "sha256": "a" * 64}))

    def test_native_helper_compiles_lints_and_refuses_unsafe_account_before_ax(self):
        if sys.platform != "darwin":
            self.skipTest("standalone macOS helper")
        source = probe.ROOT / "scripts/ActionsProbe/main.swift"
        binary = self.root / "ActionsProbe-test"
        built = subprocess.run(["swiftc", "-warnings-as-errors", str(source), "-o", str(binary)],
                               capture_output=True, text=True, timeout=60)
        self.assertEqual(built.returncode, 0, built.stderr)
        lint_tool = os.environ.get("SWIFTLINT") or shutil.which("swiftlint")
        self.assertTrue(lint_tool, "SwiftLint is required by the repository gates")
        lint = subprocess.run([lint_tool, "lint", "--strict", "--no-cache", "--config",
                               str(probe.ROOT / ".swiftlint.yml"), str(source)], capture_output=True, text=True, timeout=60)
        self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)
        facts = subprocess.run([str(binary), "--process-facts", str(os.getpid())],
                               capture_output=True, text=True, timeout=10)
        self.assertEqual(facts.returncode, 0, facts.stderr)
        actual = json.loads(facts.stdout)
        self.assertEqual(actual["start_us"], probe.process_identity(os.getpid())["start_us"])
        refused = subprocess.run([str(binary), "--observe", "--pid", str(os.getpid()), "--uid", "0",
                                  "--start-us", "1", "--samples", "1", "--interval-ms", "50"],
                                 capture_output=True, text=True, timeout=10)
        self.assertEqual(refused.returncode, 2)
        self.assertEqual(json.loads(refused.stdout)["reason"], "unsafe_observer_account")

    def test_kernel_identity_for_this_test_process(self):
        if sys.platform != "darwin":
            self.skipTest("macOS kernel identity")
        identity = probe.process_identity(os.getpid())
        self.assertEqual(identity["pid"], os.getpid())
        self.assertEqual(identity["uid"], os.getuid())
        self.assertEqual(identity["ppid"], os.getppid())
        self.assertGreater(identity["start_us"], 0)
        self.assertTrue(probe.matches_process(identity))

    def test_os_level_lease_contention_and_release(self):
        with probe.DesktopLease(self.root):
            with self.assertRaisesRegex(probe.ProbeError, "desktop-lease-busy"):
                with probe.DesktopLease(self.root):
                    self.fail("second lease admitted")
        with probe.DesktopLease(self.root):
            pass
        self.assertTrue((self.root / "com.superkeet.actions-probe.desktop.lock").exists())

    def test_lease_refuses_symlink(self):
        (self.root / "com.superkeet.actions-probe.desktop.lock").symlink_to(self.root / "foreign")
        with self.assertRaises(OSError):
            with probe.DesktopLease(self.root):
                pass

    def test_collector_rejects_malformed_and_incomplete_actual_pipe_bytes(self):
        manifest = self.load()
        for index, raw in enumerate((b"not-json\n", b"{\xff}\n", json.dumps(self.final()).encode(),
                                      (json.dumps(self.final()) + "\\n" + json.dumps(self.final()) + "\\n").encode())):
            read_fd, write_fd = os.pipe()
            os.write(write_fd, raw)
            os.close(write_fd)
            with os.fdopen(read_fd, "rb") as stream:
                with probe.OwnedRun(manifest, self.root / f"pipe-{index}") as run:
                    with self.assertRaises(probe.ProbeError):
                        run.collect(SimpleNamespace(stdout=stream), probe.LegacyTrace("replay"), 2)

    def test_interruption_cleans_only_owned_real_cli_child(self):
        if sys.platform != "darwin":
            self.skipTest("macOS process identity")
        executable = probe.process_identity(os.getpid())["executable"]
        manifest = self.load()
        manifest.data["artifacts"]["test-interpreter"] = {"path": executable, "sha256": probe.sha256(executable)}
        unrelated = subprocess.Popen([executable, "-c", "import time; time.sleep(30)"])
        self.addCleanup(lambda: unrelated.wait(timeout=5))
        self.addCleanup(unrelated.terminate)
        with self.assertRaises(KeyboardInterrupt):
            with probe.OwnedRun(manifest, self.root / "interrupted") as run:
                child = run.spawn([executable, "-c", "import time; time.sleep(30)"])
                raise KeyboardInterrupt()
        self.assertIsNotNone(child.poll())
        self.assertIsNone(unrelated.poll())
        cleanup = json.loads((self.root / "interrupted/cleanup.json").read_text())
        self.assertEqual(cleanup, [{"pid": child.pid, "state": "exited"}])

    def test_cleanup_preserves_error_when_child_exits_during_identity_check(self):
        if sys.platform != "darwin":
            self.skipTest("macOS process identity")
        executable = probe.process_identity(os.getpid())["executable"]
        manifest = self.load()
        manifest.data["artifacts"]["engine"] = {"path": executable, "sha256": probe.sha256(executable)}
        original = probe.ProbeError(1, "original-stream-invariant-failure")
        real_matches = probe.matches_process
        child = None
        released = []
        run = None

        def exit_before_identity_check(identity):
            if sys._getframe(1).f_code.co_name == "__exit__":
                self.assertIsNone(child.returncode)
                child.stdin.write(b"exit\n")
                child.stdin.close()
                deadline = time.monotonic() + 5
                while (status := os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)) is None:
                    self.assertLess(time.monotonic(), deadline, "child did not become waitable before exit deadline")
                    time.sleep(0.001)
                self.assertEqual((status.si_pid, status.si_code, status.si_status), (child.pid, os.CLD_EXITED, 0))
                self.assertIsNone(child.returncode)
                self.assertFalse(real_matches(identity), "terminated child identity still matches")
                released.append(child.pid)
            return real_matches(identity)

        try:
            with self.assertRaises(probe.ProbeError) as caught:
                with patch.object(probe, "matches_process", new=exit_before_identity_check), \
                     patch.object(subprocess.Popen, "terminate", side_effect=AssertionError("child signalled")), \
                     patch.object(subprocess.Popen, "kill", side_effect=AssertionError("child signalled")):
                    with probe.OwnedRun(manifest, self.root / "natural-exit") as run:
                        child = run.spawn([executable, "-c", "import sys; print('READY', flush=True); sys.stdin.readline()"],
                                          stdin=subprocess.PIPE)
                        self.assertEqual(child.stdout.readline(), b"READY\n")
                        self.assertTrue(real_matches(run.children[-1][1]))
                        raise original
            self.assertIs(caught.exception, original)
            self.assertEqual((caught.exception.code, caught.exception.reason), (1, "original-stream-invariant-failure"))
            self.assertEqual(released, [child.pid])
            self.assertEqual(child.returncode, 0)
            self.assertTrue(child.stdin.closed)
            self.assertTrue(child.stdout.closed)
            self.assertTrue(run.events.closed)
            self.assertTrue(all(stream is None or stream.closed for stream in (run.raw, run.wire)))
            self.assertEqual(json.loads((run.out / "cleanup.json").read_text()),
                             [{"pid": child.pid, "state": "exited"}])
            with self.assertRaises(ChildProcessError):
                os.waitpid(child.pid, os.WNOHANG)
        finally:
            if child is not None:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=5)
                for stream in (child.stdin, child.stdout):
                    if stream and not stream.closed:
                        stream.close()
            if run is not None:
                for stream in (run.events, run.raw, run.wire):
                    if stream and not stream.closed:
                        stream.close()

    def test_cleanup_does_not_signal_reused_identity(self):
        if sys.platform != "darwin":
            self.skipTest("macOS process identity")
        executable = probe.process_identity(os.getpid())["executable"]
        manifest = self.load()
        manifest.data["artifacts"]["engine"] = {"path": executable, "sha256": probe.sha256(executable)}
        child = None
        try:
            with self.assertRaisesRegex(probe.ProbeError, "cleanup-incomplete"), \
                 patch.object(subprocess.Popen, "terminate", side_effect=AssertionError("foreign process signalled")), \
                 patch.object(subprocess.Popen, "kill", side_effect=AssertionError("foreign process signalled")):
                with probe.OwnedRun(manifest, self.root / "reused") as run:
                    child = run.spawn([executable, "-c", "import sys; print('READY', flush=True); sys.stdin.readline()"],
                                      stdin=subprocess.PIPE)
                    self.assertEqual(child.stdout.readline(), b"READY\n")
                    identity = run.children[-1][1]
                    self.assertTrue(probe.matches_process(identity))
                    identity["start_us"] += 1
                    self.assertFalse(probe.matches_process(identity))
            self.assertIsNone(child.poll())
            self.assertTrue(child.stdout.closed)
            self.assertTrue(run.events.closed)
            self.assertEqual(json.loads((run.out / "cleanup.json").read_text()),
                             [{"pid": child.pid, "state": "identity-mismatch-not-signalled"}])
            child.stdin.write(b"exit\n")
            child.stdin.close()
            self.assertEqual(child.wait(timeout=5), 0)
        finally:
            if child is not None:
                if child.poll() is None:
                    child.terminate()
                child.wait(timeout=5)
                for stream in (child.stdin, child.stdout):
                    if stream and not stream.closed:
                        stream.close()

    def test_cli_refusal_has_nonzero_exit_and_no_output_or_launch(self):
        path = self.root / "manifest.json"
        path.write_text(json.dumps(self.manifest))
        out = self.root / "unsafe-output"
        command = [sys.executable, str(Path(probe.__file__)), "run", "--scenario", "legacy-wav",
                   "--manifest", str(path), "--out", str(out)]
        result = subprocess.run(command, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(out.exists())
        self.assertFalse(json.loads(result.stdout)["program_verified"])
        self.assertNotIn("/fixture/audio", result.stdout)

    def test_cli_invalid_manifest_exit2(self):
        path = self.root / "bad.json"
        path.write_text('{"schema_version":1,"schema_version":1}')
        result = subprocess.run([sys.executable, probe.__file__, "preflight", "--manifest", str(path),
                                 "--out", str(self.root / "out")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / "out").exists())

    def test_future_capability_cannot_be_asserted_from_manifest(self):
        manifest = self.load()
        manifest.data["requested_capability"] = "continuous-turns-v1"
        with patch.object(probe, "engine_protocol") as engine:
            self.assertEqual(probe.capability_preflight(manifest)["state"], "BLOCKED")
            engine.assert_not_called()

    def test_compare_requires_complete_work_and_recorder_counts(self):
        samples = [{"arm": arm, "exit_code": 0, "elapsed_ns": 1000000000,
                    "event_count": 2, "recorder_ns": [1000, 2000]} for _ in range(10) for arm in ("A", "B")]
        self.assertTrue(probe.assess_samples(samples)["budgets_passed"])
        self.assertEqual(probe.assess_samples(samples)["event_count"], 40)
        self.assertFalse(probe.assess_samples(samples[:-1])["budgets_passed"])
        samples[0]["event_count"] = 3
        self.assertFalse(probe.assess_samples(samples)["budgets_passed"])
        samples[0]["event_count"] = 100
        samples[0]["recorder_ns"] = [3000000] * 100
        self.assertFalse(probe.assess_samples(samples)["budgets_passed"])

    def test_shared_median_budget_needs_both_limits(self):
        samples = [{"arm": arm, "exit_code": 0, "elapsed_ns": (1000 if arm == "A" else 1150) * 1000000,
                    "event_count": 1, "recorder_ns": [1000]} for _ in range(10) for arm in ("A", "B")]
        self.assertTrue(probe.assess_samples(samples)["budgets_passed"])
        for row in samples:
            if row["arm"] == "B":
                row["elapsed_ns"] = 1300 * 1000000
        self.assertFalse(probe.assess_samples(samples)["budgets_passed"])

    def test_frozen_payloads_match_exact_demo_content(self):
        grammar = probe.strict_json((probe.FIXTURES / "golden/grammar.json").read_bytes())
        payloads = {row["intent"]: row.get("payload") for row in grammar}
        self.assertEqual(payloads["set-title"], "Prototype hello")
        self.assertEqual(payloads["append-body"], "Open Safari is literal text.")
        self.assertEqual(payloads["browser-search"], "Norbert Wiener")

    def test_frozen_contract_inventory_matches_all_files(self):
        index = probe.strict_json((probe.FIXTURES / "contract-index.json").read_bytes())
        actual = {p.relative_to(probe.FIXTURES).as_posix(): probe.sha256(p)
                  for p in probe.FIXTURES.rglob("*") if p.is_file() and p.name != "contract-index.json"}
        self.assertEqual(index, actual)

    def test_protocol3_requests_and_rejected_replies_match_schema(self):
        for stem in ("requests", "replies"):
            schema = probe.strict_json((probe.FIXTURES / f"schemas/protocol3-{'request' if stem == 'requests' else 'reply'}-v1.json").read_bytes())
            for value in probe.strict_json((probe.FIXTURES / f"golden/{stem}.json").read_bytes()):
                probe.validate_schema(value, schema)
                value["unexpected"] = True
                with self.assertRaises(ValueError):
                    probe.validate_schema(value, schema)

    def test_protocol3_semantics_reject_gap_overlap_revision_and_late_event(self):
        rows = [probe.strict_json(line) for line in (probe.FIXTURES / "golden/revision-finish.ndjson").read_bytes().splitlines()]
        self.assertEqual(probe.validate_protocol3_trace(rows)["turn_count"], 1)
        for change in (lambda r: r[1].update(event_id=99),
                       lambda r: r[3].update(replaces_revision=0),
                       lambda r: r[-2]["source_range"].update(start=23999),
                       lambda r: r[-1].update(accepted_through=33000),
                       lambda r: r.append(copy.deepcopy(r[-1])),
                       lambda r: r[6].update(session_id="foreign"),
                       lambda r: r[6].update(status="error", failed_segments=1),
                       lambda r: r[8].update(kind="loss"),
                       lambda r: r[7].update(kind="silence", turn_id="")):
            changed = copy.deepcopy(rows)
            change(changed)
            with self.assertRaises(ValueError):
                probe.validate_protocol3_trace(changed)

    def test_protocol3_golden_shapes(self):
        schema = probe.strict_json((probe.FIXTURES / "schemas/protocol3-event-v1.json").read_bytes())
        for path in (probe.FIXTURES / "golden").glob("*.ndjson"):
            rows = [probe.strict_json(line) for line in path.read_bytes().splitlines()]
            for row in rows:
                probe.validate_schema(row, schema)
            probe.validate_protocol3_trace(rows)


if __name__ == "__main__":
    unittest.main()
