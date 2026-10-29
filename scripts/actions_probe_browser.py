import base64
import dataclasses
import hashlib
import html
import http.client
import http.server
import json
import math
import os
from pathlib import Path
import re
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
import urllib.parse

MAX_FRAME = 4 * 1024 * 1024
MAX_MESSAGE = 8 * 1024 * 1024
MAX_HTTP = 64 * 1024
MARKER = "Actions probe result"
BROWSER_PATH = re.compile(r"/devtools/browser/[A-Za-z0-9-]+\Z")
METHODS = frozenset({
    "SystemInfo.getProcessInfo", "Browser.getBrowserCommandLine", "Target.createTarget",
    "Target.attachToTarget", "Target.getTargetInfo", "Page.enable", "Page.navigate",
    "Page.getFrameTree", "Accessibility.enable", "Accessibility.getFullAXTree", "Page.captureScreenshot",
})


class BrowserFailure(Exception):
    def __init__(self, code, reason):
        self.code, self.reason = code, reason
        super().__init__(reason)


def _fail(code, reason):
    raise BrowserFailure(code, reason)


def _json(payload):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                _fail(2, "chrome-duplicate-json-key")
            result[key] = value
        return result
    def number(value):
        result = float(value)
        if not math.isfinite(result):
            _fail(2, "chrome-nonfinite-json")
        return result
    try:
        return json.loads(payload, object_pairs_hook=pairs, parse_float=number,
                          parse_constant=lambda _: _fail(2, "chrome-nonfinite-json"))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise BrowserFailure(2, "chrome-invalid-json") from error


def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        _fail(4, "chrome-transport-deadline")
    return remaining


@dataclasses.dataclass(frozen=True)
class Endpoint:
    port: int
    browser_path: str

    def __post_init__(self):
        if (type(self.port) is not int or not 1 <= self.port <= 65535
                or not isinstance(self.browser_path, str) or not BROWSER_PATH.fullmatch(self.browser_path)):
            _fail(2, "chrome-invalid-endpoint")

    def verify_version(self, version):
        expected = f"ws://127.0.0.1:{self.port}{self.browser_path}"
        if not isinstance(version, dict) or version.get("webSocketDebuggerUrl") != expected:
            _fail(2, "chrome-browser-websocket-mismatch")


@dataclasses.dataclass(frozen=True)
class Binding:
    process: dict
    profile: Path
    endpoint: Endpoint
    target_id: str
    session_id: str


