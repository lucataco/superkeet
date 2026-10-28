# These tests start short-lived stand-in processes named Superkeet, so run them outside a live session.
import os
import shlex
import shutil
import subprocess
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "control-superkeet")
STANDIN_SOURCE = "#include <unistd.h>\nint main(void) { for (;;) sleep(1); }\n"
# Creates the marker named in argv[1] only after the handler is installed, so a test can wait for it.
TERM_IGNORING_SOURCE = (
    "#include <signal.h>\n#include <stdio.h>\n#include <unistd.h>\n"
    "int main(int argc, char **argv) {\n"
    "  signal(SIGTERM, SIG_IGN);\n"
    "  FILE *marker = fopen(argv[1], \"w\");\n"
    "  if (marker) fclose(marker);\n"
    "  for (;;) sleep(1);\n"
    "}\n"
)


def build_standin(path, source_text=STANDIN_SOURCE):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    source = path + ".c"
    with open(source, "w", encoding="utf-8") as handle:
        handle.write(source_text)
    subprocess.run(["cc", "-o", path, source], check=True)
    os.remove(source)


def ps_field(field, pid):
    result = subprocess.run(["ps", "-o", f"{field}=", "-p", str(pid)], capture_output=True, text=True)
    return result.stdout.strip()


@unittest.skipUnless(shutil.which("cc"), "building the stand-in binary needs cc")
class QuitIdentityTests(unittest.TestCase):
    def setUp(self):
        self.root = os.path.realpath(tempfile.mkdtemp())
        self.state_dir = os.path.join(self.root, "state")
        self.bundle = os.path.join(self.root, "Superkeet.app")
        self.bundle_exec = os.path.join(self.bundle, "Contents", "MacOS", "Superkeet")
        self.elsewhere_exec = os.path.join(self.root, "Other.app", "Contents", "MacOS", "Superkeet")
        self.procs = []

    def tearDown(self):
        for proc in self.procs:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        shutil.rmtree(self.root, ignore_errors=True)

    def start_standin(self, path):
        build_standin(path)
        proc = subprocess.Popen([path])
        self.procs.append(proc)
        for _ in range(40):
            if ps_field("comm", proc.pid):
                break
            time.sleep(0.05)
        return proc

    def record(self, pid, bundle, exec_path, start):
        os.makedirs(self.state_dir, exist_ok=True)
        values = {
            "RUN_ID": "test",
            "PID": str(pid),
            "BUNDLE": bundle,
            "STARTED_AT": "test",
            "DRIVER": "system-events",
            "EXEC": exec_path,
            "START": start,
        }
        with open(os.path.join(self.state_dir, "state"), "w", encoding="utf-8") as handle:
            for key, value in values.items():
                handle.write(f"{key}={shlex.quote(value)}\n")

    def run_quit(self):
        env = dict(os.environ, SUPERKEET_VERIFY_STATE_DIR=self.state_dir, SUPERKEET_VERIFY_DRIVER="system-events")
        return subprocess.run(["bash", SCRIPT, "quit"], env=env, capture_output=True, text=True, timeout=30)

    def assert_nothing_signalled(self, proc, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("state cleared, nothing signalled", result.stdout)
        self.assertIsNone(proc.poll(), "the process that does not match was signalled")
        self.assertFalse(os.path.exists(os.path.join(self.state_dir, "state")))

    def test_process_running_from_another_path_is_never_signalled(self):
        proc = self.start_standin(self.elsewhere_exec)
        self.record(proc.pid, self.bundle, self.bundle_exec, ps_field("lstart", proc.pid))
        self.assert_nothing_signalled(proc, self.run_quit())

    def test_recorded_executable_outside_the_bundle_is_never_signalled(self):
        proc = self.start_standin(self.elsewhere_exec)
        self.record(proc.pid, self.bundle, self.elsewhere_exec, ps_field("lstart", proc.pid))
        self.assert_nothing_signalled(proc, self.run_quit())

    def test_reused_pid_with_another_start_time_is_never_signalled(self):
        proc = self.start_standin(self.bundle_exec)
        self.record(proc.pid, self.bundle, self.bundle_exec, "Mon Jan  1 00:00:00 2001")
        self.assert_nothing_signalled(proc, self.run_quit())

    def test_missing_start_time_fails_closed(self):
        proc = self.start_standin(self.bundle_exec)
        self.record(proc.pid, self.bundle, self.bundle_exec, "")
        self.assert_nothing_signalled(proc, self.run_quit())

    def test_missing_executable_fails_closed(self):
        proc = self.start_standin(self.bundle_exec)
        self.record(proc.pid, self.bundle, "", ps_field("lstart", proc.pid))
        self.assert_nothing_signalled(proc, self.run_quit())

    def test_term_ignoring_process_is_killed_after_the_grace_period(self):
        build_standin(self.bundle_exec, TERM_IGNORING_SOURCE)
        marker = os.path.join(self.root, "handler-installed")
        proc = subprocess.Popen([self.bundle_exec, marker])
        self.procs.append(proc)
        for _ in range(100):
            if os.path.exists(marker):
                break
            time.sleep(0.05)
        self.assertTrue(os.path.exists(marker), "the stand-in never installed its SIGTERM handler")
        self.record(proc.pid, self.bundle, self.bundle_exec, ps_field("lstart", proc.pid))
        started = time.monotonic()
        result = self.run_quit()
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"quit pid={proc.pid} (SIGKILL after 5s)", result.stdout)
        self.assertGreaterEqual(elapsed, 5.0)
        self.assertLess(elapsed, 12.0)
        proc.wait(timeout=5)

    def test_matching_identity_is_quit_by_pid(self):
        proc = self.start_standin(self.bundle_exec)
        self.record(proc.pid, self.bundle, self.bundle_exec, ps_field("lstart", proc.pid))
        result = self.run_quit()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"quit pid={proc.pid} (SIGTERM)", result.stdout)
        proc.wait(timeout=5)
        self.assertNotEqual(proc.returncode, None)


if __name__ == "__main__":
    unittest.main()
