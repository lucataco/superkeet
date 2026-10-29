import copy
import unittest

import actions_probe as probe


SESSION = "12345678-1234-4234-8234-123456789abc"


def trace(*events, accepted=100, status="finished", dropped=0, failed=0):
    rows = [{"type": "session_started", "sample_rate": 16000, "input_kind": "wav",
             "capability": "continuous-turns-v1"},
            {"type": "audio_progress", "accepted_through": accepted}, *events,
            {"type": "session_terminal", "status": status, "accepted_through": accepted,
             "failed_segments": failed, "dropped_samples": dropped}]
    return [{"schema_version": 1, "protocol_version": 3, "session_id": SESSION,
             "event_id": index, "published_ns": index * 100, "clock_id": "synthetic", **row}
            for index, row in enumerate(rows, 1)]


def partition(start=0, end=100, kind="silence", turn=""):
    return {"type": "source_accounted", "source_range": {"start": start, "end": end},
            "kind": kind, "turn_id": turn}


def final(start=0, end=100, turn="t1", status="ok", dropped=0, failed=0):
    return {"type": "turn_final", "turn_id": turn, "revision_id": 2,
            "source_range": {"start": start, "end": end}, "text": "fixture speech",
            "status": status, "dropped_samples": dropped, "failed_segments": failed}


def preview(start=0, end=100):
    return {"type": "turn_preview", "turn_id": "t1", "revision_id": 1,
            "source_range": {"start": start, "end": end}, "context_range": {"start": start, "end": end},
            "replaces_revision": 0, "replacement_scope": "whole-unfinalized-turn",
            "truncated": False, "text": "Create a new note."}


def loss(start=0, end=100):
    return {"type": "loss", "source_range": {"start": start, "end": end},
            "reason": "overrun", "dropped_samples": end - start}


class Protocol3AccountingTests(unittest.TestCase):
    def reject(self, rows):
        with self.assertRaises(ValueError):
            probe.validate_protocol3_trace(rows)

    def test_finish_cannot_relabel_pending_preview_or_detected_speech_as_silence(self):
        for evidence in ([preview()], [{"type": "speech_activity", "state": "speech", "position": 0}],
                         [{"type": "turn_candidate", "turn_id": "t1", "candidate_revision": 1, "end_sample": 100}]):
            with self.subTest(evidence=evidence):
                self.reject(trace(*evidence, partition()))

    def test_failed_terminal_alone_cannot_discard_speech(self):
        self.reject(trace(preview(), partition(), status="failed", failed=1))

    def test_recognition_failure_or_explicit_loss_resolves_pending_speech(self):
        rows = trace(preview(), final(status="error", failed=1), partition(kind="speech", turn="t1"),
                     status="failed", failed=1)
        self.assertEqual(probe.validate_protocol3_trace(rows)["status"], "failed")
        rows = trace(preview(), loss(), partition(kind="loss"), status="failed", dropped=100)
        self.assertEqual(probe.validate_protocol3_trace(rows)["status"], "failed")

    def test_loss_marked_final_owns_its_lost_range(self):
        rows = trace(final(status="partial", dropped=100), loss(), partition(kind="loss"),
                     status="failed", dropped=100)
        self.assertEqual(probe.validate_protocol3_trace(rows)["turn_count"], 1)

    def test_loss_outside_final_cannot_satisfy_its_drop_counter(self):
        self.reject(trace(final(status="partial", dropped=100), partition(kind="speech", turn="t1"),
                          loss(100, 200), partition(100, 200, "loss"), accepted=200, status="failed", dropped=100))

    def test_partial_final_partitions_recognized_and_lost_samples(self):
        rows = trace(final(end=300, status="partial", dropped=100), loss(100, 200),
                     partition(0, 100, "speech", "t1"), partition(100, 200, "loss"),
                     partition(200, 300, "speech", "t1"), accepted=300, status="failed", dropped=100)
        self.assertEqual(probe.validate_protocol3_trace(rows)["turn_count"], 1)
        for mutate in (lambda r: r[2].update(dropped_samples=99),
                       lambda r: r[-1].update(status="finished"),
                       lambda r: r[2].update(status="ok", dropped_samples=0),
                       lambda r: r[4].update(kind="silence", turn_id="")):
            bad = copy.deepcopy(rows)
            mutate(bad)
            self.reject(bad)

    def test_loss_cannot_cross_final_ownership_boundary(self):
        self.reject(trace(final(status="partial", dropped=50), final(100, 200, "t2", "partial", 50),
                          loss(50, 150), partition(0, 50, "speech", "t1"), partition(50, 150, "loss"),
                          partition(150, 200, "speech", "t2"), accepted=200, status="failed", dropped=100))

    def test_accounting_before_final_does_not_allow_retroactive_silence_ownership(self):
        self.reject(trace(partition(), final()))

    def test_all_advisory_positions_stay_at_accepted_audio_frontier(self):
        for evidence in ({**preview(), "context_range": {"start": 0, "end": 101}},
                         {**preview(), "source_range": {"start": 0, "end": 101}},
                         {"type": "speech_activity", "state": "speech", "position": 101},
                         {"type": "turn_candidate", "turn_id": "t1", "candidate_revision": 1, "end_sample": 101}):
            with self.subTest(evidence=evidence):
                self.reject(trace(evidence, final(), partition(kind="speech", turn="t1")))

    def test_retraction_does_not_erase_candidate_revision_history(self):
        candidate = {"type": "turn_candidate", "turn_id": "t1", "candidate_revision": 1, "end_sample": 100}
        retract = {"type": "turn_retracted", "turn_id": "t1", "candidate_revision": 1}
        self.reject(trace(candidate, retract, candidate, final(), partition(kind="speech", turn="t1")))
        rows = trace(candidate, retract, {**candidate, "candidate_revision": 2}, final(),
                     partition(kind="speech", turn="t1"))
        self.assertEqual(probe.validate_protocol3_trace(rows)["status"], "finished")

    def test_speech_activity_positions_do_not_regress(self):
        self.reject(trace({"type": "speech_activity", "state": "speech", "position": 50},
                          {"type": "speech_activity", "state": "silence", "position": 10},
                          final(), partition(kind="speech", turn="t1")))

    def test_preview_disappearance_cannot_hide_unowned_speech(self):
        rows = trace(preview(), final(end=50), partition(0, 50, "speech", "t1"), partition(50, 100))
        self.reject(rows)

    def test_cancellation_suppresses_final_but_retains_explicit_loss_accounting(self):
        rows = trace(preview(), loss(), partition(kind="loss"), status="cancelled", dropped=100)
        self.assertEqual(probe.validate_protocol3_trace(rows)["status"], "cancelled")
        self.reject(trace(preview(), partition(), status="cancelled"))


