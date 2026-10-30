`bh1/` is the first BlackHole run from the 2026-10-29 spike, in the shape `run.py` writes.

- `observer.ndjson` is the spike observer's output, unchanged. It predates the rig's event format, so `report.py` also accepts `target_frontmost` and `target_windows` events without a bundle.
- `log.ndjson` is the spike's `log stream` capture reduced to `timestamp`, `category`, and `eventMessage`.
- `speech-clock.tsv` is the WhisperX alignment of that run's stimulus.
- `audit.ndjson` holds the three audit rows that run wrote.
- `documents.json` is reconstructed, not recorded. The spike found the TextEdit document empty after `type_text` reported success.

`planner-guard/` is run 2 of a five-run batch on the final rig, recorded as the rig writes it. The take split, the planner started, and the rig cancelled the app with Escape. `log.ndjson` is reduced the same way as above. Nothing else was changed.
