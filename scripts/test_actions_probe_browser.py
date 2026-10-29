"""Offline policy and protocol tests. These do not establish live Chrome evidence."""

import base64
import contextlib
import hashlib
import http.client
import io
import os
from pathlib import Path
import struct
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

import actions_probe as probe
import actions_probe_browser as browser


def ax(name, role="StaticText", **extra):
    return {"ignored": False, "name": {"value": name}, "role": {"value": role}, **extra}


def server_frame(payload, opcode=1, final=True):
    first = (0x80 if final else 0) | opcode
    length = len(payload)
    if length < 126:
        return bytes((first, length)) + payload
    if length <= 65535:
        return bytes((first, 126)) + struct.pack("!H", length) + payload
    return bytes((first, 127)) + struct.pack("!Q", length) + payload


class ScriptedSocket:
    """A byte-stream test double. It never creates a network or browser connection."""

    def __init__(self, frames=b"", accept=True):
        self.pending = bytearray()
        self.frames, self.accept, self.sent, self.closed = frames, accept, [], False

    def settimeout(self, _):
        pass

    def sendall(self, payload):
        self.sent.append(payload)
        if payload.startswith(b"GET "):
            key = payload.split(b"Sec-WebSocket-Key: ", 1)[1].split(b"\r\n", 1)[0]
            accept = base64.b64encode(hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
            if not self.accept:
                accept = b"wrong"
            self.pending.extend(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                                b"Connection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n" + self.frames)

    def recv(self, size):
        chunk = bytes(self.pending[:size])
        del self.pending[:size]
        return chunk

    def close(self):
        self.closed = True


class URLAndResultTests(unittest.TestCase):
    def test_local_url_is_exact_including_query_and_origin(self):
        expected = "http://127.0.0.1:4321/search?q=Norbert+Wiener"
        self.assertTrue(browser.committed_url_matches(expected, expected, "Norbert Wiener"))
        for wrong in [expected + "#other", expected + "&q=Norbert+Wiener", expected.replace("4321", "4322"),
                      expected.replace("/search", "/other"), expected.replace("127.0.0.1", "localhost")]:
            with self.subTest(url=wrong):
                self.assertFalse(browser.committed_url_matches(wrong, expected, "Norbert Wiener"))

    def test_public_url_rejects_challenge_redirect_host_spoof_and_query_confusion(self):
        good = "https://www.google.com/search?q=Norbert+Wiener&source=hp"
        self.assertTrue(browser.committed_url_matches(good, "", "Norbert Wiener", public=True))
        bad = ["http://www.google.com/search?q=Norbert+Wiener",
               "https://www.google.com.evil.test/search?q=Norbert+Wiener",
               "https://www.google.com@evil.test/search?q=Norbert+Wiener",
               "https://www.google.com:443/search?q=Norbert+Wiener",
               "https://www.google.com/sorry?q=Norbert+Wiener",
               "https://consent.google.com/search?q=Norbert+Wiener",
               "https://www.google.com/search?q=other",
               "https://www.google.com/search?q=Norbert+Wiener&q=Norbert+Wiener",
               good + "#results", good + "\n", good.replace("google.com", "google.com\\")]
        for url in bad:
            with self.subTest(url=url):
                self.assertFalse(browser.committed_url_matches(url, "", "Norbert Wiener", public=True))

    def test_fixture_requires_both_visible_exact_marker_and_literal_query(self):
        good = [ax("Actions probe result", "heading"), ax("Norbert Wiener")]
        self.assertTrue(browser.result_matches(good, "Norbert Wiener"))
        cases = [[ax("Not Actions probe result"), ax("Norbert Wiener")],
                 [ax("Actions probe result"), ax("Wrong query")],
                 [ax("Actions probe result", ignored=True), ax("Norbert Wiener")],
                 [ax("Actions probe result"), ax("norbert wiener")], [], [None],
                 [ax("Actions probe result"), {"ignored": False, "name": "bad"}]]
        for nodes in cases:
            with self.subTest(nodes=nodes):
                self.assertFalse(browser.result_matches(nodes, "Norbert Wiener"))

    def public_nodes(self):
        return [ax("Search Results", "heading"), ax("Search", "searchbox", value={"value": "Norbert Wiener"}),
                ax("Norbert Wiener biography", "link", properties=[
                    {"name": "url", "value": {"value": "https://example.org/biography"}}])]

    def test_public_smoke_requires_result_heading_query_and_external_result_link(self):
        self.assertTrue(browser.result_matches(self.public_nodes(), "Norbert Wiener", public=True))
        cases = [self.public_nodes()[1:], self.public_nodes()[:2], [ax("Actions probe result"), ax("Norbert Wiener")],
                 self.public_nodes() + [ax("Our systems have detected unusual traffic")],
                 self.public_nodes() + [ax("Before you continue to Google")],
                 [ax("Search Results", "heading"), ax("other", "link")]]
        for nodes in cases:
            with self.subTest(nodes=nodes):
                self.assertFalse(browser.result_matches(nodes, "Norbert Wiener", public=True))


class BindingTests(unittest.TestCase):
    def test_endpoint_cannot_name_an_arbitrary_websocket_or_host(self):
        endpoint = browser.Endpoint(4321, "/devtools/browser/abc-123")
        endpoint.verify_version({"webSocketDebuggerUrl": "ws://127.0.0.1:4321/devtools/browser/abc-123"})
        for url in ["ws://localhost:4321/devtools/browser/abc-123", "ws://127.0.0.1:4322/devtools/browser/abc-123",
                    "ws://127.0.0.1:4321/devtools/browser/other", "ws://evil.test/devtools/browser/abc-123"]:
            with self.subTest(url=url), self.assertRaises(browser.BrowserFailure):
                endpoint.verify_version({"webSocketDebuggerUrl": url})
        for port, path in [(True, "/devtools/browser/id"), (0, "/devtools/browser/id"),
                           (70000, "/devtools/browser/id"), (4321, "/devtools/page/id"),
                           (4321, "/devtools/browser/id?query=bad"), (4321, None)]:
            with self.subTest(port=port, path=path), self.assertRaises(browser.BrowserFailure):
                browser.Endpoint(port, path)

    def test_socket_listener_requires_exact_pid_port_and_loopback_address(self):
        browser.verify_listener_output(b"p123\ncGoogle Chrome\nf7\nn127.0.0.1:4321\n", 123, 4321)
        for output in [b"p124\nn127.0.0.1:4321\n", b"p123\nn*:4321\n", b"p123\nn127.0.0.1:4322\n",
                       b"p123\nn[::1]:4321\n", b"p123\n", b"p123\nn127.0.0.1:4321\np124\nn127.0.0.1:4321\n"]:
            with self.subTest(output=output), self.assertRaises(browser.BrowserFailure):
                browser.verify_listener_output(output, 123, 4321)

    def test_socket_owner_inspection_failure_is_blocked(self):
        with mock.patch.object(browser.subprocess, "run", side_effect=FileNotFoundError), self.assertRaises(browser.BrowserFailure) as caught:
            browser.verify_listener(123, browser.Endpoint(4321, "/devtools/browser/id"), time.monotonic() + 2)
        self.assertEqual(caught.exception.code, 3)

    def test_version_request_is_fixed_loopback_and_does_not_follow_redirects(self):
        endpoint = browser.Endpoint(4321, "/devtools/browser/id")
        connection = mock.Mock()
        connection.getresponse.return_value.status = 302
        connection.getresponse.return_value.read.return_value = b'{}'
        with mock.patch.object(browser.http.client, "HTTPConnection", return_value=connection) as factory, \
                self.assertRaises(browser.BrowserFailure):
            browser.get_version(endpoint, time.monotonic() + 2)
        self.assertEqual(factory.call_args.args, ("127.0.0.1", 4321))
        connection.request.assert_called_once_with("GET", "/json/version")
        connection.close.assert_called_once()

    def test_browser_process_and_command_line_must_both_agree(self):
        identity = {"pid": 123, "executable": "/Applications/Test Chrome"}
        profile = Path("/safe/run/profile")
        arguments = [identity["executable"], "--user-data-dir=/safe/run/profile", "--remote-debugging-address=127.0.0.1",
                     "--remote-debugging-port=0", "--enable-automation"]
        info = {"processInfo": [{"id": 123, "type": "browser"}, {"id": 124, "type": "renderer"}]}
        browser.verify_browser_process(info, {"arguments": arguments}, identity, profile)
        for changed in [arguments + ["--user-data-dir=/personal/profile"],
                        [arg.replace("/safe/run/profile", "/personal/profile") for arg in arguments],
                        [arg.replace("127.0.0.1", "0.0.0.0") for arg in arguments], arguments[1:]]:
            with self.subTest(arguments=changed), self.assertRaises(browser.BrowserFailure):
                browser.verify_browser_process(info, {"arguments": changed}, identity, profile)
        with self.assertRaises(browser.BrowserFailure):
            browser.verify_browser_process({"processInfo": [{"id": 999, "type": "browser"}]}, {"arguments": arguments}, identity, profile)

    def test_port_file_must_be_new_owned_regular_and_well_formed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            port_file = root / "DevToolsActivePort"
            launched_ns = time.time_ns() - 1000000000
            port_file.write_text("4321\n/devtools/browser/id\n")
            self.assertEqual(browser.read_active_port(root, launched_ns).port, 4321)
            for contents in ["4321\n/devtools/page/id\n", "0\n/devtools/browser/id\n", "4321\n/devtools/browser/id\nextra\n"]:
                port_file.write_text(contents)
                with self.subTest(contents=contents), self.assertRaises(browser.BrowserFailure):
                    browser.read_active_port(root, launched_ns)
            port_file.write_text("4321\n/devtools/browser/id\n")
            with self.assertRaises(browser.BrowserFailure):
                browser.read_active_port(root, time.time_ns() + 1000000000)
            port_file.unlink()
            port_file.symlink_to(root / "elsewhere")
            with self.assertRaises(OSError):
                browser.read_active_port(root, launched_ns)

    def test_profiles_are_never_reused_or_deleted_and_stay_beneath_runroot(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            profile = root / "profile"
            original = browser._new_profile(profile, root)
            browser._same_profile(profile, original)
            (profile / "retained-data").write_text("keep")
            with self.assertRaises(browser.BrowserFailure):
                browser._new_profile(profile, root)
            self.assertEqual((profile / "retained-data").read_text(), "keep")
            for outside in [root, root.parent / "outside", root / ".." / "outside"]:
                with self.subTest(outside=outside), self.assertRaises(browser.BrowserFailure):
                    browser._new_profile(outside, root)


class WebSocketTests(unittest.TestCase):
    def connect(self, frames=b"", accept=True):
        stream = ScriptedSocket(frames, accept)
        with mock.patch.object(browser.socket, "create_connection", return_value=stream):
            websocket = browser.WebSocket(browser.Endpoint(4321, "/devtools/browser/id"), time.monotonic() + 2)
        self.addCleanup(websocket.close)
        return websocket, stream

    def test_handshake_validates_accept_digest(self):
        websocket, _ = self.connect(server_frame(b"hello"))
        self.assertEqual(websocket.receive(time.monotonic() + 2), "hello")
        stream = ScriptedSocket(accept=False)
        with mock.patch.object(browser.socket, "create_connection", return_value=stream), self.assertRaises(browser.BrowserFailure):
            browser.WebSocket(browser.Endpoint(4321, "/devtools/browser/id"), time.monotonic() + 2)
        self.assertTrue(stream.closed)

    def test_fragmented_utf8_and_ping_are_supported(self):
        frames = server_frame(b"\xe2", final=False) + server_frame(b"ping", opcode=9) + server_frame(b"\x82\xac", opcode=0)
        websocket, stream = self.connect(frames)
        self.assertEqual(websocket.receive(time.monotonic() + 2), "\u20ac")
        pong = stream.sent[-1]
        self.assertEqual(pong[:2], b"\x8a\x84")
        self.assertEqual(bytes(value ^ pong[2 + index % 4] for index, value in enumerate(pong[6:])), b"ping")

    def test_client_frames_are_masked(self):
        websocket, stream = self.connect()
        websocket.send(b"hello", time.monotonic() + 2)
        sent = stream.sent[-1]
        self.assertEqual(sent[:2], b"\x81\x85")
        self.assertEqual(bytes(value ^ sent[2 + index % 4] for index, value in enumerate(sent[6:])), b"hello")

    def test_rejects_bad_frames_and_limits_before_reading_oversized_payload(self):
        cases = [b"\x81\x80", b"\xc1\x00", server_frame(b"x", opcode=2), server_frame(b"x", opcode=0),
                 b"\x09\x00", b"\x89\x7e", b"\x81\x7e\x00\x01x", server_frame(b"\xff"),
                 b"\x81\x7f" + struct.pack("!Q", browser.MAX_FRAME + 1)]
        for frame in cases:
            with self.subTest(frame=frame):
                websocket, _ = self.connect(frame)
                with self.assertRaises(browser.BrowserFailure):
                    websocket.receive(time.monotonic() + 2)

    def test_aggregate_message_limit_applies_to_fragments(self):
        websocket, _ = self.connect(server_frame(b"12345678", final=False) + server_frame(b"abcdefgh", opcode=0))
        with mock.patch.object(browser, "MAX_MESSAGE", 12), self.assertRaises(browser.BrowserFailure):
            websocket.receive(time.monotonic() + 2)

    def test_cdp_ignores_events_but_rejects_other_page_response(self):
        event = server_frame(b'{"method":"Page.loadEventFired","params":{}}')
        reply = server_frame(b'{"id":1,"sessionId":"owned-page","result":{"frameTree":{}}}')
        websocket, _ = self.connect(event + reply)
        cdp = browser.CDP(websocket, time.monotonic() + 2)
        self.assertEqual(cdp.call("Page.getFrameTree", session="owned-page"), {"frameTree": {}})
        websocket, _ = self.connect(server_frame(b'{"id":1,"sessionId":"other-page","result":{}}'))
        with self.assertRaises(browser.BrowserFailure):
            browser.CDP(websocket, time.monotonic() + 2).call("Page.getFrameTree", session="owned-page")

    def test_cdp_cannot_evaluate_supplied_javascript(self):
        websocket, stream = self.connect()
        before = len(stream.sent)
        with self.assertRaises(browser.BrowserFailure):
            browser.CDP(websocket, time.monotonic() + 2).call("Runtime.evaluate", {"expression": "anything"})
        self.assertEqual(len(stream.sent), before)


class ObservationRefusalTests(unittest.TestCase):
    def test_fixture_write_and_privacy_permissions_refuse_before_spawn_or_profile_creation(self):
        for fixture_writes, retain_content, code in [(False, True, 2), (1, True, 2), (True, False, 3)]:
            with self.subTest(fixture_writes=fixture_writes, retain_content=retain_content), tempfile.TemporaryDirectory() as directory:
                profile = Path(directory) / "profile"
                data = {"fixture_writes": fixture_writes, "privacy": {"retain_content": retain_content},
                        "paths": {"chrome_profile": str(profile)}, "artifacts": {"chrome": {"path": "/no/browser"}}}
                run = SimpleNamespace(manifest=SimpleNamespace(data=data), assertions=[], spawn=mock.Mock())
                with self.assertRaises(probe.ProbeError) as caught:
                    browser.observe_chrome(run)
                self.assertEqual(caught.exception.code, code)
                run.spawn.assert_not_called()
                self.assertFalse(profile.exists())
                self.assertFalse(run.assertions[-1]["passed"])

    def test_public_transport_failure_is_blocked_without_fallback_to_local_fixture(self):
        for error in [browser.BrowserFailure(4, "chrome-transport-deadline"), ConnectionRefusedError(), TimeoutError()]:
            run = SimpleNamespace(assertions=[])
            with self.subTest(error=error), mock.patch.object(browser, "_observe_chrome", side_effect=error) as operation, \
                    self.assertRaises(probe.ProbeError) as caught:
                browser.observe_chrome(run, public=True)
            self.assertEqual(caught.exception.code, 3)
            self.assertFalse(run.assertions[-1]["passed"])
            operation.assert_called_once_with(run, True, probe)

    def test_direct_cli_preserves_probe_error_module_identity(self):
        main = SimpleNamespace(__file__=os.path.relpath(probe.__file__), ProbeError=probe.ProbeError)
        with mock.patch.dict(sys.modules, {"__main__": main}):
            self.assertIs(browser._probe_api(), main)

    def test_wrong_committed_page_fails_even_when_navigation_acknowledged(self):
        binding = browser.Binding({}, Path("/run/profile"), browser.Endpoint(4321, "/devtools/browser/id"), "owned", "session")
        cdp = mock.Mock()
        cdp.call.side_effect = [
            {"targetInfo": {"targetId": "owned", "type": "page"}},
            {"frameTree": {"frame": {"id": "frame", "loaderId": "loader", "url": "https://wrong.test/"}}},
        ]
        with self.assertRaises(browser.BrowserFailure) as caught:
            browser._observe(cdp, binding, "http://127.0.0.1:4321/search?q=expected", "expected", False,
                             time.monotonic() + 1, lambda: None)
        self.assertEqual(caught.exception.code, 1)
        self.assertEqual(caught.exception.reason, "chrome-wrong-committed-url")

    def test_missing_result_is_failure_locally_and_blocked_for_public_smoke(self):
        binding = browser.Binding({}, Path("/run/profile"), browser.Endpoint(4321, "/devtools/browser/id"), "owned", "session")
        for public, url, code in [(False, "http://127.0.0.1:4321/search?q=expected", 1),
                                  (True, "https://www.google.com/search?q=expected", 3)]:
            with self.subTest(public=public):
                def reply(method, *_args, **_kwargs):
                    if method == "Target.getTargetInfo":
                        return {"targetInfo": {"targetId": "owned", "type": "page"}}
                    if method == "Page.getFrameTree":
                        return {"frameTree": {"frame": {"id": "frame", "loaderId": "loader", "url": url}}}
                    return {"nodes": [ax("Wrong result", "RootWebArea", nodeId="root", frameId="frame")]}
                cdp = mock.Mock()
                cdp.call.side_effect = reply
                with self.assertRaises(browser.BrowserFailure) as caught:
                    browser._observe(cdp, binding, url, "expected", public, time.monotonic() + 0.005, lambda: None)
                self.assertEqual(caught.exception.code, code)
                self.assertEqual(caught.exception.reason, "chrome-result-not-proven")

    def test_accessibility_markers_from_another_frame_or_disconnected_nodes_are_rejected(self):
        root = ax("Page", "RootWebArea", nodeId="root", frameId="frame")
        marker = ax("Actions probe result", nodeId="marker", parentId="root")
        query = ax("expected", nodeId="query", parentId="root")
        self.assertEqual(browser.main_frame_nodes({"nodes": [root, marker, query]}, "frame"), [root, marker, query])
        cases = [[{**root, "frameId": "other"}, marker, query],
                 [root, {**marker, "frameId": "iframe"}, query],
                 [root, {**marker, "parentId": "detached"}, query], [root, marker, marker],
                 [root, {**marker, "parentId": "query"}, {**query, "parentId": "marker"}]]
        for nodes in cases:
            with self.subTest(nodes=nodes), self.assertRaises(browser.BrowserFailure):
                browser.main_frame_nodes({"nodes": nodes}, "frame")

    def test_screenshot_frame_drift_never_writes_success_evidence(self):
        binding = browser.Binding({}, Path("/run/profile"), browser.Endpoint(4321, "/devtools/browser/id"), "owned", "session")
        frame = {"id": "frame", "loaderId": "loader", "url": "http://127.0.0.1:4321/search?q=expected"}
        cdp = mock.Mock()
        cdp.call.return_value = {}
        with tempfile.TemporaryDirectory() as directory:
            run = SimpleNamespace(out=Path(directory), assertions=[])
            with mock.patch.object(browser, "_observe", return_value=(frame, {})), \
                    mock.patch.object(browser, "_frame", return_value={**frame, "loaderId": "changed"}), \
                    self.assertRaises(browser.BrowserFailure) as caught:
                browser._navigate_and_save(run, binding, cdp, frame["url"], "expected", False,
                                           time.monotonic() + 2, lambda: None, probe)
            self.assertEqual(caught.exception.reason, "chrome-screenshot-frame-drift")
            self.assertEqual(list(run.out.iterdir()), [])

    def test_wrong_page_target_refuses_frame_read(self):
        binding = browser.Binding({}, Path("/run/profile"), browser.Endpoint(4321, "/devtools/browser/id"), "owned", "session")
        cdp = mock.Mock()
        cdp.call.return_value = {"targetInfo": {"targetId": "other", "type": "page"}}
        with self.assertRaises(browser.BrowserFailure):
            browser._frame(cdp, binding)
        self.assertEqual(cdp.call.call_count, 1)


class FixtureServerTests(unittest.TestCase):
    def test_server_is_closed_on_interruption_without_touching_profile_data(self):
        payload = browser.fixture_payload("<h1>Actions probe result</h1><p>QUERY</p>", "query")
        with self.assertRaises(KeyboardInterrupt):
            with browser.FixtureServer(payload, "query") as server:
                raise KeyboardInterrupt()
        self.assertFalse(server.thread.is_alive())
        self.assertEqual(server.server.fileno(), -1)

    def test_only_exact_search_route_is_served_and_query_is_html_escaped_without_logging(self):
        query = '<unsafe>&"content"'
        logs = io.StringIO()
        payload = browser.fixture_payload("<h1>Actions probe result</h1><p>QUERY</p>", query)
        with contextlib.redirect_stderr(logs), browser.FixtureServer(payload, query) as server:
            port = server.server.server_port
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            connection.request("GET", server.url.split(f":{port}", 1)[1])
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertIn(b"&lt;unsafe&gt;&amp;&quot;content&quot;", response.read())
            connection.close()
            for route in ["/", "/search?q=other", "/search?q=other&q=other", "/search?q=other&extra=value"]:
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
                connection.request("GET", route)
                response = connection.getresponse()
                self.assertEqual(response.status, 404)
                response.read()
                connection.close()
        self.assertFalse(server.thread.is_alive())
        self.assertEqual(logs.getvalue(), "")


if __name__ == "__main__":
    unittest.main()
