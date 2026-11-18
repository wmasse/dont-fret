"""Checks the Swift features (build/selftest --chordnet-features) match features.py.
   python parity.py <selftest> <wav> [<wav> ...]"""
import os, subprocess, sys, tempfile
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from features import features, load_audio, NBINS

worst = 0.0
for wav in sys.argv[2:]:
    out = os.path.join(tempfile.mkdtemp(), 'f.f32')
    subprocess.run([sys.argv[1], '--chordnet-features', wav, out], check=True, capture_output=True)
    s = np.fromfile(out, dtype=np.float32).reshape(-1, NBINS)
    p = features(load_audio(wav))
    T = min(len(s), len(p))
    d = np.abs(s[:T] - p[:T])
    print(f'{os.path.basename(wav)}: swift {s.shape} python {p.shape}  max |diff| {d.max():.4f}  mean {d.mean():.5f}  (feature range 0–{p.max():.2f})')
    worst = max(worst, d.max())
print('parity', 'OK' if worst < 0.05 else 'MISMATCH')
