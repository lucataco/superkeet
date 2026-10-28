# History

History lets users browse saved transcriptions, search them, and copy a saved result. Its empty state distinguishes disabled history from an empty enabled history.

## Sub-features

- `history-open` opens History from the status-item menu.
- `history-empty-off` shows the disabled-history explanation.
- `history-empty-on` shows an enabled history with no records.
- `history-search` filters existing records and shows a search miss.
- `history-copy` copies a selected record through the user interface.

## How to get to it (user POV)

- Choose `History` in the Superkeet menu.
- Use the menu's History keyboard equivalent.
- Copy a row with its UI copy action, double-click, or the copy shortcut.

## Driving it with control-superkeet

Preconditions:

- Complete Launch and Doctor. Do not alter Save History or clear records to prepare a test.
- Existing transcripts may be private. Keep snapshots local and do not publish their contents.

1. Choose History through the real menu. System Events uses `"$CONTROL" menu click "History"`. CuaDriver uses the fresh-screenshot entry procedure.
2. Wait until `"$CONTROL" windows` lists `Superkeet - History`. Check the `History` label with `exists --name`. Add `--surface history` only for CuaDriver.
3. Save `$EVIDENCE/history.ax.txt` and `$EVIDENCE/history.png`. Use `snapshot --surface history` and `screenshot --surface history` under CuaDriver. Under System Events, use plain snapshot/screenshot commands while History is the sole window.
4. If history is off, assert `History is off`, `Turn it on to keep future transcriptions on this Mac.`, and `Turn On History` in the AX tree. Do not press the button.
5. If history is enabled but empty, assert `No transcriptions yet`. Do not claim the disabled state in the same proof.
6. If records exist, assert `Search transcriptions…` and the visible records. Do not click `Clear All` or copy private text merely to complete an inspection.
7. Mark search, row-copy, and keyboard-entry journeys BLOCKED unless a disposable transcript fixture and a driver supporting text entry, row selection, and clipboard observation are supplied. The current wrapper does not implement those operations. Prove a search miss and matching clipboard content before marking those IDs verified.
8. Close History with `close-window --title "Superkeet - History"` under System Events or `close-window --window "Superkeet - History"` under CuaDriver. Confirm the window disappears.

## Gotchas

- History uses `~/Library/Application Support/Superkeet/history.json`. Never remove or rewrite it to manufacture a fixture.
- `Clear All` deletes records. It is outside this inspection journey.
- `Turn On History` changes the real profile. Do not use it as setup.
- A missing fixture is a failed precondition for search/copy, not permission to claim those features from an empty-state screenshot.
- Opening History through the menu does not verify its keyboard equivalent.
