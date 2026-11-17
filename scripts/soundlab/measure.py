"""Measures a real guitar from GuitarSet: strum timing, per-string partial decay, inharmonicity,
attack brightness and the long-term spectrum. Usage:
    python3 -I scripts/soundlab/measure.py <annotation dir> <mic audio dir> [out.json]
"""
import sys, os, json, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import au, guitarset as gs

ann, mic = sys.argv[1], sys.argv[2]
out_path = sys.argv[3] if len(sys.argv) > 3 else None
report = {}

# ---- 1. strum timing (comp files): spread from first to last string, direction ----
spreads = {'down': [], 'up': []}
per_style = {}
for f in gs.files(ann, 'comp'):
    m = gs.meta(f)
    for g in gs.strums(gs.notes(f)):
        if len(g) < 4: continue
        strs = [n[2] for n in g]
        t = [n[0] for n in g]
        order = np.corrcoef(t, strs)[0, 1] if np.std(strs) > 0 and np.std(t) > 0 else 0
        d = 'down' if order > 0.5 else ('up' if order < -0.5 else None)
        if d is None: continue
        sp = (max(t) - min(t)) * 1000
        spreads[d].append((sp, len(g)))
        per_style.setdefault(m['style'], []).append(sp)
for d in spreads:
    a = np.array([s for s, _ in spreads[d]]); n = np.array([k for _, k in spreads[d]])
    per_string = a / np.maximum(1, n - 1)
    print(f'strum {d:4s}: n={len(a)} spread ms median {np.median(a):.0f} (p10 {np.percentile(a,10):.0f}, p90 {np.percentile(a,90):.0f}); '
          f'strings/strum median {np.median(n):.0f}; ms between strings median {np.median(per_string):.1f}')
    report[f'strum_{d}_ms'] = [float(np.percentile(a, p)) for p in (10, 50, 90)]
    report[f'strum_{d}_strings'] = float(np.median(n))
for s, v in sorted(per_style.items()):
    print(f'   {gs.STYLES[s]:18s} spread median {np.median(v):.0f} ms')

# ---- 2. isolated single notes: decay per partial, inharmonicity, attack brightness ----
def isolated(ns, pre=0.25, post=0.9):
    out = []
    for i, n in enumerate(ns):
        t0, dur, s, m = n
        if dur < 0.45: continue
        clash = any(o is not n and o[0] < t0 + min(dur, post) and o[0] + o[1] > t0 - pre for o in ns)
        if not clash: out.append(n)
    return out

res = {s: [] for s in range(6)}
attack = {s: [] for s in range(6)}
for f in gs.files(ann):
    m = gs.meta(f)
    ns = gs.notes(f)
    iso = isolated(ns)
    if not iso: continue
    x, sr = au.read(os.path.join(mic, m['name'] + '_mic.wav')); x = au.mono(x)
    for (t0, dur, s, midi) in iso:
        f0 = 440 * 2 ** ((midi - 69) / 12)
        a = int(t0 * sr); L = int(min(dur, 1.5) * sr)
        seg = x[a:a + L]
        if len(seg) < int(0.45 * sr): continue
        # partial frequencies from one long window starting 40 ms in
        n = 16384
        w = seg[int(0.04 * sr):int(0.04 * sr) + n]
        if len(w) < n // 2: continue
        w = np.pad(w, (0, n - len(w))) * np.hanning(n)
        S = np.abs(np.fft.rfft(w)); fr = np.fft.rfftfreq(n, 1 / sr)
        found = []
        for k in range(1, 40):
            target = k * f0 * np.sqrt(1 + 1e-4 * k * k)
            if target > 9000: break
            lo, hi = np.searchsorted(fr, [target * 0.985 - 3, target * 1.015 + 3])
            if hi - lo < 2: continue
            j = lo + int(np.argmax(S[lo:hi]))
            if S[j] < S.max() * 10 ** (-55 / 20): continue
            if 0 < j < len(S) - 1:   # parabolic interpolation
                y0, y1, y2 = np.log(S[j - 1:j + 2] + 1e-12); p = 0.5 * (y0 - y2) / (y0 - 2 * y1 + y2)
                found.append((k, fr[j] + p * sr / n))
        B = None
        if len(found) >= 6:
            k = np.array([q[0] for q in found], float); fk = np.array([q[1] for q in found])
            # (fk/k)^2 = f0^2 (1 + B k^2)  → linear in k^2
            A = np.vstack([np.ones_like(k), k * k]).T
            c, *_ = np.linalg.lstsq(A, (fk / k) ** 2, rcond=None)
            if c[0] > 0: B = c[1] / c[0]
        # decay per partial: 10 ms hops, linear fit of dB vs time between 60 ms and the end
        hop = int(0.01 * sr); nn = 4096
        if len(seg) < nn + hop * 20: continue
        frames = 1 + (len(seg) - nn) // hop
        idx = np.arange(nn)[None, :] + hop * np.arange(frames)[:, None]
        SS = np.abs(np.fft.rfft(seg[idx] * np.hanning(nn), axis=1)); frq = np.fft.rfftfreq(nn, 1 / sr)
        tt = np.arange(frames) * hop / sr
        dec = []
        for (k, fk) in found[:24]:
            b = int(round(fk / (sr / nn)))
            amp = 20 * np.log10(SS[:, max(0, b - 1):b + 2].max(axis=1) + 1e-9)
            sel = (tt > 0.06) & (tt < min(dur, 1.5) - 0.1)
            if sel.sum() < 8: continue
            p = np.polyfit(tt[sel], amp[sel], 1)
            if p[0] < 0: dec.append((fk, -p[0]))      # dB per second
        res[s].append(dict(midi=midi, fret=round(midi - gs.OPEN[s]), B=B, dec=dec, style=m['style']))
        # attack brightness: spectral centroid of the first 25 ms vs 150–250 ms, relative to f0
        c1 = au.centroid(seg[:int(0.03 * sr)], sr, n=1024).mean()
        c2 = au.centroid(seg[int(0.15 * sr):int(0.25 * sr)], sr, n=1024).mean()
        attack[s].append((m['style'], c1, c2))

