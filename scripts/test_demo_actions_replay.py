import unittest

from demo_actions_replay import load_complete_text, missing_phrases, normalize_text, parse_engine_stdout


class DemoActionsReplayTests(unittest.TestCase):
    def test_normalize_collapses_whitespace(self):
        self.assertEqual(normalize_text("hello   there\nfriend"), "hello there friend")

    def test_load_complete_text_reads_object_and_array(self):
        event = {"type": "complete", "text": "open Notes"}
        self.assertEqual(load_complete_text(event), "open Notes")
        self.assertEqual(load_complete_text([{"type": "partial", "text": "open"}, event]), "open Notes")

    def test_load_complete_text_rejects_empty_text(self):
        with self.assertRaises(ValueError):
            load_complete_text({"type": "complete", "text": "  "})

    def test_parse_engine_stdout_reads_pretty_json_or_ndjson(self):
        pretty = '{\n  "type": "complete",\n  "text": "open Notes"\n}\n'
        self.assertEqual(parse_engine_stdout(pretty), "open Notes")
        ndjson = '{"type":"partial","text":"open"}\n{"type":"complete","text":"open Notes"}\n'
        self.assertEqual(parse_engine_stdout(ndjson), "open Notes")

    def test_parse_engine_stdout_rejects_empty(self):
        with self.assertRaises(ValueError):
            parse_engine_stdout("")

    def test_missing_phrases_ignores_punctuation_drift(self):
        drifted = (
            "Alright, can you open up the notes app for me? And umce right there, "
            "can you create a new note? And um inside this new note, let's make the "
            "title say hello. can you open up the Arc browser? Google search Norbert "
            "Wiener. open up x.com. open up the photo booth. take a picture of me."
        )
        self.assertEqual(missing_phrases(drifted), [])
        self.assertEqual(missing_phrases("open Notes"), ["notes app", "create a new note",
                         "title say hello", "arc browser", "norbert wiener", "x.com",
                         "photo booth", "take a picture"])


if __name__ == "__main__":
    unittest.main()
