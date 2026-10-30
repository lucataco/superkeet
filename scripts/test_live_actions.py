import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

RIG = Path(__file__).resolve().parent / "live-actions"
sys.path.insert(0, str(RIG))

import build_stimulus  # noqa: E402
import common  # noqa: E402
import report  # noqa: E402

BH1 = RIG / "fixtures" / "bh1"
PLANNER_GUARD = RIG / "fixtures" / "planner-guard"
SCENARIO = RIG / "scenarios" / "textedit-three-steps.json"


def scenario():
    return common.load_scenario(SCENARIO)


class PhraseMatchingTests(unittest.TestCase):
    def test_a_phrase_must_sit_on_word_boundaries(self):
        self.assertTrue(common.phrase_in_text("Then open x.com. Next", "x.com"))
        self.assertFalse(common.phrase_in_text("Then open ax.com. Next", "x.com"))
        self.assertFalse(common.phrase_in_text("open the helloworld app", "hello"))

    def test_punctuation_and_case_do_not_matter(self):
        self.assertTrue(common.phrase_in_text("...create a new Document?", "document?"))

    def test_a_camel_case_app_name_matches_the_engines_two_words(self):
        self.assertTrue(common.phrase_in_text("Can you open up Text Edit for me?", "TextEdit"))
        self.assertTrue(common.phrase_in_text("Can you open up TextEdit for me?", "TextEdit"))
        self.assertFalse(common.phrase_in_text("Can you open up text at it for me?", "TextEdit"))

    def test_missing_phrases_lists_only_the_absent_ones(self):
        self.assertEqual(common.missing_phrases("open notes", ["notes", "photo booth"]), ["photo booth"])

    def test_phrase_end_comes_from_the_last_word_of_the_phrase(self):
        clock = common.read_clock(BH1 / "speech-clock.tsv")
        self.assertEqual(common.phrase_end_ms(clock, "TextEdit"), 2373)
        self.assertEqual(common.phrase_end_ms(clock, "document?"), 5780)
        self.assertEqual(common.phrase_end_ms(clock, "make the title"), 7363)
        self.assertIsNone(common.phrase_end_ms(clock, "photo booth"))

    def test_one_clock_row_can_carry_several_tokens(self):
        clock = [(100, 400, "open"), (450, 900, "x.com?")]
        self.assertEqual(common.phrase_end_ms(clock, "x.com"), 900)
        self.assertEqual(common.phrase_end_ms(clock, "open x.com"), 900)
        self.assertIsNone(common.phrase_end_ms([(450, 900, "ax.com?")], "x.com"))


class ScenarioTests(unittest.TestCase):
    def test_the_shipped_scenario_is_valid(self):
        self.assertEqual(common.validate_scenario(json.loads(SCENARIO.read_text())), [])

    def test_bad_scenarios_are_named(self):
        bad = json.loads(SCENARIO.read_text())
        bad["start_state"] = {"com.apple.Notes": "quit"}
        bad["expect"][0]["after"] = "photo booth"
        bad["expect"][1]["probe"] = {"visible": "yes"}
        bad["forbid"] = ["world_peace"]
        problems = " ".join(common.validate_scenario(bad))
        for needle in ("com.apple.Notes", "photo booth", "probe must have exactly one", "world_peace"):
            self.assertIn(needle, problems)

    def test_audio_key_ignores_expectations_but_not_speech(self):
        base = scenario()
        louder = json.loads(json.dumps(base))
        louder["expect"][0]["budget_ms"] = 1
        longer_pause = json.loads(json.dumps(base))
        longer_pause["utterances"][0]["pause_ms"] += 1
        self.assertEqual(common.audio_key(base), common.audio_key(louder))
        self.assertNotEqual(common.audio_key(base), common.audio_key(longer_pause))

    def test_targets_are_the_apps_the_rig_sets_up(self):
        self.assertEqual(common.scenario_targets(scenario()), ["com.apple.TextEdit"])

    def test_percentile_treats_a_miss_as_infinitely_slow(self):
        self.assertEqual(common.percentile([100, 200, 300, 400, 500], 50), 300)
        self.assertEqual(common.percentile([100, 200, 300, 400, 500], 90), 500)
        self.assertIsNone(common.percentile([100, 200, None, None, None], 50))
        self.assertIsNone(common.percentile([], 50))


