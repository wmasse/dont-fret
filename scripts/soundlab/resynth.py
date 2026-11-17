"""Re-synthesizes GuitarSet performances note for note and compares them with the real studio
recordings (Neumann U-87), so changes to the guitar sound can be measured instead of guessed.

    python3 -I scripts/soundlab/resynth.py --ann <GuitarSet annotation dir> --mic <GuitarSet mic dir> \
        --render build/selftest --out build/soundlab [--legacy <old renderer>] [--seconds 20] [--calibrate]

For each clip it writes the real excerpt, the re-synthesis (and the old engine's, if given), the
event list and a spectrogram (real / new / old). It prints a scorecard; lower is closer to real:
  lsd   log-mel spectral distance per 10 ms frame (dB) - overall timbre over time
  ltas  error of the long-term 1/3-octave spectrum after level matching (dB) - tonal balance
  env   error of the loudness envelope in octave bands (dB) - attack and decay per frequency
  cent  brightness (spectral centroid), synthesized / real; attack = first 30 ms of each strum
--calibrate prints the 1/3-octave correction for GuitarBody.acousticCalibration.
"""
import sys, os, re, json, argparse, subprocess, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import au, guitarset as gs

ap = argparse.ArgumentParser()
ap.add_argument('--ann', required=True); ap.add_argument('--mic', required=True)
ap.add_argument('--render', required=True); ap.add_argument('--legacy')
ap.add_argument('--out', default='build/soundlab'); ap.add_argument('--seconds', type=float, default=20)
ap.add_argument('--names', help='comma-separated clip names (default: a balanced set)')
ap.add_argument('--calibrate', action='store_true'); ap.add_argument('--images', type=int, default=6)
ap.add_argument('--room', type=float, help='room amount for the new engine (0 = dry)')
ap.add_argument('--polish', type=float, help='mix polish amount (calibrate with 0)')
ap.add_argument('--set', help='GuitarTuning overrides for the new engine, e.g. burstLevel=0.5,highDecay=1.2')
ap.add_argument('--cal', help='31 comma-separated dB values to try instead of GuitarBody.acousticCalibration')
ap.add_argument('--cal-out', help='write the suggested calibration (comma-separated) to this file')
ap.add_argument('--damp', type=float, default=0.15, help='seconds a note takes to stop where the annotation ends it (0 = let notes ring)')
args = ap.parse_args()
os.makedirs(args.out, exist_ok=True)
SR = 44100

# ---------- which clips ----------
if args.names:
    names = args.names.split(',')
