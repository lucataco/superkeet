# Audio preservation regression suite

No human recordings of the reported complaints were available. The checked-in
manifest is an exact test oracle; `audio_regression.py render` creates synthetic
WAV smoke fixtures with macOS `say` and records their voice, duration and SHA-256.
Synthetic results do not establish real-world microphone accuracy.

```bash
python3 scripts/audio_regression.py render --fixtures .build/audio-regression
python3 scripts/audio_regression.py run \
  --fixtures .build/audio-regression \
  --engine ../../Formulae/parakeet-cli/target/release/parakeet \
  --model-dir "$HOME/Library/Application Support/parakeet/models/parakeet-tdt-0.6b-v3" \
  --report .build/audio-regression/report.json
```

The runner exits nonzero for any missing/extra critical word, wrong answer count,
WER above 15%, failed segment or dropped sample. Number words five–eight and
digits are equivalent; **auth/off, er/err/or, negations and repetitions are not**.
Recognition complaints that remain unresolved stay failing cases.

`--session` uses the live engine's bounded segmenter, shared encoder context,
owned-frame decoding, VAD and immediate-stop tail finalization. Microphone callback
overflow and independent collection have deterministic Rust tests. File replay
does not test a physical microphone, device driver, Accessibility or paste focus.

## Add human recordings

Record mono PCM WAVs with the same case IDs in a separate local directory. Read
the manifest prompts naturally, including hesitations and repeated answers. Stop
immediately after “zebra”. For the long case, read the prompt sixty times over ten
minutes; additionally record continuous speech across the 25.6-second segment
boundaries. Keep an exact reference transcript and set `provenance` in a copied
manifest to speaker/device/rate/recording date (with speaker consent).

Pass `--fixtures /path/to/recordings --manifest /path/to/manifest.json`; `run` never
writes audio. Use `--case ID` to select cases. Keep recordings local unless speakers
explicitly agree to their inclusion in the repository. Playback/retry is a test
workflow; the app's persistent history remains opt-in and contains text only.
