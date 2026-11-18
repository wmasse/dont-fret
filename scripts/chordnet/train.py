"""Trains ChordNet on the cache from prepare.py (Apple GPU via MPS when available).

  python -I train.py --data <data dir> --out <dir> [--steps 12000]

Augmentation: random transposition by -5…+6 semitones (shifting the spectrogram two bins per semitone and
the labels with it), small random tuning shifts (fractions of a bin), frequency and time masking.
Every 1000 steps it reports frame accuracy on the held-out songs (major/minor frames only), saves a checkpoint
and keeps the best on --select (GuitarSet: real recordings, since the synthetic songs are easy to overfit).
"""
import argparse, os, sys, time, json
import numpy as np
import torch
import torch.nn.functional as Fn
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from features import BPS, NBINS, N_CLASSES, shift_labels
from model import ChordNet

ap = argparse.ArgumentParser()
ap.add_argument('--data', required=True)
ap.add_argument('--out', required=True)
ap.add_argument('--steps', type=int, default=12000)
ap.add_argument('--batch', type=int, default=24)
ap.add_argument('--crop', type=int, default=256)
ap.add_argument('--lr', type=float, default=1.5e-3)
ap.add_argument('--gs-weight', type=float, default=0.3, help='share of crops from GuitarSet')
ap.add_argument('--seed', type=int, default=0)
ap.add_argument('--select', default='guitarset', help='held-out set that picks the best checkpoint (real recordings by default)')
args = ap.parse_args()
os.makedirs(args.out, exist_ok=True)
rng = np.random.default_rng(args.seed)
torch.manual_seed(args.seed)
dev = torch.device('mps' if torch.backends.mps.is_available() else 'cpu')


def load(name):
    p = os.path.join(args.data, 'cache', name + '.npz')
    if not os.path.exists(p):
        return None
    d = np.load(p)
    return d['X'], d['Y'].astype(np.int64), d['off']


train = {k: load('train_' + k) for k in ['synth', 'guitarset']}
held = {k: load('heldout_' + k) for k in ['synth', 'guitarset']}
train = {k: v for k, v in train.items() if v is not None}
weights = {'synth': 1 - args.gs_weight, 'guitarset': args.gs_weight}
srcs = list(train)
p_src = np.array([weights[s] for s in srcs]); p_src /= p_src.sum()


def crop(src):
    X, Y, off = train[src]
    i = rng.integers(len(off) - 1)
    a, b = off[i], off[i + 1]
    L = args.crop
    s = a + rng.integers(max(1, b - a - L + 1))
    x = X[s:s + L].astype(np.float32)
    y = Y[s:s + L]
    if len(y) < L:
        x = np.pad(x, ((0, L - len(y)), (0, 0)))
        y = np.pad(y, (0, L - len(y)), constant_values=-1)
    # transpose
    k = int(rng.integers(-5, 7))
    sh = k * BPS
    if sh > 0:
        x = np.concatenate([np.zeros((L, sh), np.float32), x[:, :-sh]], 1)
    elif sh < 0:
        x = np.concatenate([x[:, -sh:], np.zeros((L, -sh), np.float32)], 1)
    y = shift_labels(y, k)
    # tuning wobble: up to ±0.4 bin (±20 cents) by linear interpolation
    fr = rng.uniform(-0.4, 0.4)
    if abs(fr) > 0.05:
        idx = np.clip(np.arange(NBINS) - fr, 0, NBINS - 1)
        lo = np.floor(idx).astype(int); hi = np.minimum(lo + 1, NBINS - 1); w = idx - lo
        x = x[:, lo] * (1 - w) + x[:, hi] * w
    # level / contrast and masking
    x = x * rng.uniform(0.8, 1.2)
    if rng.random() < 0.5:
        f0 = rng.integers(NBINS - 12); x[:, f0:f0 + rng.integers(2, 12)] = 0
    if rng.random() < 0.3:
        t0 = rng.integers(L - 10); x[t0:t0 + rng.integers(2, 10)] = 0
    return x, y


def batch():
    xs, ys = [], []
    for _ in range(args.batch):
        x, y = crop(srcs[rng.choice(len(srcs), p=p_src)])
        xs.append(x); ys.append(y)
    return torch.from_numpy(np.stack(xs).astype(np.float32)).to(dev), torch.from_numpy(np.stack(ys)).to(dev)


@torch.no_grad()
def evaluate(model):
    model.eval()
    res = {}
    for k, v in held.items():
        if v is None:
            continue
        X, Y, off = v
        right = total = 0
        for i in range(len(off) - 1):
            x = torch.from_numpy(X[off[i]:off[i + 1]].astype(np.float32))[None].to(dev)
            p = model(x).argmax(-1)[0].cpu().numpy()
            y = Y[off[i]:off[i + 1]]
            m = (y >= 0) & (y < 24)
            right += int((p[m] == y[m]).sum()); total += int(m.sum())
        res[k] = right / max(1, total)
    model.train()
    return res


model = ChordNet().to(dev)
print(f'{sum(p.numel() for p in model.parameters())} parameters on {dev}; train', {k: len(v[1]) for k, v in train.items()}, 'frames')
opt = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-3)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=args.steps, pct_start=0.05)
best, log = -1, []
t0 = time.time()
run = 0.0
for step in range(1, args.steps + 1):
    x, y = batch()
    logits = model(x)
    loss = Fn.cross_entropy(logits.reshape(-1, N_CLASSES), y.reshape(-1), ignore_index=-1, label_smoothing=0.05)
    opt.zero_grad(); loss.backward()
    torch.nn.utils.clip_grad_norm_(model.parameters(), 3.0)
    opt.step(); sched.step()
    run = 0.98 * run + 0.02 * loss.item() if step > 1 else loss.item()
    if step % 1000 == 0 or step == args.steps:
        acc = evaluate(model)
        score = acc.get(args.select, float(np.mean(list(acc.values()))))
        torch.save(model.state_dict(), os.path.join(args.out, f'step{step}.pt'))
        log.append(dict(step=step, loss=run, **acc))
        print(f'step {step}  loss {run:.3f}  held-out frame accuracy ' + '  '.join(f'{k} {v:.1%}' for k, v in acc.items()) + f'  ({time.time() - t0:.0f} s)', flush=True)
        if score > best:
            best = score
            torch.save(model.state_dict(), os.path.join(args.out, 'chordnet.pt'))
json.dump(log, open(os.path.join(args.out, 'log.json'), 'w'), indent=1)
print(f'best held-out frame accuracy ({args.select})', f'{best:.1%}')
