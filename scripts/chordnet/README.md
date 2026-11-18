# ChordNet: neural chord recogniser (prototype)

A small CNN + bidirectional GRU (1.3 M parameters) that reads a log-frequency spectrogram and gives every
frame (21.5 per second) a probability for each of 24 major/minor chords and "no chord". In the app it sits
behind a flag (`chordNet` user default or `DONTFRET_CHORDNET=1`): its per-beat probabilities replace the
chroma-template scores in `Transcriber.viterbi`. Beats, key, meter, bars and sections are worked out as
before, and the template path is the fallback when the flag is off or the model is missing.
Swift side: `Sources/App/Analysis/ChordNet.swift`.

## Training data (commercially usable only)

| Source | Licence | What | Hours |
|---|---|---|---|
| GuitarSet (Xi et al., ISMIR 2018) | CC BY 4.0 | 180 accompaniment excerpts, lead-sheet chords | 1.0 train, 0.55 held out |
| Synthetic band mixes | ours | `build/selftest --chordnet-synth`: the app's guitar engine + bass, keys, pad, drums, sung-style lead; all 12 keys, major and minor, 60–170 BPM, 3/4 and 4/4, 7ths/sus/add9/6/dim/inversions, tuning ±25 cents | 21.6 train, 1.3 held out |

No commercial recordings are used for training. The 15 store previews in `build/bench` are only used to
measure. Slakh2100 (CC BY 4.0) would be the next source to add: it is MIDI rendered with professional
sample libraries and is much closer to real mixes. But it is one 104 GB archive in shuffled order, so a
partial download doesn't give matching audio and MIDI. Note that Slakh, like Lakh MIDI, renders MIDI
transcriptions of copyrighted songs: the recordings are free, but the compositions aren't. Check that
before relying on it.

GuitarSet held-out split: every player plays the same 30 lead sheets, so holding out a player leaks the
progressions. Progression 3 of each style is held out instead (all six players, 60 excerpts).

## Pipeline

Data and the Python environment live outside the repository (here `../chordnet-data`):

```bash
D=../chordnet-data
/opt/anaconda3/bin/python -m venv $D/venv && $D/venv/bin/pip install torch numpy scipy soundfile soxr coremltools
# GuitarSet: annotation.zip + audio_mono-mic.zip from zenodo.org/records/3371780, unzipped into $D/guitarset/{ann,mic}
./build.sh selftest
build/selftest --chordnet-synth $D/synth 2500 1                # ~7 min on an M3 Pro, 6.5 GB
build/selftest --chordnet-synth $D/synth-heldout 150 1000001
$D/venv/bin/python -I scripts/chordnet/prepare.py --data $D      # features + frame labels → $D/cache
$D/venv/bin/python -I scripts/chordnet/parity.py build/selftest <some.wav>   # Swift features == Python features
$D/venv/bin/python -I scripts/chordnet/train.py --data $D --out $D/run2 --steps 6000 --gs-weight 0.5   # ~40 min on MPS
$D/venv/bin/python -I scripts/chordnet/export.py --weights $D/run2/chordnet.pt --out Resources/ChordNet.mlpackage --check $D/cache/heldout_guitarset.npz
./build.sh selftest   # compiles Resources/ChordNet.mlpackage → build/ChordNet.mlmodelc (also copied into the app)
```

## Measuring

```bash
build/selftest --chordnet-eval $D/eval-guitarset        # held-out GuitarSet: templates vs ChordNet, beat by beat + key
build/selftest --chordnet-eval $D/synth-heldout
DONTFRET_CHORDNET=1 build/selftest --chart-bench        # real previews; adds a "same chart" line that scores
                                                        # both against the chart as the template run lines it up
scripts/chordnet/sweep.sh build/ChordNet.mlmodelc $D/eval-guitarset   # Viterbi weights, held-out data only
```

`CHORDNET_SCALE` (how much the network's log-probabilities count against the change costs, default 1) and
`CHORDNET_KEY` (share of the key prior kept, default 0.5) can be set to try other weights without rebuilding.

Files: `features.py` (must match `ChordNet.features`), `model.py`, `prepare.py`, `train.py`, `export.py`,
`parity.py`, `compile_model.swift`, `sweep.sh`, `run2-log.json` (training curve of the shipped model).
