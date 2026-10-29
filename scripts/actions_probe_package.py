#!/usr/bin/env python3
"""Assemble an explicit, disposable test bundle. Never build or launch the app."""

import argparse
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import subprocess
import sys
from typing import Optional, Sequence


REPO_DIR = Path(__file__).resolve().parent.parent
CODESIGN = "/usr/bin/codesign"
LIPO = "/usr/bin/lipo"
AUDIO_ENTITLEMENT = "com.apple.security.device.audio-input"
BUNDLE_NAME = "TestSuperkeet.app"


class PackageError(Exception):
    def __init__(self, reason: str, exit_code: int = 2):
        super().__init__(reason)
        self.exit_code = exit_code


@dataclass(frozen=True)
class PackageRequest:
    app: Path
    engine: Path
    out: Path
    bundle_id: str
    signing_identity: str
    capability: str
    app_source_sha: str
    engine_source_sha: str


@dataclass(frozen=True)
class EngineContract:
    protocol_version: int
    capabilities: Optional[dict] = None

    def receipt(self) -> dict:
        return {"protocol_version": self.protocol_version,
                "capability_reply": self.capabilities}


def _sha256(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def _json_bytes(value: dict) -> bytes:
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")


def _absolute_path(value: str) -> Path:
    if (not value.startswith("/") or "\x00" in value
            or any(part in {".", ".."} for part in value.split("/"))):
        raise PackageError("Paths must be absolute and contain no traversal")
    return Path(value)


def _check_path(path: Path, *, missing_leaf: bool = False) -> None:
    for component in reversed((path, *path.parents)):
        try:
            info = component.lstat()
        except FileNotFoundError:
            if component == path and missing_leaf:
                return
            raise PackageError("A required path does not exist") from None
        if stat.S_ISLNK(info.st_mode):
            raise PackageError("Symlink path components are forbidden")
        if component != path and not stat.S_ISDIR(info.st_mode):
            raise PackageError("Path ancestors must be directories")
    if missing_leaf:
        raise PackageError("Output must not already exist")


def _production_roots() -> tuple:
    roots = [REPO_DIR]
    git_path = REPO_DIR / ".git"
    if git_path.is_file():
        text = git_path.read_text(encoding="utf-8").strip()
        if text.startswith("gitdir: "):
            git_dir = (REPO_DIR / text[8:]).resolve()
            common_file = git_dir / "commondir"
            if common_file.is_file():
                common_dir = (git_dir / common_file.read_text().strip()).resolve()
                roots.append(common_dir.parent)
    return tuple(roots)


def _validate_output(path: Path) -> None:
    _check_path(path, missing_leaf=True)
    lowered = tuple(part.casefold() for part in path.parts)
    if any(part in {"applications", "library"} or part.endswith(".app")
           for part in lowered):
        raise PackageError("Output must be outside application and Library directories")
    for root in _production_roots():
        root_parts = tuple(part.casefold() for part in root.parts)
        if lowered[:len(root_parts)] == root_parts:
            raise PackageError("Output inside a production repository is forbidden")
    if any((ancestor / ".git").exists() for ancestor in path.parents):
        raise PackageError("Output must be outside repository directories")
    parent = path.parent.stat()
    if parent.st_uid != os.geteuid() or parent.st_mode & 0o022:
        raise PackageError("Output parent must be owned by this user and not shared-writable")


def _read_file(path: Path, *, executable: bool = False) -> bytes:
    _check_path(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise PackageError("Inputs must be regular files")
    with os.fdopen(descriptor, "rb") as source:
        if executable and not os.access(path, os.X_OK):
            raise PackageError("Explicit app and engine inputs must be executable")
        return source.read()


def _run(argv: Sequence[str]) -> subprocess.CompletedProcess:
    try:
        result = subprocess.run(list(map(str, argv)), stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=20, check=False)
    except subprocess.TimeoutExpired:
        raise PackageError("External inspection or signing timed out", 4) from None
    except OSError:
        raise PackageError("Required executable could not be invoked", 3) from None
    if len(result.stdout) + len(result.stderr) > 131072:
        raise PackageError("External inspection exceeded its output limit", 4)
    return result


def _checked(argv: Sequence[str], reason: str, exit_code: int = 1) -> subprocess.CompletedProcess:
    result = _run(argv)
    if result.returncode != 0:
        raise PackageError(reason, exit_code)
    return result


def _architectures(path: Path, host: str) -> list:
    result = _checked([LIPO, "-archs", str(path)], "Cannot inspect input architectures", 3)
    try:
        arches = result.stdout.decode("ascii").split()
    except UnicodeDecodeError:
        raise PackageError("Invalid architecture response", 3) from None
    if host not in arches:
        raise PackageError("Input executable does not contain the host architecture", 3)
    return arches


def _unique_object(pairs: list) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def _engine_contract(engine: Path, capability: str) -> EngineContract:
    result = _checked([str(engine), "protocol-version"],
                      "UNSUPPORTED engine protocol query", 3)
    if result.stdout.strip() not in {b"1", b"2", b"3"}:
        raise PackageError("UNSUPPORTED engine protocol version", 3)
    version = int(result.stdout.strip())
    if capability == "legacy-session":
        if version not in {1, 2}:
            raise PackageError("UNSUPPORTED legacy-session requires protocol 1 or 2", 3)
        return EngineContract(version)
    if version != 3:
        raise PackageError("UNSUPPORTED continuous-turns-v1 requires protocol 3", 3)
    reply = _checked([str(engine), "capabilities", "--format", "json"],
                     "UNSUPPORTED engine capabilities query", 3)
    try:
        payload = json.loads(reply.stdout, object_pairs_hook=_unique_object)
    except (ValueError, UnicodeDecodeError):
        raise PackageError("UNSUPPORTED malformed engine capability reply", 3) from None
    if not isinstance(payload, dict):
        raise PackageError("UNSUPPORTED engine capability reply is not an object", 3)
    expected = {"protocol_version": 3, "request_schema_version": 1, "event_schema_version": 1}
    if (set(payload) != set(expected) | {"capabilities"}
            or any(type(payload.get(key)) is not int or payload[key] != value
                   for key, value in expected.items())):
        raise PackageError("UNSUPPORTED engine capability schema", 3)
    names = payload.get("capabilities")
    if (not isinstance(names, list) or not all(isinstance(name, str) for name in names)
            or len(names) != len(set(names)) or "continuous-turns-v1" not in names):
        raise PackageError("UNSUPPORTED named continuous-turns-v1 capability absent", 3)
    return EngineContract(version, payload)


def _write_new(path: Path, payload: bytes, mode: int = 0o600) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode)
    with os.fdopen(descriptor, "wb") as destination:
        destination.write(payload)
    path.chmod(mode)


def _signature(target: Path, role: str, identifier: str, identity: str,
               evidence: Path) -> dict:
    details = _checked([CODESIGN, "--display", "--verbose=4", str(target)],
                       "Cannot inspect code-sign identity")
    detail_text = (details.stdout + details.stderr).decode("utf-8", errors="strict")
    fields = {}
    for line in detail_text.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            fields.setdefault(key, []).append(value)
    if fields.get("Identifier") != [identifier]:
        raise PackageError("Signed code identifier differs from the test identity", 1)
    requirements = _checked([CODESIGN, "--display", "--requirements", "-", str(target)],
                            "Cannot inspect designated requirement")
    entitlements = _checked([CODESIGN, "--display", "--entitlements", ":-", str(target)],
                            "Cannot inspect effective entitlements")
    try:
        effective = plistlib.loads(entitlements.stdout)
    except (ValueError, plistlib.InvalidFileException):
        raise PackageError("Malformed signed entitlements", 1) from None
    if not isinstance(effective, dict) or effective.get(AUDIO_ENTITLEMENT) is not True:
        raise PackageError("Signed executable lacks the audio-input entitlement", 1)
    certificate_hashes = []
    if identity != "-":
        prefix = evidence / (role + "-certificate-")
        _checked([CODESIGN, "--display", "--extract-certificates", str(prefix), str(target)],
                 "Cannot extract signing certificates")
        certificates = sorted(evidence.glob(role + "-certificate-*"))
        if not certificates:
            raise PackageError("Non-ad-hoc signature has no signing certificate", 1)
        certificate_hashes = [{"file": str(path.relative_to(evidence.parent)),
                               "sha256": _sha256(_read_file(path))} for path in certificates]
    return {"identifier": identifier, "requested_identity": identity,
            "details": detail_text, "fields": fields,
            "designated_requirement": (requirements.stdout + requirements.stderr).decode("utf-8"),
            "effective_entitlements": effective, "certificates": certificate_hashes}


def assemble(request: PackageRequest) -> dict:
    _validate_output(request.out)
    app_bytes = _read_file(request.app, executable=True)
    engine_bytes = _read_file(request.engine, executable=True)
    resources = {name: _read_file(REPO_DIR / "Resources" / name)
                 for name in ("Info.plist", "AppIcon.icns", "Superkeet.entitlements")}
    try:
        info = plistlib.loads(resources["Info.plist"])
        entitlements = plistlib.loads(resources["Superkeet.entitlements"])
    except (ValueError, plistlib.InvalidFileException):
        raise PackageError("Invalid source resources") from None
    if not isinstance(info, dict) or info.get("CFBundleExecutable") != "Superkeet":
        raise PackageError("Unexpected source bundle executable")
    if not isinstance(entitlements, dict) or entitlements.get(AUDIO_ENTITLEMENT) is not True:
        raise PackageError("Source entitlements must enable audio input")
    if platform.system() != "Darwin":
        raise PackageError("Test bundle signing requires macOS", 3)
    host = platform.machine()
    architectures = {"app": _architectures(request.app, host),
                     "engine": _architectures(request.engine, host)}
    observed = _engine_contract(request.engine, request.capability)
    source_manifest = {
        "schema_version": 1, "bundle_id": request.bundle_id,
        "requested_capability": request.capability,
        "sources": {
            "app": {"path": str(request.app), "sha256": _sha256(app_bytes),
                    "declared_source_sha": request.app_source_sha},
            "engine": {"path": str(request.engine), "sha256": _sha256(engine_bytes),
                       "declared_source_sha": request.engine_source_sha},
            "resources": {name: {"path": str(REPO_DIR / "Resources" / name),
                                  "sha256": _sha256(payload)}
                          for name, payload in resources.items()}},
        "provenance_scope": "Source SHAs are operator declarations, not verified build receipts.",
        "engine_contract": observed.receipt(), "architectures": architectures,
    }
    if (_read_file(request.app, executable=True) != app_bytes
            or _read_file(request.engine, executable=True) != engine_bytes):
        raise PackageError("Input executable changed during inspection", 1)
    _validate_output(request.out)
    parent_fd = os.open(request.out.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.mkdir(request.out.name, mode=0o700, dir_fd=parent_fd)
    finally:
        os.close(parent_fd)
    request.out.chmod(0o700)
    _write_new(request.out / "assembly-started.json", _json_bytes({
        "status": "ASSEMBLY_STARTED", "completion_receipt": "bundle-manifest.json"}))
    bundle = request.out / "incomplete" / BUNDLE_NAME
    macos = bundle / "Contents" / "MacOS"
    resource_dir = bundle / "Contents" / "Resources"
    engine = resource_dir / "bin" / "parakeet"
    app = macos / "Superkeet"
    macos.mkdir(parents=True)
    engine.parent.mkdir(parents=True)
    evidence = request.out / "signatures"
    evidence.mkdir(mode=0o700)
    info.update(CFBundleIdentifier=request.bundle_id, CFBundleName="TestSuperkeet",
                CFBundleDisplayName="TestSuperkeet")
    _write_new(bundle / "Contents" / "Info.plist", plistlib.dumps(info), 0o644)
    _write_new(app, app_bytes, 0o755)
    _write_new(engine, engine_bytes, 0o755)
    for name in ("AppIcon.icns", "Superkeet.entitlements"):
        _write_new(resource_dir / name, resources[name], 0o644)
    _write_new(resource_dir / "source-manifest.json", _json_bytes(source_manifest), 0o644)
    copied_entitlements = resource_dir / "Superkeet.entitlements"
    targets = (("engine", engine, request.bundle_id + ".engine"),
               ("app", app, request.bundle_id), ("bundle", bundle, request.bundle_id))
    for _, target, identifier in targets:
        _check_path(target)
        _checked([CODESIGN, "--force", "--sign", request.signing_identity,
                  "--options", "runtime", "--timestamp=none", "--identifier", identifier,
                  "--entitlements", str(copied_entitlements), str(target)],
                 "Code signing failed")
    signatures = {}
    for role, target, identifier in targets:
        _checked([CODESIGN, "--verify", "--strict", str(target)],
                 "Strict signature verification failed")
        signatures[role] = _signature(target, role, identifier, request.signing_identity, evidence)
    _checked([CODESIGN, "--verify", "--deep", "--strict", str(bundle)],
             "Deep strict bundle verification failed")
    final_contract = _engine_contract(engine, request.capability)
    if final_contract != observed:
        raise PackageError("Embedded engine contract differs from the source", 1)
    inventory = {}
    for path in sorted(bundle.rglob("*")):
        _check_path(path)
        if path.is_file():
            inventory[str(path.relative_to(bundle))] = _sha256(_read_file(path))
    final_bundle = request.out / BUNDLE_NAME
    bundle.rename(final_bundle)
    _checked([CODESIGN, "--verify", "--deep", "--strict", str(final_bundle)],
             "Promoted bundle signature verification failed")
    manifest = {
        "schema_version": 1, "status": "COMPLETE", "scope": "test-bundle-assembly-only",
        "bundle_path": str(final_bundle), "bundle_id": request.bundle_id,
        "signing_identity": request.signing_identity,
        "signing_scope": "compile-only-ad-hoc" if request.signing_identity == "-" else "local-signed-test",
        "desktop_launch_verified": False, "continuous_execution_verified": False,
        "host_architecture": host, "pre_sign": source_manifest,
        "post_sign": {"engine_contract": final_contract.receipt(), "files": inventory,
                      "inventory_sha256": _sha256(_json_bytes(inventory)),
                      "app_sha256": inventory["Contents/MacOS/Superkeet"],
                      "engine_sha256": inventory["Contents/Resources/bin/parakeet"]},
        "signatures": signatures,
    }
    pending = request.out / "bundle-manifest.pending.json"
    _write_new(pending, _json_bytes(manifest))
    pending.rename(request.out / "bundle-manifest.json")
    return manifest


def _parse_request(argv: Optional[Sequence[str]]) -> PackageRequest:
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("app", "engine", "out", "bundle-id", "signing-identity",
                   "app-source-sha", "engine-source-sha"):
        parser.add_argument("--" + option, required=True)
    parser.add_argument("--capability", required=True,
                        choices=("legacy-session", "continuous-turns-v1"))
    args = parser.parse_args(argv)
    if not re.fullmatch(r"com\.superkeet\.actionsprobe\.[a-zA-Z0-9][a-zA-Z0-9-]{0,62}", args.bundle_id):
        raise PackageError("A test-only com.superkeet.actionsprobe.<safe suffix> bundle ID is required")
    if not args.signing_identity.strip() or args.signing_identity.startswith("--"):
        raise PackageError("An explicit signing identity is required")
    for value in (args.app_source_sha, args.engine_source_sha):
        if not re.fullmatch(r"[0-9a-fA-F]{40}", value):
            raise PackageError("Source SHAs must contain exactly 40 hexadecimal characters")
    return PackageRequest(_absolute_path(args.app), _absolute_path(args.engine),
                          _absolute_path(args.out), args.bundle_id, args.signing_identity,
                          args.capability, args.app_source_sha.lower(), args.engine_source_sha.lower())


def main(argv: Optional[Sequence[str]] = None) -> int:
    try:
        request = _parse_request(argv)
        manifest = assemble(request)
        sys.stdout.write(json.dumps({"status": "COMPLETE", "scope": manifest["scope"],
                                    "manifest": str(request.out / "bundle-manifest.json")}) + "\n")
        return 0
    except PackageError as error:
        sys.stderr.write(json.dumps({"status": "REFUSED", "reason": str(error),
                                    "exit_code": error.exit_code}) + "\n")
        return error.exit_code
    except (OSError, ValueError) as error:
        sys.stderr.write(json.dumps({"status": "INCOMPLETE", "reason": type(error).__name__,
                                    "exit_code": 4}) + "\n")
        return 4


if __name__ == "__main__":
    sys.exit(main())
