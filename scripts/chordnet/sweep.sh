#!/bin/bash
# Tunes how ChordNet's scores enter the Viterbi (CHORDNET_SCALE, CHORDNET_KEY) on the held-out split of the
# training sources only (never on the real-song bench).
#   scripts/chordnet/sweep.sh <model.mlmodelc> <eval dir> [<eval dir> ...]
set -euo pipefail
model="$1"; shift
for scale in 0.6 1.0 1.6; do
  for key in 0.25 0.5 1.0; do
    for dir in "$@"; do
      CHORDNET_MODEL="$model" CHORDNET_SCALE=$scale CHORDNET_KEY=$key build/selftest --chordnet-eval "$dir" | grep " chordnet:" | sed "s|^|scale $scale key $key $(basename "$dir") |"
    done
  done
done
