import unittest
from audio_regression import evaluate, word_errors, words


class AudioOracleTests(unittest.TestCase):
    def test_critical_error_fails_even_with_low_word_error_rate(self):
        case = {"id": "auth", "spoken": "please configure auth middleware now", "critical_counts": {"auth": 1}}
        result = evaluate(case, {"text": "please configure off middleware now", "status": "ok"}, 0.5)
        self.assertIn("auth: expected 1, got 0", result["failures"])

    def test_repeated_answers_cannot_be_deduplicated(self):
        case = {"id": "repeated-answers", "spoken": "A A agreed agreed", "critical_counts": {"a": 2, "agreed": 2}, "answer_count": 4}
        self.assertTrue(evaluate(case, {"text": "A agreed", "status": "ok"}, 1)["failures"])

    def test_word_error_rate_counts_insertions_deletions_and_substitutions(self):
        self.assertEqual(word_errors(words("one two three"), words("one four three extra")), 2)

    def test_number_rendering_is_equivalent_but_or_is_not_err(self):
        self.assertEqual(words("Five six seven eight"), words("5 6 7 8"))
        self.assertNotEqual(words("err"), words("or"))


if __name__ == "__main__":
    unittest.main()