def read_active_port(profile, launched_ns):
    fd = os.open(profile / "DevToolsActivePort", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        facts = os.fstat(fd)
        if (not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_nlink != 1
                or facts.st_mtime_ns < launched_ns or facts.st_size > 4096):
            _fail(2, "chrome-active-port-identity")
        raw = os.read(fd, 4097)
    finally:
        os.close(fd)
    try:
        lines = raw.decode("ascii").splitlines()
        if len(lines) != 2 or not re.fullmatch(r"[1-9][0-9]{0,4}", lines[0]):
            _fail(2, "chrome-invalid-active-port")
        return Endpoint(int(lines[0]), lines[1])
    except UnicodeError as error:
        raise BrowserFailure(2, "chrome-invalid-active-port") from error


def verify_listener_output(output, pid, port):
    try:
        lines = output.decode("ascii").splitlines()
    except UnicodeError as error:
        raise BrowserFailure(2, "chrome-listener-binding-invalid") from error
    owners = [line[1:] for line in lines if line.startswith("p")]
    sockets = [line[1:] for line in lines if line.startswith("n")]
    if owners != [str(pid)] or not sockets or any(name != f"127.0.0.1:{port}" for name in sockets):
        _fail(2, "chrome-listener-binding-invalid")
    return {"source": "lsof-pid-tcp-listen", "pid": pid, "addresses": sockets}


def verify_listener(pid, endpoint, deadline):
    try:
        result = subprocess.run(
            ["/usr/sbin/lsof", "-nP", "-a", "-p", str(pid), f"-iTCP:{endpoint.port}", "-sTCP:LISTEN", "-Fpcn"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=min(3, _remaining(deadline)), check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise BrowserFailure(3, "chrome-listener-owner-unavailable") from error
    if result.returncode != 0 or len(result.stdout) > MAX_HTTP:
        _fail(3, "chrome-listener-owner-unavailable")
    return verify_listener_output(result.stdout, pid, endpoint.port)


def get_version(endpoint, deadline):
    connection = http.client.HTTPConnection("127.0.0.1", endpoint.port, timeout=min(3, _remaining(deadline)))
    try:
        connection.request("GET", "/json/version")
        response = connection.getresponse()
        payload = response.read(MAX_HTTP + 1)
        if response.status != 200 or len(payload) > MAX_HTTP:
            _fail(2, "chrome-version-response-invalid")
        version = _json(payload)
        endpoint.verify_version(version)
        return version
    finally:
        connection.close()


class WebSocket:
    def __init__(self, endpoint, deadline):
        self.socket = socket.create_connection(("127.0.0.1", endpoint.port), timeout=min(3, _remaining(deadline)))
        self.buffer = bytearray()
        try:
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            request = (f"GET {endpoint.browser_path} HTTP/1.1\r\nHost: 127.0.0.1:{endpoint.port}\r\n"
                       f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                       "Sec-WebSocket-Version: 13\r\n\r\n")
            self._send(request.encode("ascii"), deadline)
            while b"\r\n\r\n" not in self.buffer:
                self.socket.settimeout(_remaining(deadline))
                chunk = self.socket.recv(4096)
                if not chunk:
                    _fail(4, "chrome-websocket-closed")
                self.buffer.extend(chunk)
                if len(self.buffer) > 16384:
                    _fail(2, "chrome-websocket-header-limit")
            header, rest = bytes(self.buffer).split(b"\r\n\r\n", 1)
            self.buffer = bytearray(rest)
            rows = header.decode("ascii").split("\r\n")
            headers = {}
            for row in rows[1:]:
                name, separator, value = row.partition(":")
                name = name.lower()
                if not separator or name in headers:
                    _fail(2, "chrome-websocket-handshake-invalid")
                headers[name] = value.strip()
            accept = base64.b64encode(hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
            ).digest()).decode("ascii")
            if (rows[0].split(" ", 2)[:2] != ["HTTP/1.1", "101"]
                    or headers.get("upgrade", "").lower() != "websocket"
                    or "upgrade" not in [token.strip() for token in headers.get("connection", "").lower().split(",")]
                    or headers.get("sec-websocket-accept") != accept
                    or "sec-websocket-extensions" in headers or "sec-websocket-protocol" in headers):
                _fail(2, "chrome-websocket-handshake-invalid")
        except BaseException:
            self.close()
            raise

    def close(self):
        self.socket.close()

    def _send(self, payload, deadline):
        self.socket.settimeout(_remaining(deadline))
        self.socket.sendall(payload)

    def _read(self, length, deadline):
        while len(self.buffer) < length:
            self.socket.settimeout(_remaining(deadline))
            chunk = self.socket.recv(min(65536, length - len(self.buffer)))
            if not chunk:
                _fail(4, "chrome-websocket-closed")
            self.buffer.extend(chunk)
        result = bytes(self.buffer[:length])
        del self.buffer[:length]
        return result

    def send(self, payload, deadline, opcode=1):
        if len(payload) > MAX_FRAME or opcode not in (1, 10) or (opcode == 10 and len(payload) > 125):
            _fail(2, "chrome-websocket-send-limit")
        length = len(payload)
        if length < 126:
            header = bytes((0x80 | opcode, 0x80 | length))
        elif length <= 65535:
            header = bytes((0x80 | opcode, 0x80 | 126)) + struct.pack("!H", length)
        else:
            header = bytes((0x80 | opcode, 0x80 | 127)) + struct.pack("!Q", length)
        mask = os.urandom(4)
        encoded = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self._send(header + mask + encoded, deadline)

    def receive(self, deadline):
        message = bytearray()
        started = False
        for _ in range(1024):
            first, second = self._read(2, deadline)
            final, opcode, length = bool(first & 0x80), first & 0x0F, second & 0x7F
            if first & 0x70 or second & 0x80 or opcode not in (0, 1, 8, 9, 10):
                _fail(2, "chrome-websocket-frame-invalid")
            if opcode >= 8 and (not final or length > 125):
                _fail(2, "chrome-websocket-control-invalid")
            if length == 126:
                length = struct.unpack("!H", self._read(2, deadline))[0]
                if length < 126:
                    _fail(2, "chrome-websocket-frame-invalid")
            elif length == 127:
                length = struct.unpack("!Q", self._read(8, deadline))[0]
                if length <= 65535:
                    _fail(2, "chrome-websocket-frame-invalid")
            if length > MAX_FRAME or (opcode < 8 and len(message) + length > MAX_MESSAGE):
                _fail(2, "chrome-websocket-frame-limit")
            payload = self._read(length, deadline)
            if opcode == 8:
                _fail(4, "chrome-websocket-closed")
            if opcode == 9:
                self.send(payload, deadline, opcode=10)
                continue
            if opcode == 10:
                continue
            if (opcode == 1 and started) or (opcode == 0 and not started):
                _fail(2, "chrome-websocket-fragment-invalid")
            started = True
            message.extend(payload)
            if final:
                try:
                    return message.decode("utf-8")
                except UnicodeError as error:
                    raise BrowserFailure(2, "chrome-websocket-text-invalid") from error
        _fail(2, "chrome-websocket-fragment-limit")


class CDP:
    def __init__(self, websocket, deadline):
        self.websocket, self.deadline, self.sequence = websocket, deadline, 0

    def call(self, method, params=None, session=None):
        if method not in METHODS:
            _fail(2, "chrome-cdp-method-not-allowed")
        self.sequence += 1
        request = {"id": self.sequence, "method": method, "params": params or {}}
        if session is not None:
            request["sessionId"] = session
        deadline = min(self.deadline, time.monotonic() + 5)
        self.websocket.send(json.dumps(request, allow_nan=False).encode("utf-8"), deadline)
        for _ in range(512):
            response = _json(self.websocket.receive(deadline))
            if not isinstance(response, dict):
                _fail(2, "chrome-cdp-response-invalid")
            if "id" not in response:
                if not isinstance(response.get("method"), str):
                    _fail(2, "chrome-cdp-event-invalid")
                continue
            if type(response["id"]) is not int or response["id"] != self.sequence or response.get("sessionId") != session:
                _fail(2, "chrome-cdp-session-mismatch")
            if "error" in response:
                _fail(3, "chrome-cdp-command-refused")
            if not isinstance(response.get("result"), dict):
                _fail(2, "chrome-cdp-result-invalid")
            return response["result"]
        _fail(2, "chrome-cdp-event-limit")


def _option(arguments, name):
    values = []
    for index, argument in enumerate(arguments):
        if argument == name:
            values.append(arguments[index + 1] if index + 1 < len(arguments) else None)
        elif argument.startswith(name + "="):
            values.append(argument[len(name) + 1:])
    return values


def verify_browser_process(process_info, command_line, identity, profile):
    processes = process_info.get("processInfo")
    arguments = command_line.get("arguments")
    if (not isinstance(processes, list) or not all(isinstance(row, dict) for row in processes)
            or any(type(row.get("id")) is not int for row in processes)
            or [row.get("id") for row in processes if row.get("type") == "browser"] != [identity["pid"]]):
        _fail(2, "chrome-cdp-browser-pid-mismatch")
    if not isinstance(arguments, list) or not arguments or not all(isinstance(arg, str) for arg in arguments):
        _fail(2, "chrome-command-line-unavailable")
    if (arguments[0] != identity["executable"] or _option(arguments, "--user-data-dir") != [str(profile)]
            or _option(arguments, "--remote-debugging-address") != ["127.0.0.1"]
            or _option(arguments, "--remote-debugging-port") != ["0"] or "--enable-automation" not in arguments):
        _fail(2, "chrome-command-line-binding-mismatch")


def committed_url_matches(url, expected_url, query, public=False):
    if not isinstance(url, str) or any(ord(character) <= 32 for character in url) or "\\" in url:
        return False
    if not public:
        return url == expected_url
    try:
        parsed = urllib.parse.urlsplit(url)
        values = urllib.parse.parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True)
        return (parsed.scheme == "https" and parsed.netloc == "www.google.com" and parsed.path == "/search"
                and not parsed.fragment and values.get("q") == [query])
    except ValueError:
        return False


def result_matches(nodes, query, public=False):
    if not isinstance(nodes, list) or not nodes or len(nodes) > 50000:
        return False
    if not all(isinstance(node, dict) for node in nodes):
        return False
    visible = [node for node in nodes if node.get("ignored") is False]
    for node in visible:
        if any(not isinstance(node.get(key, {}), dict) for key in ("name", "role", "value")):
            return False
        properties = node.get("properties", [])
        if not isinstance(properties, list) or not all(isinstance(prop, dict) for prop in properties):
            return False
    names = [node.get("name", {}).get("value", "") for node in visible]
    if not all(isinstance(name, str) for name in names):
        return False
    if not public:
        return MARKER in names and any(query in name for name in names)
    content = "\n".join(names).casefold()
    challenges = ("unusual traffic", "captcha", "before you continue", "not a robot", "verify you are human",
                  "our systems have detected", "consent.google")
    if any(marker in content for marker in challenges):
        return False
    values = [node.get("value", {}).get("value", "") for node in visible if isinstance(node.get("value"), dict)]
    if not any(query in value for value in names + values if isinstance(value, str)):
        return False
    headings = [node for node in visible if node.get("role", {}).get("value") == "heading"]
    if not any(node.get("name", {}).get("value") in ("Search Results", "Search results") for node in headings):
        return False
    for node in visible:
        if node.get("role", {}).get("value") != "link" or not node.get("name", {}).get("value"):
            continue
        for prop in node.get("properties", []):
            if isinstance(prop, dict) and prop.get("name") == "url":
                value = prop.get("value", {})
                if not isinstance(value, dict) or not isinstance(value.get("value"), str):
                    continue
                try:
                    url = urllib.parse.urlsplit(value["value"])
                    if (url.scheme in ("http", "https") and url.hostname and url.hostname != "google.com"
                            and not url.hostname.endswith(".google.com")):
                        return True
                except (ValueError, AttributeError):
                    pass
    return False


def fixture_payload(template, query):
    if "QUERY" not in template or MARKER not in template or len(template.encode("utf-8")) > 1024 * 1024:
        _fail(2, "chrome-fixture-template-invalid")
    return template.replace("QUERY", html.escape(query, quote=True)).encode("utf-8")


class FixtureServer:
    def __init__(self, payload, query):

        class Handler(http.server.BaseHTTPRequestHandler):
            def setup(self):
                super().setup()
                self.connection.settimeout(2)

            def do_GET(self):
                try:
                    parsed = urllib.parse.urlsplit(self.path)
                    valid = (len(self.path) <= 8192 and parsed.scheme == "" and parsed.netloc == ""
                             and parsed.path == "/search" and not parsed.fragment
                             and urllib.parse.parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True) == {"q": [query]})
                except ValueError:
                    valid = False
                if not valid:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_):
                pass

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        self.url = f"http://127.0.0.1:{self.server.server_port}/search?{urllib.parse.urlencode({'q': query})}"

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)
        if self.thread.is_alive():
            _fail(4, "chrome-fixture-server-cleanup-incomplete")


