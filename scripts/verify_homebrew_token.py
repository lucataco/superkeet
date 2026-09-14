#!/usr/bin/env python3
import json
import os
from pathlib import Path
import re
import subprocess
from urllib.parse import quote

REPOSITORY = "lucataco/homebrew-tap"
NULL_SHA = "0" * 40


class VerificationError(Exception):
    pass


def api(method, path, payload=None):
    command = ["gh", "api", "--hostname", "github.com", "--include", "--method", method,
               "-H", "Accept: application/vnd.github+json",
               "-H", "X-GitHub-Api-Version: 2026-03-10", path]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(payload) if payload is not None else None,
                            capture_output=True, text=True, timeout=30, check=False)
    headers, separator, body = result.stdout.partition("\n\n")
    status = re.match(r"HTTP/\S+\s+(\d+)", headers)
    if not status or not separator:
        raise VerificationError("GitHub did not return an HTTP response. Check connectivity and the gh CLI.")
    try:
        return int(status[1]), json.loads(body)
    except (ValueError, TypeError) as error:
        raise VerificationError("GitHub returned an unreadable API response.") from error


def require_status(status, expected, operation):
    if status != expected:
        raise VerificationError(
            f"{operation}: expected HTTP {expected}, received {status}. "
            "Check HOMEBREW_TAP_TOKEN, its expiration, selected repository, and permission levels."
        )


def verify(request=api):
    status, repository = request("GET", f"repos/{REPOSITORY}")
    require_status(status, 200, "Repository metadata access")
    if repository.get("full_name", "").lower() != REPOSITORY.lower():
        raise VerificationError("GitHub returned a different repository; refusing permission probes.")
    if repository.get("permissions", {}).get("push") is not True:
        raise VerificationError("The token does not satisfy the release workflow's repository push-access check.")
    branch = repository.get("default_branch")
    if not isinstance(branch, str) or not branch:
        raise VerificationError("The tap has no default branch.")
    status, reference = request("GET", f"repos/{REPOSITORY}/git/ref/heads/{quote(branch, safe='')}")
    require_status(status, 200, "Repository contents access")
    ref = f"refs/heads/{branch}"
    if reference.get("ref") != ref or reference.get("object", {}).get("type") != "commit":
        raise VerificationError("Could not verify the default-branch reference.")

    status, response = request("POST", f"repos/{REPOSITORY}/git/refs", {"ref": ref, "sha": NULL_SHA})
    require_status(status, 422, "Contents write endpoint authorization")
    if response.get("message", "").lower().rstrip(".") not in {"reference already exists", "object does not exist"}:
        raise VerificationError("Contents probe returned an unexpected validation error; authorization is inconclusive.")

    status, response = request("POST", f"repos/{REPOSITORY}/pulls", {
        "title": "Homebrew token authorization probe",
        "head": branch, "base": branch, "draft": True,
    })
    require_status(status, 422, "Pull requests write endpoint authorization")
    errors = response.get("errors", [])
    expected_message = f"No commits between {branch} and {branch}"
    if not isinstance(errors, list) or not any(
        isinstance(error, dict) and error.get("resource") == "PullRequest"
        and error.get("message") == expected_message for error in errors
    ):
        raise VerificationError("Pull-request probe returned an unexpected validation error; authorization is inconclusive.")

    return [
        f"Authenticated access to {REPOSITORY} and its default branch passed.",
        "Contents write endpoint authorized; the non-creating reference probe was rejected as expected.",
        "Pull requests write endpoint authorized; the same-branch PR probe was rejected as expected.",
        "No branches, commits, pull requests, releases, or release assets were created or updated.",
    ]


def main():
    try:
        if not os.environ.get("GH_TOKEN", "").strip():
            raise VerificationError("HOMEBREW_TAP_TOKEN is missing or empty. Set the repository Actions secret with that exact name.")
        lines = verify()
        succeeded = True
    except (VerificationError, OSError, subprocess.TimeoutExpired) as error:
        lines = [str(error)]
        succeeded = False
    for line in lines:
        print(line)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        heading = "Homebrew token verification passed" if succeeded else "Homebrew token verification failed"
        Path(summary_path).write_text(f"## {heading}\n\n" + "\n".join(f"- {line}" for line in lines) + "\n")
    return 0 if succeeded else 1


if __name__ == "__main__":
    raise SystemExit(main())
