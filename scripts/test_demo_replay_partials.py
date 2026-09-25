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


if __name__ == "__main__":
    unittest.main()