def _new_profile(profile, root):
    if not profile.is_absolute() or ".." in profile.parts or profile == root or root not in profile.parents:
        _fail(2, "chrome-fresh-run-profile-required")
    for part in (profile, *profile.parents):
        if part.is_symlink():
            _fail(2, "chrome-profile-symlink")
    if profile.parent.stat().st_uid != os.getuid():
        _fail(2, "chrome-profile-parent-owner")
    try:
        profile.mkdir(mode=0o700)
    except FileExistsError as error:
        raise BrowserFailure(2, "chrome-existing-profile-refused") from error
    return profile.stat()


def _same_profile(profile, original):
    facts = profile.lstat()
    if (not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.getuid()
            or (facts.st_dev, facts.st_ino) != (original.st_dev, original.st_ino)):
        _fail(2, "chrome-profile-identity-changed")


def _target(cdp, binding):
    info = cdp.call("Target.getTargetInfo", {"targetId": binding.target_id}).get("targetInfo", {})
    if not isinstance(info, dict) or info.get("targetId") != binding.target_id or info.get("type") != "page":
        _fail(2, "chrome-page-target-mismatch")


def _frame(cdp, binding):
    _target(cdp, binding)
    tree = cdp.call("Page.getFrameTree", session=binding.session_id).get("frameTree", {})
    frame = tree.get("frame", {}) if isinstance(tree, dict) else None
    if (not isinstance(frame, dict) or not isinstance(frame.get("id"), str) or not frame["id"]
            or not isinstance(frame.get("loaderId"), str) or not frame["loaderId"] or frame.get("parentId")):
        _fail(2, "chrome-main-frame-invalid")
    return {key: frame.get(key) for key in ("id", "loaderId", "url")}


