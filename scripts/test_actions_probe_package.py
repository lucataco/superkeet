"""Packaging policy tests. OSBoundaryDouble is synthetic, never signing evidence."""

from dataclasses import replace
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import actions_probe_package as package


class OSBoundaryDouble:
    """Explicit test double for lipo, engine queries, and codesign only."""

    def __init__(self, protocol=2, capability_reply=None):
        self.protocol = protocol
        self.capability_reply = capability_reply if capability_reply is not None else {
            "protocol_version": 3, "request_schema_version": 1, "event_schema_version": 1,
            "capabilities": ["continuous-turns-v1"]}
        self.calls = []
        self.identifiers = {}
        self.fail_sign = False
        self.fail_verify = False
        self.audio_entitlement = True
        self.host_architecture = platform.machine()
        self.embedded_protocol = None

    def __call__(self, argv):
        argv = list(map(str, argv))
        self.calls.append(argv)
        stdout, stderr, code = b"", b"", 0
        target = Path(argv[-1])
        if argv[0] == package.LIPO:
            stdout = self.host_architecture.encode()
        elif argv[1:] == ["protocol-version"]:
            version = self.protocol
            if "incomplete" in Path(argv[0]).parts and self.embedded_protocol is not None:
                version = self.embedded_protocol
            stdout = str(version).encode()
        elif argv[1:] == ["capabilities", "--format", "json"]:
            stdout = (self.capability_reply if isinstance(self.capability_reply, bytes)
                      else json.dumps(self.capability_reply).encode())
        elif argv[0] != package.CODESIGN:
            raise AssertionError("Unexpected OS command in explicit test double")
        elif "--force" in argv:
            if self.fail_sign:
                code = 1
            else:
                self.identifiers[str(target)] = argv[argv.index("--identifier") + 1]
                executable = target / "Contents/MacOS/Superkeet" if target.is_dir() else target
                with executable.open("ab") as destination:
                    destination.write(b"|TEST-DOUBLE-SIGNATURE")
                if target.is_dir():
                    seals = target / "Contents/_CodeSignature"
                    seals.mkdir()
                    (seals / "CodeResources").write_bytes(b"TEST-DOUBLE-SEAL")
        elif "--verify" in argv:
            code = 1 if self.fail_verify else 0
        elif "--verbose=4" in argv:
            identifier = self.identifiers[str(target)]
            stderr = ("Identifier=" + identifier + "\nTeamIdentifier=TEST-DOUBLE\n"
                      "CDHash=TEST-DOUBLE-CDHASH\nAuthority=TEST-DOUBLE-CERTIFICATE\n").encode()
        elif "--requirements" in argv:
            stdout = b"designated => TEST-DOUBLE-REQUIREMENT\n"
        elif "--entitlements" in argv:
            stdout = plistlib.dumps({package.AUDIO_ENTITLEMENT: self.audio_entitlement})
        elif "--extract-certificates" in argv:
            prefix = argv[argv.index("--extract-certificates") + 1]
            Path(prefix + "0").write_bytes(b"TEST-DOUBLE-DER-CERTIFICATE")
        else:
            raise AssertionError("Unrecognized code-sign command in test double")
        return subprocess.CompletedProcess(argv, code, stdout, stderr)


class PackagePolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="actions-package-policy-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.app = self.root / "explicit-app"
        self.engine = self.root / "explicit-engine"
        for executable in (self.app, self.engine):
            executable.write_bytes(b"EXPLICIT NON-NATIVE TEST DOUBLE")
            executable.chmod(0o700)
        self.request = package.PackageRequest(
            self.app, self.engine, self.root / "new-output", "com.superkeet.actionsprobe.unit-test",
            "-", "legacy-session", "a" * 40, "b" * 40)
        self.boundary = OSBoundaryDouble()
        self.run_patch = patch.object(package, "_run", self.boundary)
        self.run_patch.start()
        self.addCleanup(self.run_patch.stop)
        self.system_patch = patch.object(package.platform, "system", return_value="Darwin")
        self.system_patch.start()
        self.addCleanup(self.system_patch.stop)

    def assemble(self, **changes):
        return package.assemble(replace(self.request, **changes))

    def refused(self, expected_code=2, **changes):
        with self.assertRaises(package.PackageError) as raised:
            self.assemble(**changes)
        self.assertEqual(raised.exception.exit_code, expected_code)
        self.assertFalse(self.request.out.exists())
        return str(raised.exception)

    def test_existing_output_is_untouched_before_external_commands(self):
        self.request.out.mkdir()
        sentinel = self.request.out / "sentinel"
        sentinel.write_bytes(b"keep")
        with self.assertRaises(package.PackageError):
            self.assemble()
        self.assertEqual(sentinel.read_bytes(), b"keep")
        self.assertEqual(self.boundary.calls, [])

    def test_production_and_application_outputs_refuse_before_external_commands(self):
        for output in (package.REPO_DIR / "new-probe-output",
                       package._production_roots()[-1] / "new-probe-output",
                       Path("/Applications/new-probe-output"),
                       Path("/Library/new-probe-output"), self.root / "Superkeet.app",
                       self.root / "TestSuperkeet.app", self.root / "Library/probe"):
            with self.subTest(output=output):
                with self.assertRaises(package.PackageError):
                    self.assemble(out=output)
                self.assertFalse(output.exists())
        self.assertEqual(self.boundary.calls, [])

    def test_output_inside_another_repository_refuses(self):
        engine_repository = self.root / "engine-repository"
        engine_repository.mkdir()
        (engine_repository / ".git").mkdir()
        self.refused(out=engine_repository / "probe-output")
        self.assertEqual(self.boundary.calls, [])

    def test_relative_and_traversal_paths_are_invalid(self):
        for value in ("relative/file", "/absolute/../file", "/absolute/./file"):
            with self.subTest(value=value), self.assertRaises(package.PackageError):
                package._absolute_path(value)

    def test_symlink_source_file_and_parent_refuse(self):
        link = self.root / "linked-app"
        link.symlink_to(self.app)
        self.refused(app=link)
        directory_link = self.root / "linked-directory"
        directory_link.symlink_to(self.root, target_is_directory=True)
        self.refused(app=directory_link / self.app.name)
        self.refused(out=directory_link / "output")
        self.assertEqual(self.boundary.calls, [])

    def test_broken_symlink_output_is_not_overwritten(self):
        self.request.out.symlink_to(self.root / "missing")
        with self.assertRaises(package.PackageError):
            self.assemble()
        self.assertTrue(self.request.out.is_symlink())
        self.assertEqual(self.boundary.calls, [])

    def test_shared_writable_output_parent_refuses(self):
        self.root.chmod(0o777)
        self.refused()
        self.assertEqual(self.boundary.calls, [])

    def test_non_executable_and_non_regular_sources_refuse(self):
        self.app.chmod(0o600)
        self.refused()
        self.app.chmod(0o700)
        self.refused(app=self.root)
        self.assertEqual(self.boundary.calls, [])

    def test_mismatched_architecture_refuses_before_engine_query(self):
        self.boundary.host_architecture = "not-the-host"
        self.refused(expected_code=3)
        self.assertEqual(len(self.boundary.calls), 1)
        self.assertEqual(self.boundary.calls[0][0], package.LIPO)

    def test_continuous_request_never_queries_capabilities_on_legacy_engine(self):
        self.refused(expected_code=3, capability="continuous-turns-v1")
        self.assertFalse(any("capabilities" in call for call in self.boundary.calls))

    def test_unknown_protocol_refuses(self):
        self.boundary.protocol = 99
        self.refused(expected_code=3)

    def test_failed_engine_query_cannot_be_treated_as_support(self):
        def failed_query(argv):
            result = self.boundary(argv)
            if argv[1:] == ["protocol-version"]:
                return subprocess.CompletedProcess(argv, 42, b"2", b"TEST-DOUBLE-FAILURE")
            return result
        with patch.object(package, "_run", side_effect=failed_query):
            self.refused(expected_code=3)

    def test_input_changed_during_inspection_refuses_before_output(self):
        def changed_input(argv):
            result = self.boundary(argv)
            if argv[1:] == ["protocol-version"]:
                self.app.write_bytes(b"CHANGED TEST DOUBLE")
            return result
        with patch.object(package, "_run", side_effect=changed_input):
            self.refused(expected_code=1)

    def test_symlink_parent_substituted_during_inspection_refuses(self):
        source_dir = self.root / "source-directory"
        source_dir.mkdir()
        app = source_dir / "app"
        app.write_bytes(self.app.read_bytes())
        app.chmod(0o700)
        def changed_parent(argv):
            result = self.boundary(argv)
            if argv[1:] == ["protocol-version"]:
                source_dir.rename(self.root / "original-source-directory")
                source_dir.symlink_to(self.root / "original-source-directory", target_is_directory=True)
            return result
        with patch.object(package, "_run", side_effect=changed_parent):
            self.refused(app=app)

    def test_protocol_three_is_not_implicit_legacy_support(self):
        self.boundary.protocol = 3
        self.refused(expected_code=3)

    def test_continuous_requires_actual_named_capability_and_schema_one(self):
        self.boundary.protocol = 3
        invalid_replies = [
            {"protocol_version": 3, "capabilities": ["continuous-turns-v1"]},
            {"protocol_version": 3, "request_schema_version": 1, "event_schema_version": 2,
             "capabilities": ["continuous-turns-v1"]},
            {"protocol_version": 3, "request_schema_version": True, "event_schema_version": 1,
             "capabilities": ["continuous-turns-v1"]},
            {"protocol_version": 3, "request_schema_version": 1, "event_schema_version": 1,
             "capabilities": ["future-capability"]},
            {"protocol_version": 3, "request_schema_version": 1, "event_schema_version": 1,
             "capabilities": "continuous-turns-v1"},
            {"protocol_version": 3, "request_schema_version": 1, "event_schema_version": 1,
             "capabilities": ["continuous-turns-v1"], "unexpected": float("nan")},
            [], b'{"protocol_version":3,"protocol_version":3}', b"not-json",
        ]
        for reply in invalid_replies:
            with self.subTest(reply=reply):
                self.boundary.capability_reply = reply
                self.refused(expected_code=3, capability="continuous-turns-v1")

    def test_legacy_protocol_one_and_two_are_observed_not_assumed(self):
        for protocol in (1, 2):
            with self.subTest(protocol=protocol):
                self.boundary.protocol = protocol
                manifest = self.assemble(out=self.root / ("protocol-" + str(protocol)))
                self.assertEqual(manifest["post_sign"]["engine_contract"]["protocol_version"], protocol)
                self.assertIsNone(manifest["post_sign"]["engine_contract"]["capability_reply"])

    def test_continuous_package_is_not_continuous_execution_proof(self):
        self.boundary.protocol = 3
        manifest = self.assemble(capability="continuous-turns-v1")
        self.assertEqual(manifest["post_sign"]["engine_contract"]["capability_reply"],
                         self.boundary.capability_reply)
        self.assertFalse(manifest["continuous_execution_verified"])
        self.assertEqual(sum(call[1:] == ["capabilities", "--format", "json"]
                             for call in self.boundary.calls), 2)

    def test_signing_order_strict_verification_and_post_sign_hashes(self):
        source_app = self.app.read_bytes()
        source_engine = self.engine.read_bytes()
        manifest = self.assemble()
        bundle = self.request.out / package.BUNDLE_NAME
        engine = bundle / "Contents/Resources/bin/parakeet"
        app = bundle / "Contents/MacOS/Superkeet"
        self.assertEqual(self.request.out.stat().st_mode & 0o777, 0o700)
        signed = [Path(call[-1]) for call in self.boundary.calls if "--force" in call]
        self.assertEqual([path.name for path in signed], ["parakeet", "Superkeet", package.BUNDLE_NAME])
        for call in self.boundary.calls:
            if "--force" in call:
                self.assertIn("--timestamp=none", call)
                self.assertIn("--entitlements", call)
                self.assertNotIn("--deep", call)
        verified = [call for call in self.boundary.calls if "--verify" in call]
        self.assertEqual(len(verified), 5)
        self.assertTrue(all("--strict" in call for call in verified))
        self.assertEqual(sum("--deep" in call for call in verified), 2)
        self.assertEqual(manifest["pre_sign"]["sources"]["app"]["sha256"],
                         hashlib.sha256(source_app).hexdigest())
        self.assertEqual(manifest["pre_sign"]["sources"]["engine"]["sha256"],
                         hashlib.sha256(source_engine).hexdigest())
        self.assertEqual(manifest["post_sign"]["app_sha256"], hashlib.sha256(app.read_bytes()).hexdigest())
        self.assertEqual(manifest["post_sign"]["engine_sha256"], hashlib.sha256(engine.read_bytes()).hexdigest())
        self.assertNotEqual(manifest["post_sign"]["app_sha256"], manifest["pre_sign"]["sources"]["app"]["sha256"])
        self.assertEqual(self.app.read_bytes(), source_app)
        self.assertEqual(self.engine.read_bytes(), source_engine)
        self.assertEqual(manifest["signing_scope"], "compile-only-ad-hoc")
        self.assertFalse(manifest["desktop_launch_verified"])
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], self.request.bundle_id)
        self.assertEqual(info["CFBundleExecutable"], "Superkeet")
        self.assertEqual(info["CFBundleDisplayName"], "TestSuperkeet")
        receipt = self.request.out / "bundle-manifest.json"
        self.assertEqual(json.loads(receipt.read_bytes()), manifest)
        self.assertFalse((bundle / "Contents/Resources/bundle-manifest.json").exists())
        for relative, digest in manifest["post_sign"]["files"].items():
            self.assertEqual(hashlib.sha256((bundle / relative).read_bytes()).hexdigest(), digest)
        self.assertEqual(set(manifest["pre_sign"]["sources"]["resources"]),
                         {"Info.plist", "AppIcon.icns", "Superkeet.entitlements"})

    def test_explicit_certificate_identity_records_certificate_fingerprint(self):
        manifest = self.assemble(signing_identity="EXPLICIT TEST DOUBLE CERTIFICATE")
        for signature in manifest["signatures"].values():
            self.assertEqual(signature["requested_identity"], "EXPLICIT TEST DOUBLE CERTIFICATE")
            self.assertEqual(signature["certificates"][0]["sha256"],
                             hashlib.sha256(b"TEST-DOUBLE-DER-CERTIFICATE").hexdigest())
            self.assertEqual(signature["fields"]["TeamIdentifier"], ["TEST-DOUBLE"])

    def test_failed_signing_retains_incomplete_artifact_without_receipt(self):
        self.boundary.fail_sign = True
        with self.assertRaises(package.PackageError) as raised:
            self.assemble()
        self.assertEqual(raised.exception.exit_code, 1)
        self.assertTrue((self.request.out / "incomplete" / package.BUNDLE_NAME).is_dir())
        self.assertFalse((self.request.out / package.BUNDLE_NAME).exists())
        self.assertFalse((self.request.out / "bundle-manifest.json").exists())
        self.assertEqual(json.loads((self.request.out / "assembly-started.json").read_bytes())["status"],
                         "ASSEMBLY_STARTED")

    def test_verification_failure_cannot_emit_complete_receipt(self):
        self.boundary.fail_verify = True
        with self.assertRaises(package.PackageError):
            self.assemble()
        self.assertFalse((self.request.out / "bundle-manifest.json").exists())

    def test_missing_effective_microphone_entitlement_fails(self):
        self.boundary.audio_entitlement = False
        with self.assertRaises(package.PackageError):
            self.assemble()
        self.assertFalse((self.request.out / "bundle-manifest.json").exists())

    def test_final_embedded_engine_contract_is_rechecked(self):
        self.boundary.embedded_protocol = 1
        with self.assertRaises(package.PackageError):
            self.assemble()
        self.assertFalse((self.request.out / "bundle-manifest.json").exists())


