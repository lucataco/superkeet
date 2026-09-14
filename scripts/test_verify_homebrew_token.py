import contextlib
import io
import os
import unittest
from unittest.mock import patch

from verify_homebrew_token import NULL_SHA, REPOSITORY, VerificationError, main, verify


class TokenVerificationTests(unittest.TestCase):
    def responses(self, branch="main"):
        return [
            (200, {"full_name": REPOSITORY, "default_branch": branch, "permissions": {"push": True}}),
            (200, {"ref": f"refs/heads/{branch}", "object": {"type": "commit", "sha": "a" * 40}}),
            (422, {"message": "Object does not exist"}),
            (422, {"message": "Validation Failed", "errors": [
                {"resource": "PullRequest", "code": "custom", "message": f"No commits between {branch} and {branch}"}
            ]}),
        ]

    def run_probe(self, responses):
        calls = []

        def request(method, path, payload=None):
            calls.append((method, path, payload))
            return responses[len(calls) - 1]

        return verify(request), calls

    def test_write_probes_cannot_create_a_reference_or_pull_request(self):
        lines, calls = self.run_probe(self.responses())
        self.assertEqual(len(lines), 4)
        self.assertEqual([call[0] for call in calls], ["GET", "GET", "POST", "POST"])
        self.assertEqual(calls[2][2], {"ref": "refs/heads/main", "sha": NULL_SHA})
        self.assertEqual(calls[3][2]["head"], calls[3][2]["base"])
        self.assertNotIn("issue", calls[3][2])

    def test_existing_reference_validation_is_also_accepted(self):
        responses = self.responses()
        responses[2] = (422, {"message": "Reference already exists"})
        self.run_probe(responses)

    def test_missing_write_permissions_fail_despite_reported_push_access(self):
        for index in [2, 3]:
            responses = self.responses()
            responses[index] = (403, {"message": "Resource not accessible by personal access token"})
            with self.assertRaises(VerificationError):
                self.run_probe(responses)

    def test_authentication_failure_and_unexpected_success_fail(self):
        for index, status in [(0, 401), (1, 404), (2, 201), (3, 201), (2, 429)]:
            responses = self.responses()
            responses[index] = (status, {})
            with self.assertRaises(VerificationError):
                self.run_probe(responses)

    def test_unrelated_validation_errors_are_not_permission_success(self):
        for index in [2, 3]:
            responses = self.responses()
            responses[index] = (422, {"message": "Validation Failed", "errors": []})
            with self.assertRaises(VerificationError):
                self.run_probe(responses)

    def test_unexpected_repository_stops_before_write_requests(self):
        responses = self.responses()
        responses[0][1]["full_name"] = "someone/else"
        with self.assertRaises(VerificationError):
            self.run_probe(responses)

    def test_release_push_access_check_must_also_pass(self):
        responses = self.responses()
        responses[0][1]["permissions"]["push"] = False
        with self.assertRaises(VerificationError):
            self.run_probe(responses)

    def test_branch_names_with_slashes_are_encoded_for_reads(self):
        _, calls = self.run_probe(self.responses("release/main"))
        self.assertTrue(calls[1][1].endswith("heads/release%2Fmain"))
        self.assertEqual(calls[3][2]["head"], "release/main")

    def test_missing_secret_does_not_fall_back_to_other_gh_credentials(self):
        with patch.dict(os.environ, {}, clear=True), patch("verify_homebrew_token.verify") as probe:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(main(), 1)
            probe.assert_not_called()


if __name__ == "__main__":
    unittest.main()