def main_frame_nodes(tree, frame_id):
    nodes = tree.get("nodes")
    if (not isinstance(nodes, list) or not nodes or len(nodes) > 50000
            or not all(isinstance(node, dict) and isinstance(node.get("nodeId"), str) for node in nodes)):
        _fail(2, "chrome-accessibility-tree-invalid")
    by_id = {node["nodeId"]: node for node in nodes}
    roots = [node for node in nodes if "parentId" not in node]
    if (len(by_id) != len(nodes) or len(roots) != 1 or roots[0].get("frameId") != frame_id
            or not isinstance(roots[0].get("role"), dict) or roots[0]["role"].get("value") != "RootWebArea"
            or any(node.get("frameId", frame_id) != frame_id for node in nodes)):
        _fail(2, "chrome-accessibility-frame-mismatch")
    children = {}
    for node in nodes:
        parent = node.get("parentId")
        if parent is not None:
            if not isinstance(parent, str) or parent not in by_id:
                _fail(2, "chrome-accessibility-tree-invalid")
            children.setdefault(parent, []).append(node["nodeId"])
    reached, pending = set(), [roots[0]["nodeId"]]
    while pending:
        node_id = pending.pop()
        if node_id in reached:
            _fail(2, "chrome-accessibility-tree-invalid")
        reached.add(node_id)
        pending.extend(children.get(node_id, []))
    if len(reached) != len(nodes):
        _fail(2, "chrome-accessibility-tree-disconnected")
    return nodes


