import importlib.util
from pathlib import Path
import unittest

MODULE_PATH = Path(__file__).resolve().with_name("runtime_forensics.py")
SPEC = importlib.util.spec_from_file_location("runtime_forensics", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SummarizeTests(unittest.TestCase):
    def test_reports_count_median_and_range(self):
        runs = [{"ready_seconds": value} for value in [1.4, 0.8, 1.0]]
        result = MODULE.summarize(runs, ["ready_seconds"])
        self.assertEqual(result["run_count"], 3)
        self.assertEqual(result["metrics"]["ready_seconds"], {"median": 1.0, "min": 0.8, "max": 1.4})

    def test_ignores_metrics_missing_from_a_failed_run(self):
        runs = [{"ready_seconds": 1.0}, {"error": "failed"}]
        result = MODULE.summarize(runs, ["ready_seconds"])
        self.assertEqual(result["run_count"], 2)
        self.assertEqual(result["metrics"]["ready_seconds"]["median"], 1.0)


class TranscriptValidationTests(unittest.TestCase):
    def valid_result(self):
        return {
            "status": "ok",
            "failed_segments": 0,
            "dropped_samples": 0,
            "duration": 48.0,
            "inference_time": 1.2,
            "text": "Open the notes app and search Norbert Wiener",
        }

    def test_accepts_completed_known_speech(self):
        result = self.valid_result()
        self.assertTrue(all(MODULE.validate_transcript(result).values()))

    def test_rejects_fast_failure_or_missing_work(self):
        for key, value in [
            ("status", "error"),
            ("failed_segments", 1),
            ("dropped_samples", 1),
            ("duration", 0),
            ("inference_time", 0),
            ("text", ""),
        ]:
            with self.subTest(key=key):
                result = self.valid_result()
                result[key] = value
                with self.assertRaisesRegex(RuntimeError, "transcript validation failed"):
                    MODULE.validate_transcript(result)


if __name__ == "__main__":
    unittest.main()
