import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import demo_replay_partials as replay  # noqa: E402


def partial(at, text):
    return {"audio_ms": at, "text": text}


class ProgressKeyTests(unittest.TestCase):
    def test_ignores_case_punctuation_and_earlier_words(self):
        self.assertEqual(
            replay.progress_key("? And um inside this new note let's make the title say hello"),
            replay.progress_key("And inside, let's make the title say Hello."),
        )

    def test_new_last_word_is_progress(self):
        self.assertNotEqual(replay.progress_key("make the title say"), replay.progress_key("make the title say hello"))


class FirstEndpointTests(unittest.TestCase):
    def test_flicker_does_not_restart_the_timer(self):
        partials = [
            partial(500, "open up x.com?"),
            partial(1000, "open up x dot com."),
            partial(1500, "open up x.com"),
            partial(2000, "Open up x dot com"),
            partial(2500, "open up x.com. nice"),
        ]
        self.assertEqual(replay.first_endpoint(partials, 1000, 10_000), 2000)

    def test_steady_speech_has_no_endpoint_until_the_clip_ends(self):
        partials = [partial(500 * i, f"word{i}") for i in range(1, 6)]
        self.assertIsNone(replay.first_endpoint(partials, 1000, 2600))
        self.assertEqual(replay.first_endpoint(partials, 1000, 4000), 3500)


class ParseEventsTests(unittest.TestCase):
    OUTPUT = "\n".join([
        "Model loaded in 0.4s",
        '{"audio_ms":510,"session_id":"replay","trailing_silence_ms":0,"type":"tick"}',
        '{"audio_ms":510,"sequence":1,"session_id":"replay","text":"Hello.","type":"partial"}',
        '{"audio_ms":1020,"session_id":"replay","trailing_silence_ms":352,"type":"tick"}',
        '{"session_id":"replay","status":"ok","text":"Hello.","type":"complete"}',
    ])

    def test_splits_partials_ticks_and_final(self):
        partials, ticks, final = replay.parse_events(self.OUTPUT)
        self.assertEqual([p["text"] for p in partials], ["Hello."])
        self.assertEqual([t["trailing_silence_ms"] for t in ticks], [0, 352])
        self.assertEqual(final, "Hello.")

    def test_an_engine_without_ticks_yields_none(self):
        _, ticks, _ = replay.parse_events('{"audio_ms":510,"sequence":1,"text":"Hi","type":"partial"}')
        self.assertEqual(ticks, [])


class TimelineTests(unittest.TestCase):
    def test_a_tick_precedes_the_partial_of_the_same_audio_and_times_are_recording_time(self):
        partials = [{"audio_ms": 510, "sequence": 1, "text": "Hello."}]
        ticks = [{"audio_ms": 510, "trailing_silence_ms": 0}, {"audio_ms": 1020, "trailing_silence_ms": 352}]
        self.assertEqual(replay.timeline(8_000, partials, ticks), [
            {"type": "tick", "at_ms": 8_510, "trailing_silence_ms": 0},
            {"type": "partial", "at_ms": 8_510, "sequence": 1, "text": "Hello."},
            {"type": "tick", "at_ms": 9_020, "trailing_silence_ms": 352},
        ])


if __name__ == "__main__":
    unittest.main()