def _observe(cdp, binding, expected_url, query, public, deadline, revalidate):
    while time.monotonic() < deadline:
        revalidate()
        before = _frame(cdp, binding)
        if before["url"] not in ("", "about:blank") and not committed_url_matches(before["url"], expected_url, query, public):
            _fail(3 if public else 1, "chrome-wrong-committed-url")
        tree = cdp.call("Accessibility.getFullAXTree", {"frameId": before["id"]}, binding.session_id)
        nodes = main_frame_nodes(tree, before["id"])
        after = _frame(cdp, binding)
        if (before == after and committed_url_matches(after["url"], expected_url, query, public)
                and result_matches(nodes, query, public)):
            return after, tree
        time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    _fail(3 if public else 1, "chrome-result-not-proven")


def _probe_api():
    main = sys.modules.get("__main__")
    main_path = getattr(main, "__file__", None)
    if main_path and Path(main_path).resolve() == Path(__file__).resolve().with_name("actions_probe.py"):
        return main
    import actions_probe
    return actions_probe


def observe_chrome(run, public=False):
    """Called only by the manifest-validated runner while it holds the desktop lease."""
    api = _probe_api()
    try:
        return _observe_chrome(run, public, api)
    except BrowserFailure as error:
        code = 3 if public and error.code == 4 else error.code
        reason = "chrome-public-result-unproven" if code != error.code else error.reason
        run.assertions.append({"id": "chrome-bound-result", "passed": False, "reason": reason})
        raise api.ProbeError(code, reason) from error
    except (ConnectionError, TimeoutError) as error:
        code = 3 if public else 4
        reason = "chrome-public-result-unproven" if public else "chrome-observation-incomplete"
        run.assertions.append({"id": "chrome-bound-result", "passed": False, "reason": reason})
        raise api.ProbeError(code, reason) from error
    except (OSError, http.client.HTTPException, subprocess.SubprocessError) as error:
        run.assertions.append({"id": "chrome-bound-result", "passed": False, "reason": "chrome-observation-incomplete"})
        raise api.ProbeError(4, "chrome-observation-incomplete") from error


