#!/usr/bin/env python3
DESCRIPTION = "Exercise the actual daemon transport and capture-failure completion, without recording audio."
import argparse
import json
from pathlib import Path
import selectors
import socket
import subprocess
import tempfile
import time


def request(path, message, split=False):
    data = (json.dumps(message, ensure_ascii=False) + "\n").encode()
    with socket.socket(socket.AF_UNIX) as stream:
        stream.settimeout(5)
        stream.connect(str(path))
        if split:
            for byte in data:
                stream.sendall(bytes([byte]))
        else:
            stream.sendall(data)
        response = bytearray()
        while not response.endswith(b"\n"):
            chunk = stream.recv(4096)
            if not chunk:
                raise AssertionError("Response ended before its frame completed")
            response.extend(chunk)
        return json.loads(response)


def main():
    parser = argparse.ArgumentParser(description=DESCRIPTION)
    parser.add_argument("--engine", type=Path, required=True)
    parser.add_argument("--model-dir", type=Path, required=True)
    parser.add_argument("--runtime-root", type=Path)
    args = parser.parse_args()
    assert subprocess.check_output([str(args.engine), "protocol-version"], text=True).strip() == "1"
    with tempfile.TemporaryDirectory(prefix="sk-", dir=args.runtime_root) as directory:
        path = Path(directory) / "s"
        pid = Path(directory) / "p"
        engine = subprocess.Popen([str(args.engine), "serve", "--socket", str(path), "--pid-file", str(pid),
                                   "--model-dir", str(args.model_dir), "--device", "__superkeet_missing_device__"],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 30
            while not path.exists():
                if engine.poll() is not None:
                    raise AssertionError(engine.stderr.read())
                if time.monotonic() > deadline:
                    raise TimeoutError("Engine did not start")
                time.sleep(0.05)
            assert request(path, {"command": "status"})["protocol_version"] == 1
            with selectors.DefaultSelector() as selector:
                selector.register(engine.stdout, selectors.EVENT_READ)
                for session_id in ["first-🦜", "second-中文"]:
                    response = request(path, {"command": "start", "session_id": session_id}, split=True)
                    assert response["status"] == "error"
                    assert selector.select(timeout=5), "Missing completion after capture failure"
                    event = json.loads(engine.stdout.readline())
                    assert event["type"] == "complete" and event["session_id"] == session_id
                    assert event["status"] == "error" and event["text"] == ""
                    assert request(path, {"command": "status"})["state"] == "idle"
            request(path, {"command": "shutdown"})
            engine.communicate(timeout=10)
            assert engine.returncode == 0
            assert not path.exists() and not pid.exists()
        finally:
            if engine.poll() is None:
                engine.terminate()
                try:
                    engine.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    engine.kill()
                    engine.communicate()
    print("PASS: protocol version, fragmented Unicode commands, per-session failure completion, recovery, shutdown cleanup")


if __name__ == "__main__":
    main()
