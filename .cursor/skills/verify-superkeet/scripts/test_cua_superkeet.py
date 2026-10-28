import copy
import json
import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cua_superkeet as cua  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")

# Width in pixels of the screenshot that a real get_window_state returns for an 800 point window.
SCREENSHOT_WIDTH_PX = 1568
BOUNDS = {"x": 500, "y": 200, "width": 800, "height": 648}
SETTINGS_ID, HISTORY_ID, OVERLAY_ID = 11, 12, 13


def load(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
        return json.load(handle)


def window(window_id, title="", width=800, height=648, on_screen=True, z_index=None):
    return {
        "window_id": window_id,
        "title": title,
        "bounds": {"x": 0, "y": 0, "width": width, "height": height},
        "is_on_screen": on_screen,
        "z_index": z_index,
    }


class WindowSelectionTests(unittest.TestCase):
    def setUp(self):
        self.windows = load("list_windows-settings-history-overlay.json")["windows"]

    def test_default_pick_ignores_offscreen_overlay_with_highest_z(self):
        self.assertEqual(cua.pick_window(self.windows)["window_id"], SETTINGS_ID)

    def test_history_surface_picks_the_history_window(self):
        self.assertEqual(cua.pick_window(self.windows, surface="history")["window_id"], HISTORY_ID)

    def test_settings_surface_skips_the_untitled_offscreen_overlay(self):
        self.assertEqual(cua.pick_window(self.windows, surface="settings")["window_id"], SETTINGS_ID)

    def test_setup_surface_is_absent_when_setup_is_closed(self):
        self.assertIsNone(cua.pick_window(self.windows, surface="setup"))

    def test_title_names_a_window_exactly(self):
        self.assertEqual(cua.pick_window(self.windows, title="Superkeet - History")["window_id"], HISTORY_ID)
        self.assertIsNone(cua.pick_window(self.windows, title="Superkeet - history"))

    def test_offscreen_windows_never_qualify(self):
        self.assertIsNone(cua.pick_window([window(7, on_screen=False, z_index=99)]))

    def test_area_beats_z_order(self):
        windows = [window(1, width=480, height=548, z_index=90), window(2, width=800, height=648, z_index=3)]
        self.assertEqual(cua.pick_window(windows)["window_id"], 2)

    def test_z_order_breaks_equal_area_ties(self):
        windows = [window(1, z_index=4), window(2, z_index=9)]
        self.assertEqual(cua.pick_window(windows)["window_id"], 2)

    def test_null_z_order_does_not_depend_on_array_order(self):
        windows = [window(12), window(5), window(9)]
        forward = cua.pick_window(windows)["window_id"]
        backward = cua.pick_window(list(reversed(windows)))["window_id"]
        self.assertEqual(forward, backward)
        self.assertEqual(forward, 5)


class WindowStateTests(unittest.TestCase):
    def test_general_tree_names_its_sections(self):
        text = cua.tree_text(load("get_window_state-settings-general.json"))
        self.assertIn('AXStaticText = "General"', text)
        self.assertTrue(cua.tree_has_name(text, "Setup Checklist"))
        self.assertFalse(cua.tree_has_name(text, "Diagnostic details"))

    def test_advanced_tree_names_the_troubleshooting_disclosure(self):
        text = cua.tree_text(load("get_window_state-settings-advanced-collapsed.json"))
        self.assertTrue(cua.tree_has_name(text, "Troubleshooting"))
        self.assertTrue(cua.tree_has_name(text, "Diagnostic details"))

    def test_degraded_offscreen_window_fails_instead_of_returning_empty_text(self):
        with self.assertRaises(SystemExit) as raised:
            cua.tree_text(load("get_window_state-overlay-degraded.json"))
        self.assertIn("ax_window_unresolved", str(raised.exception))


class DisclosureTests(unittest.TestCase):
    spec = cua.DISCLOSURES["Diagnostic details"]

    def advanced(self, expanded=False):
        name = "get_window_state-settings-advanced-expanded.json" if expanded else "get_window_state-settings-advanced-collapsed.json"
        return load(name)

    def test_collapsed_tree_reads_as_closed(self):
        text = cua.tree_text(self.advanced())
        self.assertFalse(cua.disclosure_open(text, self.spec))

    def test_expanded_tree_reads_as_open(self):
        text = cua.tree_text(self.advanced(expanded=True))
        self.assertTrue(cua.disclosure_open(text, self.spec))

    def test_aim_point_is_measured_from_the_refresh_frame(self):
        data = self.advanced()
        point, reason = cua.disclosure_check(cua.tree_text(data), data["elements"], self.spec, BOUNDS)
        self.assertIsNone(reason)
        # Refresh frame (900, 600) plus (3.6, 38) is screen (903.6, 638). Window origin is (500, 200).
        self.assertEqual(point, (403.6, 438.0))

    def test_aim_point_converts_to_the_recorded_click_pixel(self):
        data = self.advanced()
        point, _ = cua.disclosure_check(cua.tree_text(data), data["elements"], self.spec, BOUNDS)
        scale = SCREENSHOT_WIDTH_PX / BOUNDS["width"]
        # 403.6 * 1.96 = 791.056 and 438.0 * 1.96 = 858.48.
        self.assertEqual((round(point[0] * scale), round(point[1] * scale)), (791, 858))

    def test_triangle_near_the_bottom_edge_is_scrolled_into_view(self):
        self.assertEqual(cua.disclosure_scroll_direction(645.0, 648), "down")
        self.assertEqual(cua.disclosure_scroll_direction(BOUNDS["height"] - 8, BOUNDS["height"]), None)
        self.assertEqual(cua.disclosure_scroll_direction(7.9, 648), "up")
        self.assertIsNone(cua.disclosure_scroll_direction(8.0, 648))

    def test_refuses_when_the_label_is_not_in_the_troubleshooting_section(self):
        data = self.advanced()
        text = cua.tree_text(data).replace("AXDisclosureTriangle (Diagnostic details)", "AXStaticText = \"Other\"")
        point, reason = cua.disclosure_check(text, data["elements"], self.spec, BOUNDS)
        self.assertIsNone(point)
        self.assertIn("Diagnostic details", reason)

    def test_refuses_when_the_troubleshooting_heading_is_missing(self):
        data = self.advanced()
        text = cua.tree_text(data).replace("AXHeading (Troubleshooting)", "AXStaticText = \"Other\"")
        point, reason = cua.disclosure_check(text, data["elements"], self.spec, BOUNDS)
        self.assertIsNone(point)
        self.assertIn("Troubleshooting", reason)

    def test_refuses_when_refresh_is_not_in_a_button_row(self):
        data = self.advanced()
        lone = [e for e in data["elements"] if e.get("label") in (None, "Refresh")]
        point, reason = cua.disclosure_check(cua.tree_text(data), lone, self.spec, BOUNDS)
        self.assertIsNone(point)
        self.assertIn("row of buttons", reason)

    def test_refuses_when_another_control_covers_the_aim_point(self):
        data = self.advanced()
        elements = copy.deepcopy(data["elements"])
        elements.append({
            "element_index": 30,
            "element_token": "s00000001:30",
            "role": "AXButton",
            "label": "Other",
            "actions": ["AXPress"],
            "frame": {"x": 890.0, "y": 630.0, "w": 40.0, "h": 16.0},
        })
        point, reason = cua.disclosure_check(cua.tree_text(data), elements, self.spec, BOUNDS)
        self.assertIsNone(point)
        self.assertIn("Other", reason)


class FixturePrivacyTests(unittest.TestCase):
    FORBIDDEN = [
        re.compile(r"Log Out"),
        re.compile(r"Recent"),
        re.compile(r"/Users"),
        re.compile(r"/private"),
        re.compile(r"Microphone"),
        re.compile(r"\d+ words"),
        re.compile(r"\d+ WPM"),
    ]

    def test_fixtures_hold_no_personal_or_machine_text(self):
        for name in sorted(os.listdir(FIXTURES)):
            with open(os.path.join(FIXTURES, name), encoding="utf-8") as handle:
                content = handle.read()
            for pattern in self.FORBIDDEN:
                self.assertIsNone(pattern.search(content), f"{name} matches {pattern.pattern!r}")


if __name__ == "__main__":
    unittest.main()