def _observe_chrome(run, public, api):
    data = run.manifest.data
    if data.get("fixture_writes") is not True:
        _fail(2, "chrome-explicit-fixture-writes-required")
    if data.get("privacy", {}).get("retain_content") is not True:
        _fail(3, "chrome-screenshot-proof-requires-local-content-opt-in")
    if "chrome" not in data.get("artifacts", {}) or "chrome_profile" not in data.get("paths", {}):
        _fail(3, "chrome-artifact-and-fresh-profile-required")
    query = data.get("expected", {}).get("query")
    if not isinstance(query, str) or not query.strip() or len(query.encode("utf-8")) > 2048 or any(ord(c) < 32 for c in query):
        _fail(2, "chrome-explicit-bounded-query-required")
    fixture = Path(__file__).resolve().parents[1] / "Tests/Fixtures/actions-prototype/browser/search.html"
    payload = None
    if not public:
        with fixture.open("rb") as stream:
            raw = stream.read(1024 * 1024 + 1)
        if len(raw) > 1024 * 1024:
            _fail(2, "chrome-fixture-template-invalid")
        try:
            payload = fixture_payload(raw.decode("utf-8"), query)
        except UnicodeError as error:
            raise BrowserFailure(2, "chrome-fixture-template-invalid") from error
    profile = Path(data["paths"]["chrome_profile"])
    original = _new_profile(profile, run.manifest.root)
    launched_ns = time.time_ns()
    child = run.spawn([data["artifacts"]["chrome"]["path"], f"--user-data-dir={profile}",
                       "--remote-debugging-address=127.0.0.1", "--remote-debugging-port=0",
                       "--enable-automation", "--no-first-run", "about:blank"])
    identity = next((facts for process, facts in run.children if process is child), None)
    artifact = data["artifacts"]["chrome"]
    if (identity is None or identity.get("executable") != artifact["path"]
            or identity.get("sha256") != artifact["sha256"]):
        _fail(2, "chrome-owned-process-required")
    deadline = time.monotonic() + 40
    endpoint = None
    while time.monotonic() < deadline:
        _same_profile(profile, original)
        if child.poll() is not None or not api.matches_process(identity):
            _fail(2, "chrome-owned-process-lost")
        try:
            endpoint = read_active_port(profile, launched_ns)
            break
        except FileNotFoundError:
            time.sleep(min(0.1, max(0, deadline - time.monotonic())))
    if endpoint is None:
        _fail(3, "chrome-debug-endpoint-unavailable")

    def revalidate():
        _same_profile(profile, original)
        if child.poll() is not None or not api.matches_process(identity):
            _fail(2, "chrome-owned-process-lost")
        run.track_descendants()
        if read_active_port(profile, launched_ns) != endpoint:
            _fail(2, "chrome-debug-endpoint-changed")
        return verify_listener(child.pid, endpoint, deadline)

    revalidate()
    version = get_version(endpoint, deadline)
    websocket = WebSocket(endpoint, deadline)
    try:
        cdp = CDP(websocket, deadline)
        process_info = cdp.call("SystemInfo.getProcessInfo")
        command_line = cdp.call("Browser.getBrowserCommandLine")
        verify_browser_process(process_info, command_line, identity, profile)
        listener = revalidate()
        target_id = cdp.call("Target.createTarget", {"url": "about:blank"}).get("targetId")
        if not isinstance(target_id, str) or not target_id:
            _fail(2, "chrome-page-target-missing")
        session_id = cdp.call("Target.attachToTarget", {"targetId": target_id, "flatten": True}).get("sessionId")
        if not isinstance(session_id, str) or not session_id:
            _fail(2, "chrome-page-session-missing")
        binding = Binding(identity, profile, endpoint, target_id, session_id)
        _target(cdp, binding)
        api.write_json(run.out / "browser-binding.json", {
            "process": identity, "profile": str(profile), "profile_inode": original.st_ino,
            "port": endpoint.port, "browser_path": endpoint.browser_path,
            "version": version, "process_info": process_info, "command_line": command_line,
            "listener": listener, "target_id": target_id, "session_id": session_id,
        })
        cdp.call("Page.enable", session=session_id)
        cdp.call("Accessibility.enable", session=session_id)
        if public:
            url = "https://www.google.com/search?" + urllib.parse.urlencode({"q": query})
            return _navigate_and_save(run, binding, cdp, url, query, True, deadline, revalidate, api)
        with FixtureServer(payload, query) as server:
            return _navigate_and_save(run, binding, cdp, server.url, query, False, deadline, revalidate, api)
    finally:
        websocket.close()