class StimulusTimelineTests(unittest.TestCase):
    def test_layout_places_clips_with_exact_silences(self):
        windows, total = build_stimulus.layout(100, [48000, 96000, 24000], [200, 550, 2000])
        self.assertEqual(windows, [(4800, 52800), (62400, 158400), (184800, 208800)])
        self.assertEqual(total, 208800 + 96000)
        self.assertEqual(build_stimulus.windows_ms(windows), [(100, 1100), (1300, 3300), (3850, 4350)])

    def test_alignment_must_land_inside_the_utterance_windows(self):
        windows = [(0, 1440), (1640, 4935), (5485, 7888)]
        clock = [(51, 131, "Can"), (1992, 2153, "And"), (5675, 5795, "And")]
        self.assertEqual(build_stimulus.alignment_problems(clock, windows), [])
        drifted = clock + [(9000, 9200, "stray")]
        self.assertIn("stray", build_stimulus.alignment_problems(drifted, windows)[0])
        self.assertIn("utterance 2", build_stimulus.alignment_problems(clock[:2], windows)[0])

    def test_the_live_gate_wants_the_phrase_in_a_partial_soon_after_it_ends(self):
        clock = [(772, 1213, "TextEdit")]
        late = [(1020, "Can you open up text?"), (1530, "Can you open up Text Adit for me?"), (6630, "Can you open up Text Edit")]
        timely = late[:2] + [(1530, "Can you open up Text Edit for me?")]
        self.assertEqual([p.phrase for p in build_stimulus.live_gate_problems(late, clock, ["TextEdit"])], ["TextEdit"])
        self.assertEqual(build_stimulus.live_gate_problems(timely, clock, ["TextEdit"]), [])

    def test_a_failed_phrase_names_the_utterances_to_synthesize_again(self):
        self.assertEqual(build_stimulus.carrying(scenario(), [build_stimulus.Problem("hello.", "x")]), [2])
        self.assertEqual(build_stimulus.carrying(scenario(), [build_stimulus.Problem(None, "x")]), [0, 1, 2])


class LogParsingTests(unittest.TestCase):
    def test_log_rows_carry_epoch_milliseconds_and_skip_noise(self):
        text = 'Filtering the log data using "subsystem"\n' + (BH1 / "log.ndjson").read_text() + '{"timestamp": "broken'
        rows = common.parse_log(text)
        self.assertEqual(len(rows), 13)
        self.assertEqual(rows[0][1:], ("HotkeyManager", "Command hotkey pressed"))
        self.assertEqual(rows[1][0] - rows[0][0], 1)


class ProbeTests(unittest.TestCase):
    def rows(self, *events):
        return [(e.pop("ms"), e) for e in events]

    def test_the_open_panel_and_existing_windows_are_not_new_documents(self):
        rows = self.rows(
            {"ms": -50, "event": "target_windows", "bundle": "b", "titles": ["Notes"]},
            {"ms": 300, "event": "target_windows", "bundle": "b", "titles": ["Notes", "Open"]},
            {"ms": 900, "event": "target_windows", "bundle": "b", "titles": ["Notes", "Untitled"]},
        )
        self.assertEqual(report.probe_ms("new_window", "b", rows), (900, None))

    def test_an_app_that_was_frontmost_before_playback_is_called_out(self):
        rows = self.rows({"ms": -200, "event": "frontmost", "bundle": "b"}, {"ms": 400, "event": "frontmost", "bundle": "b"})
        at, note = report.probe_ms("frontmost", "b", rows)
        self.assertEqual(at, 400)
        self.assertIn("before playback", note)

    def test_text_is_read_from_the_document_not_the_hud(self):
        rows = self.rows(
            {"ms": 100, "event": "hud", "text": "Typed “hello” in TextEdit"},
            {"ms": 500, "event": "target_text", "bundle": "b", "texts": [""]},
            {"ms": 900, "event": "target_text", "bundle": "b", "texts": ["Hello there"]},
        )
        self.assertEqual(report.probe_ms("focused_text_contains", "hello", rows), (900, None))

    def test_a_probe_that_never_holds_is_a_miss(self):
        self.assertEqual(report.probe_ms("focused_text_contains", "hello", []), (None, None))


class AuditScoringTests(unittest.TestCase):
    def row(self, tool, args, outcome, detail=None, risk="mutating"):
        return {"toolName": tool, "arguments": args, "outcome": outcome, "detail": detail, "risk": risk}

    def test_the_same_tool_and_arguments_twice_is_a_duplicate(self):
        audit = [
            self.row("press_shortcut", '{"keys":["cmd","n"]}', "speculative"),
            self.row("press_shortcut", '{"keys":["cmd","n"]}', "succeeded"),
            self.row("open_app", '{"name":"TextEdit"}', "speculative"),
            self.row("list_apps", "{}", "succeeded", risk="readOnly"),
            self.row("list_apps", "{}", "succeeded", risk="readOnly"),
        ]
        self.assertEqual(report.duplicate_dispatches(audit), 1)

    def test_smart_quotes_do_not_hide_text_that_landed(self):
        run = {"name": "r", "events": [], "log": [], "meta": {}, "documents": [{"name": "Untitled", "text": "Let’s  go"}],
               "audit": [self.row("type_text", "{}", "succeeded (auto-approved)", "Typed “Let's go” in TextEdit")]}
        result = report.analyze_run(run, scenario(), [(0, 100, "x")])
        self.assertEqual(result["forbidden"]["success_without_effect"], 0)

    def test_a_hud_card_left_over_from_the_previous_run_is_not_a_claim(self):
        events = [
            {"event": "audio_play", "t": 10_000},
            {"event": "hud", "t": 9_000, "text": "Done | Typed “hello” in TextEdit"},
            {"event": "hud", "t": 10_500, "text": "Listening… | Can you"},
        ]
        run = {"name": "r", "events": events, "log": [], "meta": {}, "documents": [], "audit": []}
        result = report.analyze_run(run, scenario(), [(0, 100, "x")])
        self.assertEqual(result["forbidden"]["success_without_effect"], 0)

    def test_typing_two_different_texts_is_not_a_duplicate(self):
        args = '{"app":"TextEdit","text":"***"}'
        audit = [self.row("type_text", args, "succeeded", "Typed “one” in TextEdit"), self.row("type_text", args, "succeeded", "Typed “two” in TextEdit")]
        self.assertEqual(report.duplicate_dispatches(audit), 0)


class PlannerGuardFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.result = report.analyze_run(report.load_run(PLANNER_GUARD), scenario(), common.read_clock(PLANNER_GUARD / "speech-clock.tsv"))

    def test_the_open_landed_and_the_cancelled_steps_are_misses(self):
        expect = self.result["expect"]
        self.assertEqual(expect["open"]["latency_ms"], 1893 - 1213)
        self.assertIsNone(expect["new_doc"]["latency_ms"])
        self.assertIsNone(expect["hello"]["latency_ms"])

    def test_the_split_and_the_planner_are_counted_from_the_log(self):
        self.assertEqual(self.result["forbidden"]["take_split"], 1)
        self.assertEqual(self.result["forbidden"]["planner_call"], 1)

    def test_the_report_says_the_rig_cancelled_the_app(self):
        self.assertTrue(any("cancelled the app" in d for d in self.result["details"]))

    def test_no_typing_claim_means_no_success_without_effect(self):
        self.assertEqual(self.result["forbidden"]["success_without_effect"], 0)


class FixtureRunTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.result = report.analyze_run(report.load_run(BH1), scenario(), common.read_clock(BH1 / "speech-clock.tsv"))

    def test_latencies_are_probe_time_minus_phrase_end(self):
        expect = self.result["expect"]
        self.assertEqual(expect["open"]["latency_ms"], 2965 - 2373)
        self.assertEqual(expect["new_doc"]["latency_ms"], 6182 - 5780)
        self.assertIsNone(expect["hello"]["latency_ms"])

    def test_the_take_split_is_found_from_the_pause_log_line(self):
        self.assertEqual(self.result["forbidden"]["take_split"], 1)
        self.assertIn("6424", self.result["details"][0])

    def test_typing_that_never_reached_the_document_is_a_success_without_effect(self):
        self.assertEqual(self.result["forbidden"]["success_without_effect"], 1)

    def test_this_run_made_no_planner_call_and_no_duplicate(self):
        self.assertEqual(self.result["forbidden"]["planner_call"], 0)
        self.assertEqual(self.result["forbidden"]["duplicate_dispatch"], 0)

    def test_first_words_reach_the_hud_after_the_first_spoken_word_ends(self):
        self.assertEqual(self.result["hud"]["first_words_ms"], 1362 - 829)

    def test_a_landed_document_clears_the_flag(self):
        run = report.load_run(BH1)
        run["documents"] = [{"name": "Untitled", "text": "hello"}]
        result = report.analyze_run(run, scenario(), common.read_clock(BH1 / "speech-clock.tsv"))
        self.assertEqual(result["forbidden"]["success_without_effect"], 0)

    def test_the_verdict_fails_on_a_miss_and_names_the_forbidden_events(self):
        verdict = report.summarize([self.result], scenario())
        self.assertFalse(verdict["pass"])
        self.assertIn("hello misses its budget", verdict["reasons"])
        self.assertIn("take_split in 1/1 runs", verdict["reasons"])
        self.assertTrue(verdict["expectations"]["open"]["pass"])
        self.assertFalse(verdict["expectations"]["hello"]["pass"])
        self.assertEqual(verdict["forbidden"]["success_without_effect"]["rate"], 1.0)

    def test_a_clean_run_passes(self):
        clean = {"name": "r", "errors": [], "icloud_files": [], "expect": {k: {"latency_ms": ms} for k, ms in (("open", 100), ("new_doc", 650), ("hello", -20))},
                 "forbidden": {k: 0 for k in common.FORBIDDEN_EVENTS}}
        verdict = report.summarize([clean, clean], scenario())
        self.assertTrue(verdict["pass"], verdict["reasons"])

    def test_write_produces_a_report_and_a_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scenario.json").write_text(SCENARIO.read_text())
            (root / "speech-clock.tsv").write_text((BH1 / "speech-clock.tsv").read_text())
            run = root / "run-01"
            run.mkdir()
            for item in BH1.iterdir():
                if item.name not in ("scenario.json", "speech-clock.tsv"):
                    (run / item.name).write_text(item.read_text())
            with contextlib.redirect_stdout(io.StringIO()):
                verdict = report.write(root)
            self.assertFalse(verdict["pass"])
            self.assertIn("| take_split | 1/1 |", (root / "report.md").read_text())
            self.assertEqual(json.loads((root / "verdict.json").read_text())["runs"], 1)


if __name__ == "__main__":
    unittest.main()
