# History

History lets a user browse saved transcriptions, search them, copy a row, and see a clear empty state when history is off or empty.

## Sub-features

- `history-open` opens the History window from the menu.
- `history-empty-off` shows `History is off` when Save History is disabled.
- `history-empty-on` shows `No transcriptions yet` when Save History is on and the list is empty.
- `history-search` filters rows from `Search transcriptions...` and shows `No results found` when nothing matches.
- `history-copy` copies a row via double-click, ⌘C, or `Copy Text`.

## How to get to it (user POV)

- Choose `History` in the Superkeet menu.
- Press `h` while the Superkeet menu is open.

## Driving it with control-superkeet

Preconditions:

- `control-superkeet doctor` is clean.
- Do not enable or disable `Save History` unless you restore it afterward.

- **Open History.** Choose `History`. Run `control-superkeet menu click "History"`. `control-superkeet windows` lists a window titled `Superkeet - History`.
- **Identity.** Run `control-superkeet exists --name "History"`. Exit 0. The heading `History` is visible.
- **Empty, history off.** If the snapshot contains `History is off`, it also contains `Turn on Save History in Settings > Output & Privacy`. No `Clear All` button.
- **Empty, history on.** If the snapshot contains `No transcriptions yet`, it also mentions the menu bar or the toggle-recording shortcut. No rows.
- **Populated.** If rows exist, a search field named `Search transcriptions...` is present. `Clear All` exists. Do not click `Clear All`.
- **Search miss.** When rows exist, type a string that cannot match (use the search field only if you can clear it). The empty title becomes `No results found`. Clear the query afterward.
- **Proof.** Run `control-superkeet snapshot --path artifacts/history/window.ax.txt` and `control-superkeet screenshot --path artifacts/history/window.png --window "Superkeet - History"`. Both show `Superkeet - History` or the `History` heading.

## Gotchas

- This machine's real history file is `~/Library/Application Support/Superkeet/history.json`. Do not delete it to force an empty state.
- `Clear All` permanently deletes every record. Never use it in a verify run.
- Empty-state copy depends on `Save History`. Read the heading that is actually on screen; do not expect both empty states in one pass.
- The window title includes a space-hyphen-space: `Superkeet - History`.
