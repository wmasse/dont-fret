"""Exports a trained ChordNet to Core ML (macOS 14+, float32 by default, any length ≥ 16 frames).
(float16 drifted badly on one checkpoint — 12% of frames changed chord — so it is opt-in and checked.)

  python -I export.py --weights <chordnet.pt> --out Resources/ChordNet.mlpackage
Input `spec` [1, T, 150] (features.py), output `logp` [1, T, 25] log-probabilities.
"""
import argparse, os, sys
import numpy as np
import torch
import coremltools as ct
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from features import NBINS
from model import ChordNet

ap = argparse.ArgumentParser()
ap.add_argument('--weights', required=True)
ap.add_argument('--out', required=True)
ap.add_argument('--fp16', action='store_true')
ap.add_argument('--check', help='a cache .npz whose first songs are used to compare Core ML with PyTorch')
args = ap.parse_args()


class WithSoftmax(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m

    def forward(self, x):
        return torch.log_softmax(self.m(x), -1)


m = ChordNet()
m.load_state_dict(torch.load(args.weights, map_location='cpu'))
w = WithSoftmax(m).eval()
traced = torch.jit.trace(w, torch.randn(1, 300, NBINS))
ml = ct.convert(traced, inputs=[ct.TensorType(name='spec', shape=(1, ct.RangeDim(16, 20000, default=600), NBINS))],
                outputs=[ct.TensorType(name='logp')], minimum_deployment_target=ct.target.macOS14,
                compute_precision=ct.precision.FLOAT16 if args.fp16 else ct.precision.FLOAT32)
ml.short_description = "Don't Fret ChordNet: 24 major/minor chords + no chord per spectrogram frame"
ml.save(args.out)
mlm = ct.models.MLModel(args.out, compute_units=ct.ComputeUnit.CPU_AND_GPU)
tests = [torch.randn(1, 777, NBINS).abs()]
if args.check:
    d = np.load(args.check)
    for i in range(min(8, len(d['off']) - 1)):
        tests.append(torch.from_numpy(d['X'][d['off'][i]:d['off'][i + 1]].astype(np.float32))[None])
worst, agree, n = 0.0, 0, 0
for x in tests:
    ref = w(x).detach().numpy()
    out = mlm.predict({'spec': x.numpy()})['logp']
    worst = max(worst, float(np.abs(out - ref).max()))
    agree += int((out.argmax(-1) == ref.argmax(-1)).sum()); n += ref.shape[1]
print('saved', args.out, f'— max |Core ML − PyTorch| log-prob {worst:.4f}, argmax agreement {agree / n:.4f} over {len(tests)} inputs')