print('\nisolated notes per string:', {s: len(v) for s, v in res.items()})
report['strings'] = {}
for s in range(6):
    v = res[s]
    if not v: continue
    Bs = np.array([r['B'] for r in v if r['B'] is not None and 0 < r['B'] < 1e-2])
    frets = np.array([r['fret'] for r in v if r['B'] is not None and 0 < r['B'] < 1e-2])
    # normalise B to the open string: B grows with (f/f_open)^2 for the same string
    B_open = Bs / (2 ** (frets / 12)) ** 2 if len(Bs) else Bs
    # decay model: dB/s = c1 + c3 f^2   (Chaigne & Askenfelt style damping)
    allf = np.array([d[0] for r in v for d in r['dec']]); alld = np.array([d[1] for r in v for d in r['dec']])
    fit = None
    if len(allf) > 10:
        A = np.vstack([np.ones_like(allf), allf, allf ** 2]).T
        fit, *_ = np.linalg.lstsq(A, alld, rcond=None)
    bands = []
    for lo, hi in [(60, 250), (250, 500), (500, 1000), (1000, 2000), (2000, 4000), (4000, 9000)]:
        sel = (allf >= lo) & (allf < hi)
        bands.append(float(np.median(alld[sel])) if sel.sum() >= 3 else None)
    print(f'string {gs.OPEN[s]:2d} ({len(v):3d} notes): B_open median {np.median(B_open) if len(B_open) else float("nan"):.2e} '
          f'(n={len(B_open)}), decay dB/s by band 60-250/250-500/500-1k/1-2k/2-4k/4-9k: '
          + ' '.join('  -  ' if b is None else f'{b:5.1f}' for b in bands))
    report['strings'][s] = dict(B_open=float(np.median(B_open)) if len(B_open) else None, decay_db_s_bands=bands,
                                decay_fit=[float(c) for c in fit] if fit is not None else None)
cent = {}
for s in range(6):
    for st, c1, c2 in attack[s]: cent.setdefault(st, []).append((c1, c2))
print('\nattack centroid (first 30 ms) vs body (150–250 ms), Hz, by style:')
for st, v in sorted(cent.items()):
    a = np.array(v); print(f'   {gs.STYLES[st]:18s} n={len(a):3d} attack {np.median(a[:,0]):5.0f}  later {np.median(a[:,1]):5.0f}')

# ---- 3. long-term spectrum by style and kind ----
print('\nlong-term 1/3-octave spectrum (dB re max), averaged per group:')
cen = None; groups = {}
for f in gs.files(ann):
    m = gs.meta(f)
    x, sr = au.read(os.path.join(mic, m['name'] + '_mic.wav')); x = au.mono(x)
    cen, d = au.third_octave(x, sr)
    groups.setdefault((m['kind'], m['style']), []).append(10 ** (d / 10))
    groups.setdefault((m['kind'], 'all'), []).append(10 ** (d / 10))
sel = slice(4, 30)
print(' ' * 22 + ' '.join(f'{(str(int(c)) if c < 1000 else str(round(c / 1000, 1)) + "k"):>5}' for c in cen[sel]))
report['ltas_centers'] = [float(c) for c in cen]
for key in sorted(groups):
    d = 10 * np.log10(np.mean(groups[key], axis=0)); d -= d.max()
    print(f'{key[0]:4s} {key[1]:16s} ' + ' '.join(f'{v:5.0f}' for v in d[sel]))
    report[f'ltas_{key[0]}_{key[1]}'] = [float(v) for v in d]
if out_path: json.dump(report, open(out_path, 'w'), indent=1)
