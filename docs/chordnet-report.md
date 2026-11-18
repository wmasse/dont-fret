# ChordNet prototype: neural chords vs the template engine

Branch `neural-chords`. ChordNet is a CNN + bidirectional GRU (1.3 M parameters, 5 MB Core ML, float32)
that reads a log-frequency spectrogram. Its per-beat chord probabilities replace the template scores in
`Transcriber.viterbi`; beats, key estimate, meter and sections are unchanged. It is off by default (the
`chordNet` user default or `DONTFRET_CHORDNET=1`). Pipeline and how to rerun everything:
`scripts/chordnet/README.md`.

**Recommendation: don't ship it as the default yet.** It clearly beats the templates on held-out audio
like its training data. On the real store previews the gain is small (+2 points), uneven from song to song,
and the key and chart results get slightly worse. Keep the flag and the code; the next step is better
training data (below).

## Results

### Real-song bench (`DONTFRET_CHORDNET=1 build/selftest --chart-bench`, 11 previews with a well-matched chart, 586 beats)

| | Templates | ChordNet |
|---|---|---|
| right chord, beat by beat | 70% | 72% |
| right root | 72% | 74% |
| right chord within a beat | 78% | 80% |
| key right, preview only | 13/15 | 12/15 |
| key right, what you get (chart + audio) | 12/15 | 11/15 |
| whole song (chart used) | 13/15 | 12/15 |

The ChordNet column is scored against the chart as the template run lines it up, so both use the same
reference; with the chart lined up by its own run the numbers are identical (72 / 74 / 80). Per song,
right chord:

| Song | Templates | ChordNet |
|---|---|---|
| Someone Like You | 43% | 77% |
| Stand By Me | 72% | 85% |
| Knockin' On Heaven's Door | 89% | 100% |
| Let It Be | 80% | 83% |
| Brown Eyed Girl | 63% | 64% |
| I'm Yours | 100% | 100% |
| A Horse With No Name | 61% | 56% |
| Zombie | 74% | 67% |
| Sweet Home Alabama | 69% | 59% |
| Take Me Home, Country Roads | 71% | 59% |
| Wonderwall | 39% | 27% |

5 songs better, 5 worse, 1 the same. The +2 points come mostly from three songs. On 11 songs that isn't
evidence of a real improvement, and the charts are crowd-made, so some "errors" on both sides are the
chart's. What it fixes: the neighbour-chord confusions the templates make on full-band mixes (F#→F#m and
C#m→E on Someone Like You, D→F#m and A→E on Stand By Me, Am→Em on Knockin'). What it breaks:
- Wonderwall (sus/add chords over a drone) comes out in E major instead of F# minor, and its chart then
  lines up in that key.
- Country Roads and Sweet Home Alabama lose some vi and IV chords to I.
- Smells Like Teen Spirit's chart drops from Medium to Poor. The chart-fit ratio divides by how well the
  transcriber's own chords fit the chroma templates, and ChordNet's chords fit them less tightly. So that
  song loses its whole-song chart.

The key regressions come from `refineKey`, which weighs the chords on the path heavily.

### Held-out split of the training sources (`build/selftest --chordnet-eval`, full Transcriber, beat by beat)

| | Templates | ChordNet |
|---|---|---|
| GuitarSet, 60 held-out excerpts (progression 3 of each style, all players), right chord | 77.1% | 81.6% |
| GuitarSet within a beat | 82.4% | 86.6% |
| GuitarSet key exact | 49/60 | 57/60 |
| Synthetic band mixes, 150 held-out songs, right chord | 87.7% | 96.1%* |
| Synthetic key exact | 96/150 | 102/150* |

\* at the earlier default emission scale 1.0 (GuitarSet at 1.0: 79.9%).

Every GuitarSet player plays the same 30 lead sheets, so holding out a player leaks the progressions.
Whole progressions are held out instead. The synthetic songs come from the same generator as the training
songs, so that row mostly shows the model learned the task, not that it generalises.

### Other checks

- Full `build/selftest` with ChordNet on: the "auto chords from a full mix" block is unchanged (tempo, key and
  meter 100%, bars 92%, progressions 100%), and no check fails. The mic-detection, melody and sound
  numbers that differ between runs come from the tests' random generators, not ChordNet (they don't use it).
- Swift and Python features match exactly at 44.1 kHz (`parity.py`), and to within 0.007 for 48 kHz input
  (AVAudioConverter vs soxr). The Core ML model matches PyTorch to 1e-3 log-prob, and the argmax is identical.
- macOS 14 build: the target stays macOS 14. The model needs only Core ML on macOS 14; without the model or
  the flag the template path runs unchanged. An x86_64 typecheck passes (no Float16).
- Cost: one extra 16k-point FFT pass plus the network per analysis. Not timed carefully: the Mac was
  under heavy load (a system install) during the final runs.

## How it was trained

- GuitarSet comp excerpts (CC BY 4.0), lead-sheet chords mapped to major/minor; 7ths count as their triad,
  and hdim/sus are ignored in the loss.
- 2,500 synthetic songs (21.6 h) from `build/selftest --chordnet-synth`: the app's guitar engine (acoustic,
  clean, drive; strums, picking, power chords, reggae), additive piano and pad, bass lines with inversions,
  drums, a formant-synth lead singing scale and chord tones; all 12 keys, major and minor, 60–170 BPM,
  tuning offsets, 7th/sus/add9/6/dim colours.
- Augmentation: transposition −5…+6 semitones in the spectrogram, ±20 cent shifts, masking. 6,000 steps
  on MPS (~40 min), half the crops from GuitarSet. The checkpoint was chosen on held-out GuitarSet. The
  first run, which drew 70% of crops from the synthetic songs, kept improving on synthetic songs and stalled
  on real guitar.
- Viterbi weights (`CHORDNET_SCALE` 1.6, `CHORDNET_KEY` 0.5) were picked on held-out GuitarSet only. The
  bench was run with the defaults, never tuned on.

## What would make it shippable

1. **More realistic training audio.** The model is very good on audio like what it trained on (+8 points on
   synthetic songs, +4.5 on held-out real guitar), but real produced mixes are still a different domain.
   Slakh2100 (CC BY 4.0, MIDI rendered with professional sample libraries, exact chord labels from MIDI) is the
   obvious next source. It is a single 104 GB download (shuffled, so no partial download), so it needs your
   OK. Licensing note: Slakh and Lakh render MIDI transcriptions of copyrighted songs. The audio is free to
   use, but the compositions aren't, so check that before training a commercial model on them.
2. **Combine instead of replace.** Add the template and network scores, measured on held-out data first;
   the songs it loses are ones where the templates were right.
3. **Key and chart gating.** Compute `refineKey` and the chart-fit ratio from the template path (or the
   chroma) even when ChordNet is on, so the chords can improve without moving the key or dropping charts.
4. **A bigger real-song benchmark.** 11 songs can't separate a 2-point change from noise. The per-song
   swings here are ±10–30 points.

`scripts/release.sh` and `scripts/appstore.sh` don't bundle the model yet (only `build.sh` does), so those
builds fall back to templates.