def _navigate_and_save(run, binding, cdp, url, query, public, deadline, revalidate, api):
    navigation = cdp.call("Page.navigate", {"url": url}, binding.session_id)
    if "errorText" in navigation or navigation.get("isDownload"):
        _fail(3 if public else 1, "chrome-navigation-not-committed")
    frame, tree = _observe(cdp, binding, url, query, public, deadline, revalidate)
    capture_started_ns = time.monotonic_ns()
    screenshot = cdp.call("Page.captureScreenshot", {"format": "png", "fromSurface": True,
                                                   "captureBeyondViewport": False}, binding.session_id)
    capture_finished_ns = time.monotonic_ns()
    revalidate()
    if _frame(cdp, binding) != frame:
        _fail(1, "chrome-screenshot-frame-drift")
    try:
        image = base64.b64decode(screenshot.get("data", ""), validate=True)
    except (ValueError, TypeError) as error:
        raise BrowserFailure(2, "chrome-screenshot-invalid") from error
    if (not image.startswith(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR")
            or len(image) < 45 or len(image) > MAX_FRAME or image[-12:] != b"\x00\x00\x00\x00IEND\xaeB`\x82"):
        _fail(2, "chrome-screenshot-invalid")
    fd = os.open(run.out / "browser-page.png", os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(image)
    api.write_json(run.out / "browser-content.json", {"committed_url": frame["url"], "accessibility": tree})
    proof = {"state": "VERIFIED", "scope": "public-search-smoke" if public else "local-browser-fixture",
             "pid": binding.process["pid"], "start_us": binding.process["start_us"],
             "profile": str(binding.profile), "port": binding.endpoint.port,
             "browser_path": binding.endpoint.browser_path, "target_id": binding.target_id,
             "frame_id": frame["id"], "loader_id": frame["loaderId"],
             "committed_url_matched": True, "accessible_result_matched": True,
             "binding": "browser-binding.json", "screenshot": "browser-page.png", "content": "browser-content.json",
             "capture_interval_ns": [capture_started_ns, capture_finished_ns], "clock": "host-monotonic-ns",
             "input_consumed": False, "production_action_exercised": False}
    schema = api.strict_json((api.FIXTURES / "schemas/browser-observation-v1.json").read_bytes())
    api.validate_schema(proof, schema)
    api.write_json(run.out / "browser-observation.json", proof)
    run.assertions.append({"id": "chrome-bound-result", "passed": True, "observation": "browser-observation.json",
                           "scope": proof["scope"]})
    return proof
