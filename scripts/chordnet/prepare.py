"""Builds the ChordNet training cache: features and per-frame labels for every source.

  python -I prepare.py --data <data dir>

Sources (all commercially usable):
  <data>/guitarset/{ann,mic}   GuitarSet (Xi et al. 2018, CC BY 4.0): the 180 accompaniment ("comp")
                               excerpts with their lead-sheet chords. Progression 3 of each style
                               (all six players) is held out, since every player plays the same lead sheets.
  <data>/synth, synth-heldout  build/selftest --chordnet-synth (the app's own synth; .lab per song)

Writes <data>/cache/<split>_<source>.npz (features float16 [sum T, 150], labels int8, song offsets)
and <data>/eval-guitarset/ (wav links + .lab + .key) for `build/selftest --chordnet-eval`.
"""
import argparse, glob, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from features import features, load_audio, frame_labels, chord_class, PC

ap = argparse.ArgumentParser()
ap.add_argument('--data', required=True)
ap.add_argument('--sources', default='guitarset,synth')
args = ap.parse_args()
cache = os.path.join(args.data, 'cache')
os.makedirs(cache, exist_ok=True)


def save(name, items):
    if not items:
        return
    X = np.concatenate([x for x, _ in items]).astype(np.float16)
    Y = np.concatenate([y for _, y in items]).astype(np.int8)
    off = np.cumsum([0] + [len(y) for _, y in items])
    np.savez(os.path.join(cache, name + '.npz'), X=X, Y=Y, off=off)
    lab = Y[Y >= 0]
    print(f'{name}: {len(items)} songs, {len(Y)} frames ({len(Y) / 21.5 / 3600:.2f} h), labelled {len(lab) / len(Y):.0%}, no-chord {np.mean(lab == 24):.1%}')


def guitarset():
    gs = os.path.join(args.data, 'guitarset')
    ev = os.path.join(args.data, 'eval-guitarset')
    os.makedirs(ev, exist_ok=True)
    items = {'train': [], 'heldout': []}
    for jp in sorted(glob.glob(os.path.join(gs, 'ann', '*_comp.jams'))):
        name = os.path.basename(jp)[:-5]
        wav = os.path.join(gs, 'mic', name + '_mic.wav')
        if not os.path.exists(wav):
            continue
        d = json.load(open(jp))
        chords = [a for a in d['annotations'] if a['namespace'] == 'chord'][0]   # the lead sheet
        segs = [(c['time'], c['time'] + c['duration'], chord_class(c['value'])) for c in chords['data']]
        x = load_audio(wav)
        F = features(x)
        Y = frame_labels(segs, len(F))
        # every player plays the same 30 lead sheets, so hold out whole progressions (number 3 of each style)
        split = 'heldout' if name.split('_')[1].split('-')[0].endswith('3') else 'train'
        items[split].append((F, Y))
        if split == 'heldout':
            link = os.path.join(ev, name + '.wav')
            if not os.path.exists(link):
                os.symlink(wav, link)
            with open(os.path.join(ev, name + '.lab'), 'w') as f:
                for s, e, c in segs:
                    f.write(f'{s:.4f} {e:.4f} {c}\n')
            km = [a for a in d['annotations'] if a['namespace'] == 'key_mode']
            if km and km[0]['data']:
                root, _, mode = km[0]['data'][0]['value'].partition(':')
                pc = (PC[root[0]] + root[1:].count('#') - root[1:].count('b')) % 12
                with open(os.path.join(ev, name + '.key'), 'w') as f:
                    f.write(f'{pc} {"minor" if mode.startswith("min") else "major"}\n')
    for split, it in items.items():
        save(f'{split}_guitarset', it)


# synthetic
def synth(folder):
    out = []
    for lab in sorted(glob.glob(os.path.join(args.data, folder, 'syn_*.lab'))):
        segs = [(float(a), float(b), int(c)) for a, b, c in (l.split() for l in open(lab) if l.strip())]
        F = features(load_audio(lab[:-4] + '.wav'))
        out.append((F, frame_labels(segs, len(F))))
    return out


if 'guitarset' in args.sources:
    guitarset()
if 'synth' in args.sources:
    save('train_synth', synth('synth'))
    save('heldout_synth', synth('synth-heldout'))
