#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import subprocess


def fail(message):
    raise SystemExit(f"control-superkeet (cua): {message}")


def call(tool, payload):
    result = subprocess.run(
        ["cua-driver", "call", tool, json.dumps(payload)],
        text=True,
        capture_output=True,
        check=False,
    )
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


def select_window(pid, title=None):
    candidates = windows(pid)
    if title is not None:
        candidates = [window for window in candidates if window.get("title", "") == title]
    if not candidates:
        suffix = f" titled {title!r}" if title is not None else ""
        fail(f"no Superkeet window{suffix}; run windows and open the required feature first")
    return max(candidates, key=lambda window: window.get("z_index") or -1)


def snapshot(pid, title=None):
    window = select_window(pid, title)
    data = call(
        "get_window_state",
        {
            "pid": pid,
            "window_id": window["window_id"],
            "include_screenshot": False,
        },
    )
    return window, data


def write_snapshot(pid, path, title=None):
    _, data = snapshot(pid, title)
    tree = data.get("tree_markdown", "")
    if path:
        destination = Path(path).expanduser().resolve()
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(tree + "\n", encoding="utf-8")
        print(f"wrote {destination}")
    else:
        print(tree)


def exists(pid, name):
    _, data = snapshot(pid)
    tree = data.get("tree_markdown", "")
    found = f'"{name}"' in tree or f"({name})" in tree
    print("yes" if found else "no")
    if not found:
        raise SystemExit(1)


def click(pid, name=None, row=None):
    window, data = snapshot(pid)
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


def screenshot(pid, path, title=None):
    window = select_window(pid, title)
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
    print(f"wrote {destination}")


def close_window(pid, title=None):
    window = select_window(pid, title)
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
    parser.add_argument("--window", "--title", dest="window")
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
                f"{window.get('window_id')}\t{window.get('title', '')}\t"
                f"{bounds.get('x')},{bounds.get('y')}\t"
                f"{bounds.get('width')}x{bounds.get('height')}"
            )
    elif args.command == "snapshot":
        write_snapshot(args.pid, args.path, args.window)
    elif args.command == "exists":
        if not args.name:
            fail("exists requires --name")
        exists(args.pid, args.name)
    elif args.command == "click":
        if args.row is None and not args.name:
            fail("click requires --name or --row")
        click(args.pid, args.name, args.row)
    elif args.command == "screenshot":
        if not args.path:
            fail("screenshot requires --path")
        screenshot(args.pid, args.path, args.window)
    elif args.command == "close-window":
        close_window(args.pid, args.window)
    else:
        fail(f"unknown command: {args.command}")


if __name__ == "__main__":
    main()
