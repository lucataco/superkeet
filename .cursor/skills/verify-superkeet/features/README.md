# Superkeet verification map

Read [the skill](../SKILL.md), select a feature, and record each entry point actually exercised. Use the existing `control-superkeet` helper. Do not treat a convenient entry point as proof of every path.

## Baseline preconditions

- Use macOS 14 or later on Apple Silicon with an unlocked graphical session.
- Launch the exact bundle through this run's fresh ownership directory. Refuse an existing app or engine owned by another run.
- Run `doctor` and the journey's own readiness checks. Driver access does not imply recording or Actions readiness.
- Use a disposable macOS account for mutations. Worktrees do not isolate defaults, history, runtime sockets, or desktop focus.
- Use `$CONTROL`, `$APP`, and `$EVIDENCE` from the skill's Launch section. All evidence paths below are under `$EVIDENCE` and survive cleanup.
- Follow the backend support table. CuaDriver supports `--surface`; most System Events commands do not.

## Driving conventions

- Prefer exact menu titles and AX handles. CuaDriver's status-item entry and guarded diagnostic disclosure are the documented coordinate exceptions.
- Wait for the expected window and label after each navigation action. Use the skill's retry-count bound. A driver call can take longer than the retry sleep, so this is not a ten-second elapsed-time guarantee. Abort stalled attempts and clean up.
- Keep only the intended window open under System Events. Under CuaDriver, select a surface and check its identity labels.
- Do not change permissions, settings, approval policy, MCP servers, history, or clipboard contents during an inspection journey.
- If a path needs missing data, a permission, an unsupported input command, or a disposable target, report it BLOCKED with the failed precondition. Do not substitute a weaker journey.
- Capture action output, before/after AX state, and screenshots. Record actual side effects for recording or action execution.
- Cleanup only owned processes. Keep evidence and confirm it still exists after teardown.

## Features

- [Menu bar](menu-bar.md) covers status, recording controls, window entries, and quit.
- [Settings](settings.md) covers General, Output & Privacy, Advanced, About, and Actions-tab visibility.
- [History](history.md) covers opening, empty states, search, and copy preconditions.
- [Setup](setup.md) covers first-run onboarding and the rerun entry.
- [Recording](recording.md) covers menu and shortcut entry points, cancellation, and transcript outcomes.
- [Actions Mode](actions.md) separates current Actions settings inspection from listening, approval, and execution proof.

## Maintain the map

Each feature has exactly four H2 sections, in this order. `Sub-features`, `How to get to it (user POV)`, `Driving it with control-superkeet`, and `Gotchas`.

Keep IDs stable. Add a concrete end-state assertion when adding a journey. Mark missing driver support explicitly rather than dropping the entry point. Use `/maintain-verification-skill` when the app changes.
