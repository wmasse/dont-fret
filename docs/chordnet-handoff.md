# Note for Jeremy's Claude: the `neural-chords` branch

Hi. Winston asked for this note so you can pick this work up without starting from scratch. It covers what
this branch is, where it stands, what not to do with it, and how it can help Don't Fret later. Full numbers
are in `docs/chordnet-report.md`, and the pipeline is in `scripts/chordnet/README.md`.

## What this branch is

**ChordNet** is a prototype neural chord recogniser for analysing recordings (Add Any Song, Listen While It
Plays, Choose Audio File). It is **not** used for live mic chord detection.

- **The model:** a small CNN with a bidirectional GRU (1.3 M parameters, 5 MB Core ML, float32). It reads a
  log-frequency spectrogram and outputs a probability for each of 24 major/minor chords, plus "no chord",
  21.5 times a second.
- **Where it plugs in:** `Transcriber.viterbi` takes an optional `net:` argument. When it's given, the
  network's per-beat log-probabilities replace the chroma-template scores. Beats, key, meter, bars and
  sections are worked out exactly as before.
- **The flag:** it's **off by default**. Turn it on with the `chordNet` user default or
  `DONTFRET_CHORDNET=1`. With the flag off, or without the model, the template path runs unchanged.
- **Files:**
  - `Sources/App/Analysis/ChordNet.swift`
  - `Resources/ChordNet.mlpackage`
  - `scripts/chordnet/`
  - `Tests/ChordNetData.swift` and `Tests/ChordNetEval.swift`
  - the `--chordnet-*` selftest flags
  - a model-compile step in `build.sh`
- **Base:** it's one commit (`026d9db`) on top of `fee82d7`. Main has moved on since, by one commit (heard
  lyrics, `9637e08`), which doesn't touch the chord code. A rebase or merge should be clean.

## Where it stands

| | Templates (main) | ChordNet |
|---|---|---|
| Real store previews, right chord beat by beat (11 songs, 586 beats) | 70% | 72% |
| Real store previews, key right | 13/15 | 12/15 |
| Held-out GuitarSet, right chord | 77% | 82% |
| Held-out GuitarSet, key exact | 49/60 | 57/60 |

It's clearly better on audio like its training data, but only slightly better on real produced mixes.

- **Uneven from song to song:** 5 songs improve, 5 get worse and 1 is the same. Someone Like You goes from
  43% to 77%, while Wonderwall drops from 39% to 27% and is read in the wrong key.
- **Key and chart regressions:** the key gets worse because `refineKey` leans on the chord path. One song,
  Smells Like Teen Spirit, loses its whole-song chart, because the chart-fit ratio is measured against the
  template fit.

**Recommendation from both Winston's session and the report: don't turn it on by default yet.**

## Please don't

- **Don't merge it into main or switch it on by default** without Winston and Jeremy agreeing. Keeping it
  behind the flag is deliberate.
- **Don't train on commercial recordings.** The 15 store previews in `build/bench` are only for measuring.
  The training data is GuitarSet (CC BY 4.0) plus synthetic songs from the app's own guitar engine.
- **Don't treat Slakh2100 as cleared for a commercial model.** The audio is CC BY 4.0, but it renders MIDI
  transcriptions of copyrighted songs, so check the licensing first. It's also a single 104 GB download.
- **Don't tune on the real-song bench.** The Viterbi weights were picked on held-out GuitarSet only. Keep it
  that way, or the bench stops meaning anything.

## Gotchas

- **Training data isn't in the repo.** The data and the Python environment live outside it
  (`../chordnet-data`). To retrain, you need to rebuild them:
  - download GuitarSet from Zenodo
  - regenerate the synthetic songs with `build/selftest --chordnet-synth`
  - set up the venv

  `scripts/chordnet/README.md` has the exact commands. The trained model itself is committed, so you only
  need all this to retrain.
- **The release and App Store scripts don't bundle the model yet.** `scripts/release.sh` and
  `scripts/appstore.sh` don't copy it; only `build.sh` does. Those builds silently fall back to templates
  even with the flag on.
- **One default is out of date in the README.** It says `CHORDNET_SCALE` defaults to 1, but the code
  (`ChordNet.emissionScale`) defaults to 1.6, the value picked on held-out data.
- **Some newer work isn't on this branch.** Winston's Mac has uncommitted follow-up work: Slakh fetch and
  extract scripts, MIDI chord labelling, and edits to `prepare.py`, `train.py` and `ChordNetEval.swift`.
  It was mid-experiment. Ask Winston before redoing any of it.
- **Feature extraction exists twice.** `ChordNet.features` in Swift and `scripts/chordnet/features.py` must
  stay identical. Run `scripts/chordnet/parity.py` after touching either one.

## How it can help in the future

In order of expected payoff:

1. **Combine it with the templates instead of replacing them.** Add the network and template scores,
   weighted, and measure on held-out data first. The songs ChordNet loses are ones the templates got right,
   so a blend should keep most of the wins without the losses. This is the cheapest next step.
2. **Protect the key and the chart.** Even with ChordNet on, compute `refineKey` and the chart-fit ratio from
   the template path or the chroma. Then better chords can't move the key or drop a whole-song chart. That
   removes every regression listed above except the chord-level ones.
3. **Train on more realistic audio.** This is the real fix for the gap between real and synthetic results.
   Options:
   - Slakh, after a licensing check
   - more varied synthetic mixes: real drum loops, piano samples, vocals with lyrics, mastering
     compression
   - licensed multitrack stems
4. **Build a bigger real-song benchmark.** With 11 songs, a 2-point change is noise, because per-song swings
   are ±10–30 points. Around 50 or more previews with well-matched charts would make decisions trustworthy.
   `--chart-bench` already does beat-by-beat scoring.
5. **Recognise richer chords later.** The model only predicts major and minor today: 7ths are counted as
   their triad, and sus/hdim are ignored. The same pipeline could add 7, maj7, sus2/sus4 and slash-bass
   outputs. That would help songs like Wonderwall and give learners more accurate chord names.
6. **Report its confidence.** The frame probabilities could flag low-confidence beats in the UI ("check this
   chord by ear") instead of presenting every chord as certain.

## Measuring

```bash
./build.sh selftest
DONTFRET_CHORDNET=1 build/selftest --chart-bench           # real previews, templates vs ChordNet
build/selftest --chordnet-eval ../chordnet-data/eval-guitarset   # held-out GuitarSet
CHORDNET_SCALE=2.0 CHORDNET_KEY=0.5 DONTFRET_CHORDNET=1 build/selftest --chart-bench   # try weights without rebuilding
```

When you report results, give both the real-preview numbers and the held-out numbers, and say which songs
got worse, not just the average.