class Protocol3IdentityTests(unittest.TestCase):
    def test_requests_and_events_require_uuid_session_ids(self):
        for stem, rows in (("request", probe.strict_json((probe.FIXTURES / "golden/requests.json").read_bytes())),
                           ("event", trace(partition()))):
            schema = probe.strict_json((probe.FIXTURES / f"schemas/protocol3-{stem}-v1.json").read_bytes())
            for row in rows:
                if "session_id" not in row:
                    continue
                probe.validate_schema({**row, "session_id": SESSION}, schema)
                for wrong in ("fixture-session", "replay", "", SESSION + "extra", "g" + SESSION[1:]):
                    with self.subTest(stem=stem, kind=row.get("type", row.get("command")), wrong=wrong):
                        with self.assertRaises(ValueError):
                            probe.validate_schema({**row, "session_id": wrong}, schema)

    def test_continuous_acknowledgements_bind_uuid_and_command_state(self):
        schema = probe.strict_json((probe.FIXTURES / "schemas/protocol3-reply-v1.json").read_bytes())
        for command, state in (("continuous_start", "capturing"), ("continuous_finish", "finishing"),
                               ("continuous_cancel", "cancelling")):
            row = {"schema_version": 1, "protocol_version": 3, "request_id": "r2", "status": "accepted",
                   "command": command, "session_id": SESSION, "state": state}
            probe.validate_schema(row, schema)
            for fields in ({"session_id": "fixture-session"}, {"state": "idle"}, {"session_id": "replay"}):
                with self.subTest(command=command, fields=fields), self.assertRaises(ValueError):
                    probe.validate_schema({**row, **fields}, schema)

    def test_golden_session_ids_are_uuids_without_relabelling_legacy_replay(self):
        for path in (probe.FIXTURES / "golden").glob("*.ndjson"):
            rows = list(map(probe.strict_json, path.read_bytes().splitlines()))
            probe.validate_protocol3_trace(rows)
            for row in rows:
                self.assertEqual(str(probe.uuid.UUID(row["session_id"])), row["session_id"])
        legacy = probe.strict_json((probe.FIXTURES / "golden/legacy-v2.json").read_bytes())
        self.assertIn("replay", str(legacy))


if __name__ == "__main__":
    unittest.main()
