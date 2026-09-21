# Superkeet verification map

This directory is the maintained source for verifying the user-facing behavior of Superkeet. Read the index before driving the app, then use the matching feature file as the recipe.

## Baseline preconditions

- macOS 14 or later, Apple Silicon.
- Superkeet is launched only by `control-superkeet launch` from this skill.
- `control-superkeet doctor` reports a verify-owned pid, the launched bundle, Accessibility reachability, and a visible menu-bar extra.
- Never drive `/Applications/Superkeet.app` (or any other copy) if this run did not start it.
- Do not run `./install.sh` during a verify pass.
- Put `control-superkeet` on `PATH` or invoke `.cursor/skills/verify-superkeet/scripts/control-superkeet`.
- Artifact root is `.cursor/skills/verify-superkeet/artifacts/`. Cleanup must not delete it.

## Driving conventions

- Start every recipe from the baseline unless its preconditions say otherwise.
- Prefer AX names and exact menu titles over coordinates.
- Treat every command as literal. Keep quoted titles unchanged, including `Settings...` (ASCII dots) and `Run an Action…` (unicode ellipsis).
- Close windows you open before starting another feature, unless the recipe says to keep them.
- Restore any setting you change. Prefer recipes that do not change settings.

## Proof and skip reporting

- Capture the user action and the resulting state, not only the final screen.
- Window proof includes an AX snapshot and a screenshot with Superkeet identity visible.
- Menu proof includes `menu dump` output with the expected titles.
- Mutation proof includes a second read of the same UI after leaving and returning.
- Record the feature ID and entry point used with every artifact.
- Report an unreachable path with the attempted command and the unmet precondition.
- Do not report a skipped entry point as verified through a different path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the user-visible behavior. It then uses exactly four H2 sections in this order.

1. `Sub-features` lists short IDs with one line for each behavior.
2. `How to get to it (user POV)` lists every user entry point.
3. `Driving it with control-superkeet` starts with `Preconditions:` and uses labeled bullets that pair each user action with an exact command and observable result.
4. `Gotchas` lists traps that can waste or invalidate a verification run.

Keep implementation details out of the map. Name only user paths, stable handles, required state, commands, and observable proof.

## Features

- [Menu bar](./menu-bar.md) covers the status-item menu, recording controls, recovery items, and quit.
- [Settings](./settings.md) covers opening Settings and switching General, Output & Privacy, Advanced, About, and Actions.
- [History](./history.md) covers the history window, search, empty states, and copy.
- [Setup](./setup.md) covers first-run and Run Setup Again.
- [Recording](./recording.md) covers starting and stopping a take from the menu and the overlay outcomes.