else:
    names = []
    for style in ['BN', 'Funk', 'Jazz', 'Rock', 'SS']:
        for kind in ['comp', 'solo']:
            fs = [f for f in gs.files(args.ann, kind) if gs.meta(f)['style'] == style]
            # two players per style and kind, spread across the six guitarists
            picks = [fs[i] for i in (len(fs) // 7, (len(fs) * 4) // 7)] if len(fs) > 1 else fs
            names += [gs.meta(f)['name'] for f in picks]

# ---------- annotation → events ----------
STYLE = {  # (touch for bass strings, touch for treble, brightness down, brightness up)
    'BN': (1, 2, 0.45, 0.5), 'Jazz': (0, 0, 0.42, 0.5), 'Funk': (0, 0, 0.72, 0.82),
    'Rock': (0, 0, 0.6, 0.72), 'SS': (0, 0, 0.6, 0.75)}


def events_for(name, mic):
    m = gs.meta(os.path.join(args.ann, name + '.jams'))
    ns = [n for n in gs.notes(os.path.join(args.ann, name + '.jams')) if n[0] < args.seconds]
    groups = gs.strums(ns, window=0.05)
    # how hard each strum or note was played, from the rise in level on the microphone
    strength = []
    for g in groups:
        t0 = g[0][0]; a = int(t0 * SR)
        before = mic[max(0, a - int(0.03 * SR)):a]; after = mic[a:a + int(0.06 * SR)]
        rb = np.sqrt(np.mean(before ** 2)) if len(before) else 0; ra = np.sqrt(np.mean(after ** 2)) if len(after) else 0
        strength.append(np.sqrt(max(1e-12, ra * ra - rb * rb)) / max(1, len(g)) ** 0.5)
    ls = np.log(np.array(strength) + 1e-9)
    lo, hi = np.percentile(ls, 5), np.percentile(ls, 95)
    vel = np.clip(0.35 + 0.6 * (ls - lo) / max(1e-6, hi - lo), 0.25, 1.0)
    tb, tt, bdown, bup = STYLE[m['style']]
    lines = ['# tone 0']
    for g, v in zip(groups, vel):
        strs = [n[2] for n in g]
        up = len(g) >= 3 and np.corrcoef([n[0] for n in g], strs)[0, 1] < -0.5
        single = len(g) == 1
        for (t, dur, s, val) in g:
            mi = int(round(val)); det = val - mi
            touch = tb if s < 3 else tt
            bright = bup if up else bdown
            beta = 0.15 if single and touch == 0 else (0.2 if touch else 0.19)
            vv = v * (0.82 if up else 1.0)
            lines.append(f'{t:.5f} p {s} {mi} {det:.4f} {vv:.3f} {bright:.2f} {beta:.3f} {touch} 0 0 0.12')
    # stop notes where the annotation ends them, unless the same string plays again right away
    by_string = {}
    for n in ns: by_string.setdefault(n[2], []).append(n)
    for s, lst in by_string.items():
        for a, b in zip(lst, lst[1:] + [None]):
            end = a[0] + a[1]
            if b is not None and b[0] - end < 0.03: continue
            if end < args.seconds and args.damp > 0: lines.append(f'{end:.5f} d {s} 0 0 0 0 0 0 0 {args.damp} 0')
    return '\n'.join(lines) + '\n', m


# ---------- metrics ----------
def mel_fb(n=2048, bands=64, fmin=40, fmax=16000):
    f = np.fft.rfftfreq(n, 1 / SR)
    mel = lambda x: 2595 * np.log10(1 + x / 700); inv = lambda y: 700 * (10 ** (y / 2595) - 1)
    edges = inv(np.linspace(mel(fmin), mel(fmax), bands + 2))
    fb = np.zeros((bands, len(f)))
    for i in range(bands):
        l, c, r = edges[i:i + 3]
        fb[i] = np.clip(np.minimum((f - l) / (c - l), (r - f) / (r - c)), 0, None)
    return fb

FB = mel_fb()
OCT = [125, 250, 500, 1000, 2000, 4000, 8000]


def logmel(x):
    S = au.stft(x, 2048, 441) ** 2
    return 10 * np.log10(S @ FB.T + 1e-12), S


def align(real, syn, hop=64):
    """Shifts `syn` to line up with `real`: GuitarSet's annotated onsets sit ~9 ms after the
    sound reaches the microphone, so the re-synthesis is late by that much."""
    def flux(x):
        S = au.stft(x, 512, hop); f = np.fft.rfftfreq(512, 1 / SR); m = (f >= 2000) & (f < 12000)
        L = np.log1p(1e4 * S[:, m]); d = np.maximum(0, np.diff(L, axis=0)).sum(axis=1)
        return (d - d.mean()) / (d.std() + 1e-9)
    a, b = flux(real), flux(syn[:len(real)])
    k = max(range(-40, 41), key=lambda k: np.dot(a[max(0, k):len(a) + min(0, k)], b[max(0, -k):len(b) - max(0, k)]))
    shift = -k * hop                                  # samples the synthesis is late
    return (syn[shift:] if shift > 0 else np.concatenate([np.zeros(-shift), syn])), shift / SR


def metrics(real, syn, onsets):
    n = min(len(real), len(syn)); real, syn = real[:n], syn[:n]
    syn = syn * np.sqrt(np.sum(real ** 2) / max(1e-12, np.sum(syn ** 2)))   # level match
    Lr, Sr = logmel(real); Ls, Ss = logmel(syn)
    act = Lr.max(axis=1) > Lr.max() - 60
    floor = Lr.max() - 80
    d = np.maximum(Lr, floor) - np.maximum(Ls, floor)
    lsd = float(np.mean(np.sqrt(np.mean(d[act] ** 2, axis=1))))
    c, a = au.third_octave(real, SR); _, b = au.third_octave(syn, SR)
    sel = (c >= 63) & (c <= 12600)
    diff = (b - a)[sel]; ltas = float(np.sqrt(np.mean((diff - diff.mean()) ** 2)))
    f = np.fft.rfftfreq(2048, 1 / SR)
    errs = []
    for oc in OCT:
        msk = (f >= oc / np.sqrt(2)) & (f < oc * np.sqrt(2))
        er = 10 * np.log10(Sr[:, msk].sum(axis=1) + 1e-12); es = 10 * np.log10(Ss[:, msk].sum(axis=1) + 1e-12)
        keep = er > er.max() - 45
        if keep.sum() < 10: continue
        dd = np.maximum(es[keep], er.max() - 60) - er[keep]
        errs.append(np.sqrt(np.mean((dd - dd.mean()) ** 2)))
    env = float(np.mean(errs))
    cr = au.centroid(real, SR); cs = au.centroid(syn, SR)
    m = min(len(cr), len(cs)); w = (Sr.sum(axis=1)[:m] > 1e-6 * Sr.sum(axis=1).max()) if len(Sr) >= m else slice(None)
    cent = float(np.median(cs[:m][w]) / np.median(cr[:m][w]))
    att_r, att_s = [], []
    for t in onsets:
        i = max(0, int((t - 0.009) * SR)); j = i + int(0.03 * SR)
        if j < n:
            att_r.append(au.centroid(real[i:j], SR, n=1024).mean()); att_s.append(au.centroid(syn[i:j], SR, n=1024).mean())
    attack = float(np.median(np.array(att_s) / np.maximum(1, np.array(att_r)))) if att_r else float('nan')
    dec = {}
    hop = 441 / SR
    iso = [t for i, t in enumerate(onsets) if (i + 1 == len(onsets) or onsets[i + 1] - t > 0.45)]
    for oc in OCT:
        msk = (f >= oc / np.sqrt(2)) & (f < oc * np.sqrt(2))
        er = 10 * np.log10(Sr[:, msk].sum(axis=1) + 1e-12); es = 10 * np.log10(Ss[:, msk].sum(axis=1) + 1e-12)
        sr_, ss_ = [], []
        for t in iso:
            i0, i1 = int((t + 0.04) / hop), int((t + 0.40) / hop)
            if i1 >= len(er): continue
            tt = np.arange(i1 - i0) * hop
            sr_.append(np.polyfit(tt, er[i0:i1], 1)[0]); ss_.append(np.polyfit(tt, es[i0:i1], 1)[0])
        if sr_: dec[oc] = (float(np.median(sr_)), float(np.median(ss_)))
    return dict(lsd=lsd, ltas=ltas, env=env, cent=cent, attack=attack, ltas_curve=(b - a).tolist(), decay=dec)


# ---------- run ----------
rows, curves = [], {'new': [], 'old': []}
for k, name in enumerate(names):
    x, sr = au.read(os.path.join(args.mic, name + '_mic.wav')); x = au.mono(x)
    ev, m = events_for(name, x)
    evp = os.path.join(args.out, name + '.events.txt'); open(evp, 'w').write(ev)
    L = int((args.seconds + 1.5) * SR)
    real = x[:L]
    au.write_wav(os.path.join(args.out, name + '.real.wav'), real, SR)
    outs = {}
    for tag, exe in [('new', args.render), ('old', args.legacy)]:
        if not exe: continue
        wav = os.path.join(args.out, f'{name}.{tag}.wav')
        cmd = [exe, '--render-events', evp, wav] if tag == 'new' else [exe, evp, wav]
        if tag == 'new' and args.room is not None: cmd += ['--room', str(args.room)]
        if tag == 'new' and args.polish is not None: cmd += ['--polish', str(args.polish)]
        if tag == 'new' and args.set: cmd += ['--set', args.set]
        if tag == 'new' and args.cal: cmd += ['--cal', args.cal]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
        y, _ = au.read(wav); y, lag = align(real, au.mono(y)); outs[tag] = y[:L]
    onsets = [g[0][0] for g in gs.strums([n for n in gs.notes(os.path.join(args.ann, name + '.jams')) if n[0] < args.seconds], 0.05)]
    row = dict(name=name, style=m['style'], kind=m['kind'])
    for tag, y in outs.items():
        r = metrics(real, y, onsets); curves[tag].append(np.array(r.pop('ltas_curve'))); row[tag] = r
    rows.append(row)
    if k < args.images:
        clips = [('real', real[:int(8 * SR)])] + [(t, outs[t][:int(8 * SR)]) for t in ('new', 'old') if t in outs]
        au.save_specs(os.path.join(args.out, name + '.spec.png'), clips, SR, width=1000, fmax=16000)
    print(f"{name:28s} " + '  '.join(f"{t}: lsd {row[t]['lsd']:5.2f} ltas {row[t]['ltas']:4.1f} env {row[t]['env']:4.1f} "
                                     f"cent {row[t]['cent']:4.2f} att {row[t]['attack']:4.2f}" for t in ('new', 'old') if t in row), flush=True)

print('\nmean over', len(rows), 'clips (lower is better; cent/att: 1.00 = as bright as real)')
for tag in ('new', 'old'):
    rs = [r[tag] for r in rows if tag in r]
    if not rs: continue
    print(f"  {tag}: lsd {np.mean([r['lsd'] for r in rs]):5.2f}  ltas {np.mean([r['ltas'] for r in rs]):4.1f}  env {np.mean([r['env'] for r in rs]):4.1f}"
          f"  cent {np.median([r['cent'] for r in rs]):4.2f}  attack {np.nanmedian([r['attack'] for r in rs]):4.2f}")
    for kind in ('comp', 'solo'):
        k = [r[tag] for r in rows if tag in r and r['kind'] == kind]
        if k: print(f"     {kind}: lsd {np.mean([r['lsd'] for r in k]):5.2f}  ltas {np.mean([r['ltas'] for r in k]):4.1f}  env {np.mean([r['env'] for r in k]):4.1f}")
json.dump(rows, open(os.path.join(args.out, 'scores.json'), 'w'), indent=1)
print('\ndecay after isolated onsets, dB/s (real / new / old), median over clips:')
for oc in OCT:
    vals = {t: [r[t]['decay'][oc] for r in rows if t in r and oc in r[t]['decay']] for t in ('new', 'old')}
    if not vals['new']: continue
    line = f'   {oc:5d} Hz  real {np.median([v[0] for v in vals["new"]]):6.1f}  new {np.median([v[1] for v in vals["new"]]):6.1f}'
    if vals['old']: line += f'  old {np.median([v[1] for v in vals["old"]]):6.1f}'
    print(line)

if args.calibrate and curves['new']:
    centres = 1000 * 2 ** (np.arange(-17, 14) / 3)
    diff = -np.mean(curves['new'], axis=0)          # real − synthesized, per band
    diff -= np.mean(diff[(centres >= 200) & (centres <= 5000)])
    sm = np.convolve(np.pad(diff, 1, mode='edge'), [0.25, 0.5, 0.25], mode='valid')
    src = open(os.path.join(os.path.dirname(__file__), '..', '..', 'Sources', 'App', 'GuitarBody.swift')).read()
    cur = re.search(r'acousticCalibration: \[Double\] = (\[Double\]\(repeating: 0, count: 31\)|\[[^\]]*\])', src).group(1)
    cur = np.zeros(31) if 'repeating' in cur else np.array([float(v) for v in cur.strip('[]').split(',')])
    if args.cal: cur = np.array([float(v) for v in args.cal.split(',')])
    new = np.clip(cur + sm, -14, 14)
    # below 80 Hz the recordings hold room rumble and handling noise, not guitar: don't chase it
    new[centres < 80] = np.minimum(new[centres < 80], new[np.argmax(centres >= 80)])
    new[centres > 14000] = np.minimum(new[centres > 14000], 6)   # above the guitar's range: keep air, not hiss
    new[centres < 40] = new[np.argmax(centres >= 40)]; new[centres > 16000] = new[np.argmax(centres > 16000) - 1]
    print('\ncalibration (real − synthesized, smoothed, added to the current curve):')
    print('    static let acousticCalibration: [Double] = [' + ', '.join(f'{v:.1f}' for v in new) + ']')
    if args.cal_out: open(args.cal_out, 'w').write(','.join(f'{v:.2f}' for v in new))
