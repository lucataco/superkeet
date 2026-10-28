#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time

CALL_TIMEOUT_SECONDS = 45
MAX_SCROLLS = 6
EDGE_PT = 8.0
TOLERANCE_PT = 2.0
INDEX_RE = re.compile(r"\[(\d+)\]")
NON_TARGET_ROLES = {"AXWindow", "AXOutline", "AXScrollArea", "AXScrollBar", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem"}
SURFACES = {
    # Settings has a hidden titlebar, so its title is empty.
    "settings": "",
    "history": "Superkeet - History",
    "setup": "Superkeet Setup",
}
DISCLOSURES = {
    # CuaDriver gives the disclosure triangle no element index and no frame, so its point is
    # measured from the "Refresh" button above it. dx and dy are points from that button's
    # top-left frame corner.
    "Diagnostic details": {
        "section": "Troubleshooting",
        "label": "Diagnostic details",
        "anchor": "Refresh",
        "dx": 3.6,
        "dy": 38.0,
        "open_markers": ('AXStaticText = "Status:', 'AXStaticText = "Diagnostics:'),
    },
}


def fail(message):
    raise SystemExit(f"control-superkeet (cua): {message}")


def call(tool, payload):
    try:
        result = subprocess.run(
            ["cua-driver", "call", tool, json.dumps(payload)],
            text=True,
            capture_output=True,
            check=False,
            timeout=CALL_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        fail(f"{tool} did not return within {CALL_TIMEOUT_SECONDS}s")
    if result.returncode != 0:
        fail(result.stderr.strip() or f"cua-driver {tool} exited {result.returncode}")
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        fail(f"cua-driver {tool} returned non-JSON output: {result.stdout[:300]}")
    if data.get("status") == "refused" or data.get("effect") == "refused" or "refusal" in data:
        fail(f"{tool} refused: {json.dumps(data, ensure_ascii=False)}")
    return data


def windows(pid):
    return call("list_windows", {"pid": pid}).get("windows", [])


def window_area(window):
    bounds = window.get("bounds") or {}
    return float(bounds.get("width", 0)) * float(bounds.get("height", 0))


def z_rank(window):
    z = window.get("z_index")
    return z if isinstance(z, int) else -1


def pick_window(candidates, title=None, surface=None):
    # Offscreen panels can carry the highest z_index, so only on-screen windows qualify.
    # z_index only breaks ties, and a null z_index ranks lowest, so array order never decides.
    eligible = [w for w in candidates if w.get("is_on_screen") is True and window_area(w) > 0]
    if title is not None:
        eligible = [w for w in eligible if (w.get("title") or "") == title]
    elif surface is not None:
        expected = SURFACES[surface]
        eligible = [w for w in eligible if (w.get("title") or "") == expected]
    if not eligible:
        return None
    return max(eligible, key=lambda w: (window_area(w), z_rank(w), -int(w.get("window_id", 0))))


def select_window(pid, title=None, surface=None):
    window = pick_window(windows(pid), title, surface)
    if window is None:
        if title is not None:
            wanted = f"titled {title!r}"
        elif surface is not None:
            wanted = f"for surface {surface!r}"
        else:
            wanted = "on screen"
        fail(f"no Superkeet window {wanted}; run windows, then open that window from the menu")
    return window


def describe(window):
    bounds = window.get("bounds", {})
    return (
        f"window {window.get('window_id')} {window.get('title', '')!r} "
        f"{bounds.get('width')}x{bounds.get('height')}"
    )


def tree_text(data):
    text = data.get("tree_markdown")
    if isinstance(text, str) and text.strip():
        return text
    reason = data.get("degraded_reason") or "no tree_markdown in the response"
    fail(f"window {data.get('window_id')} returned no accessibility tree: {reason[:240]}")


def snapshot(pid, title=None, surface=None):
    window = select_window(pid, title, surface)
    data = call(
        "get_window_state",
        {
            "pid": pid,
            "window_id": window["window_id"],
            "include_screenshot": False,
        },
    )
    tree_text(data)
    return window, data


def write_snapshot(pid, path, title=None, surface=None):
    window, data = snapshot(pid, title, surface)
    text = tree_text(data)
    if path:
        destination = Path(path).expanduser().resolve()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(text + "\n", encoding="utf-8")
        print(f"wrote {destination} from {describe(window)}")
    else:
        print(text)


def tree_has_name(text, name):
    return f'"{name}"' in text or f"({name})" in text


def exists(pid, name, title=None, surface=None):
    _, data = snapshot(pid, title, surface)
    found = tree_has_name(tree_text(data), name)
    print("yes" if found else "no")
    if not found:
        raise SystemExit(1)


def click(pid, name=None, row=None, title=None, surface=None):
    if row is not None and title is None and surface is None:
        surface = "settings"
    window, data = snapshot(pid, title, surface)
    elements = data.get("elements", [])
    if row is not None:
        rows = [element for element in elements if element.get("role") == "AXRow"]
        if row < 1 or row > len(rows):
            fail(f"sidebar row {row} is out of range; found {len(rows)} rows")
        element = rows[row - 1]
    else:
        matches = [
            element
            for element in elements
            if element.get("label") == name and element.get("element_token")
        ]
        if len(matches) != 1:
            fail(f"expected one actionable element named {name!r}; found {len(matches)}")
        element = matches[0]
    result = call(
        "click",
        {
            "pid": pid,
            "window_id": window["window_id"],
            "element_token": element["element_token"],
        },
    )
    print(json.dumps(result, ensure_ascii=False))


def disclosure_open(text, spec):
    return any(marker in text for marker in spec["open_markers"])


def section_span(lines, heading):
    marker = f"AXHeading ({heading})"
    start = next((i for i, line in enumerate(lines) if marker in line), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if "AXHeading (" in lines[i]), len(lines))
    return start + 1, end


def section_indexes(lines, span):
    first, last = span
    return {int(match.group(1)) for line in lines[first:last] for match in INDEX_RE.finditer(line)}


def covers(frame, x, y):
    return (
        frame["x"] - TOLERANCE_PT <= x <= frame["x"] + frame["w"] + TOLERANCE_PT
        and frame["y"] - TOLERANCE_PT <= y <= frame["y"] + frame["h"] + TOLERANCE_PT
    )


def disclosure_check(text, elements, spec, bounds):
    """Return (window_point, None) when the aim is safe, or (None, reason) to refuse the click.

    The window point is in points, measured from the window's top-left corner.
    """
    lines = text.split("\n")
    span = section_span(lines, spec["section"])
    if span is None:
        return None, f"no {spec['section']} section in the tree"
    first, last = span
    if not any(f"AXDisclosureTriangle ({spec['label']})" in line for line in lines[first:last]):
        return None, f"{spec['label']!r} is not in the {spec['section']} section"
    by_index = {element.get("element_index"): element for element in elements}
    in_section = [
        by_index[index]
        for index in section_indexes(lines, span)
        if index in by_index and by_index[index].get("frame")
    ]
    anchors = [
        element
        for element in in_section
        if element.get("role") == "AXButton" and element.get("label") == spec["anchor"]
    ]
    if not anchors:
        return None, f"no {spec['anchor']!r} button in the {spec['section']} section"
    anchor_frame = anchors[0]["frame"]
    row = [
        element
        for element in in_section
        if element.get("role") == "AXButton" and abs(element["frame"]["y"] - anchor_frame["y"]) <= TOLERANCE_PT
    ]
    if len(row) < 2:
        return None, f"{spec['anchor']!r} is not in a row of buttons"
    screen_x = anchor_frame["x"] + spec["dx"]
    screen_y = anchor_frame["y"] + spec["dy"]
    for element in elements:
        frame = element.get("frame")
        if not frame or element.get("role") in NON_TARGET_ROLES:
            continue
        if covers(frame, screen_x, screen_y):
            label = element.get("label") or element.get("role")
            return None, f"the aim point would land on {label!r}"
    return (screen_x - bounds["x"], screen_y - bounds["y"]), None


def disclosure_scroll_direction(y_pt, height):
    """Return the scroll that brings the triangle inside the window, or None when it is visible."""
    if y_pt < EDGE_PT:
        return "up"
    if y_pt > height - EDGE_PT:
        return "down"
    return None


def expand(pid, name, title=None, surface=None):
    spec = DISCLOSURES.get(name)
    if spec is None:
        fail(f"no known disclosure {name!r}; known: {', '.join(sorted(DISCLOSURES))}")
    window = select_window(pid, title, None if title is not None else (surface or "settings"))
    window_id = window["window_id"]
    bounds = window["bounds"]
    height = bounds["height"]
    with tempfile.TemporaryDirectory() as scratch:
        shot = Path(scratch) / "window.png"
        for _ in range(MAX_SCROLLS + 1):
            data = call(
                "get_window_state",
                {"pid": pid, "window_id": window_id, "screenshot_out_file": str(shot)},
            )
            text = tree_text(data)
            if disclosure_open(text, spec):
                print(f"{name} already expanded in {describe(window)}")
                return
            width_px = data.get("screenshot_width")
            if not width_px:
                fail(f"no screenshot size for {describe(window)}; cannot aim a pixel click")
            scale = width_px / bounds["width"]
            point, reason = disclosure_check(text, data.get("elements", []), spec, bounds)
            if reason:
                fail(f"refusing to click {name} in {describe(window)}: {reason}. Nothing was clicked.")
            x_pt, y_pt = point
            direction = disclosure_scroll_direction(y_pt, height)
            if direction is None:
                break
            call(
                "scroll",
                {
                    "pid": pid,
                    "window_id": window_id,
                    "x": round(bounds["width"] * 0.6 * scale),
                    "y": round(height * 0.5 * scale),
                    "direction": direction,
                    "amount": 5,
                    "by": "page",
                },
            )
        else:
            fail(f"could not scroll {name} into view in {describe(window)}")

    call(
        "click",
        {
            "pid": pid,
            "window_id": window_id,
            "x": round(x_pt * scale),
            "y": round(y_pt * scale),
            "delivery_mode": "foreground",
        },
    )
    for _ in range(8):
        time.sleep(0.25)
        after = call("get_window_state", {"pid": pid, "window_id": window_id, "include_screenshot": False})
        if disclosure_open(tree_text(after), spec):
            print(f"expanded {name} in {describe(window)}")
            return
    fail(f"clicked {name} at window point ({x_pt:.1f}, {y_pt:.1f}) but it did not expand")


def screenshot(pid, path, title=None, surface=None):
    window = select_window(pid, title, surface)
    destination = Path(path).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    result = call(
        "get_window_state",
        {
            "pid": pid,
            "window_id": window["window_id"],
            "include_accessibility_tree": False,
            "screenshot_out_file": str(destination),
        },
    )
    if not destination.is_file():
        fail(f"screenshot was not written: {json.dumps(result, ensure_ascii=False)}")
    print(f"wrote {destination} from {describe(window)}")


def close_window(pid, title=None, surface=None):
    window = select_window(pid, title, surface)
    result = call(
        "hotkey",
        {
            "pid": pid,
            "window_id": window["window_id"],
            "keys": ["cmd", "w"],
            "delivery_mode": "foreground",
        },
    )
    print(json.dumps(result, ensure_ascii=False))


def desktop_screenshot(path):
    destination = Path(path).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    result = call("get_desktop_state", {"screenshot_out_file": str(destination)})
    if not destination.is_file():
        fail(f"desktop screenshot was not written: {json.dumps(result, ensure_ascii=False)}")
    print(f"wrote {destination}")


def desktop_click(x, y):
    result = call("click", {"scope": "desktop", "x": x, "y": y})
    print(json.dumps(result, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command")
    parser.add_argument("--pid", type=int, required=False)
    parser.add_argument("--path")
    selector = parser.add_mutually_exclusive_group()
    selector.add_argument("--window", "--title", dest="window")
    selector.add_argument("--surface", choices=sorted(SURFACES))
    parser.add_argument("--name")
    parser.add_argument("--row", type=int)
    parser.add_argument("--x", type=float)
    parser.add_argument("--y", type=float)
    args = parser.parse_args()

    if args.command == "desktop-screenshot":
        if not args.path:
            fail("desktop-screenshot requires --path")
        desktop_screenshot(args.path)
        return
    if args.command == "desktop-click":
        if args.x is None or args.y is None:
            fail("desktop-click requires --x and --y in native screenshot pixels")
        desktop_click(args.x, args.y)
        return
    if not args.pid:
        fail("this command requires --pid")

    if args.command == "windows":
        found = windows(args.pid)
        if not found:
            print("(no windows)")
        for window in found:
            bounds = window.get("bounds", {})
            print(
                f"{window.get('window_id')}\t{window.get('title', '')!r}\t"
                f"{bounds.get('x')},{bounds.get('y')}\t"
                f"{bounds.get('width')}x{bounds.get('height')}\t"
                f"on_screen={window.get('is_on_screen')}\tz={window.get('z_index')}"
            )
    elif args.command == "snapshot":
        write_snapshot(args.pid, args.path, args.window, args.surface)
    elif args.command == "exists":
        if not args.name:
            fail("exists requires --name")
        exists(args.pid, args.name, args.window, args.surface)
    elif args.command == "click":
        if args.row is None and not args.name:
            fail("click requires --name or --row")
        click(args.pid, args.name, args.row, args.window, args.surface)
    elif args.command == "expand":
        if not args.name:
            fail("expand requires --name, for example --name \"Diagnostic details\"")
        expand(args.pid, args.name, args.window, args.surface)
    elif args.command == "screenshot":
        if not args.path:
            fail("screenshot requires --path")
        screenshot(args.pid, args.path, args.window, args.surface)
    elif args.command == "close-window":
        close_window(args.pid, args.window, args.surface)
    else:
        fail(f"unknown command: {args.command}")


if __name__ == "__main__":
    main()