class PackageCLITests(unittest.TestCase):
    """Real subprocess CLI refusals. No test doubles, signing, or desktop launch."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="actions-package-cli-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.wrapper = Path(__file__).resolve().parent / "package_actions_prototype.sh"
        self.argv = ["/bin/bash", str(self.wrapper), "--app", "/usr/bin/true",
                     "--engine", "/usr/bin/true", "--out", str(self.root / "output"),
                     "--bundle-id", "com.superkeet.actionsprobe.cli-refusal",
                     "--signing-identity", "-", "--capability", "continuous-turns-v1",
                     "--app-source-sha", "a" * 40, "--engine-source-sha", "b" * 40]

    def invoke(self, flag=None, value=None):
        argv = self.argv[:]
        if flag is not None:
            argv[argv.index(flag) + 1] = value
        return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, timeout=20, check=False)

    def test_missing_arguments_refuses(self):
        result = subprocess.run([sys.executable, str(self.wrapper.with_name("actions_probe_package.py"))],
                                capture_output=True, timeout=20, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / "output").exists())

    def test_invalid_identity_source_shas_and_paths_refuse(self):
        for flag, value in (("--bundle-id", "com.superkeet.app"),
                            ("--bundle-id", "com.superkeet.actionsprobe.unsafe.suffix"),
                            ("--app-source-sha", "not-a-sha"),
                            ("--engine-source-sha", "a" * 64),
                            ("--signing-identity", ""), ("--app", "relative/app")):
            with self.subTest(flag=flag, value=value):
                result = self.invoke(flag, value)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(json.loads(result.stderr)["status"], "REFUSED")
                self.assertFalse((self.root / "output").exists())

    def test_production_output_refuses(self):
        result = self.invoke("--out", str(package.REPO_DIR / "no-production-output"))
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertFalse((package.REPO_DIR / "no-production-output").exists())

    @unittest.skipUnless(platform.system() == "Darwin", "Real macOS lipo boundary")
    def test_system_true_is_not_a_continuous_engine(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertEqual(json.loads(result.stderr)["status"], "REFUSED")
        self.assertFalse((self.root / "output").exists())


if __name__ == "__main__":
    unittest.main()
