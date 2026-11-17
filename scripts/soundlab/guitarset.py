"""GuitarSet helpers: read a .jams annotation into per-string notes, group them into strums."""
import json, os, glob

STYLES = {'BN': 'Bossa Nova', 'Funk': 'Funk', 'Jazz': 'Jazz', 'Rock': 'Rock', 'SS': 'Singer-Songwriter'}
OPEN = [40, 45, 50, 55, 59, 64]


def notes(jams_path):
    """[(time, duration, string 0..5 low→high, midi float)] sorted by time."""
    d = json.load(open(jams_path))
    out = []
    for a in d['annotations']:
        if a['namespace'] != 'note_midi':
            continue
        s = int(a['annotation_metadata']['data_source'])
        for n in a['data']:
            out.append((n['time'], n['duration'], s, n['value']))
    return sorted(out)


def meta(jams_path):
    """player, style key, bpm, key, kind ('comp' / 'solo') from the file name, e.g. 00_SS3-84-Bb_comp."""
    name = os.path.basename(jams_path).replace('.jams', '')
    player, rest = name.split('_', 1)
    prog, kind = rest.rsplit('_', 1)
    style = next(k for k in STYLES if prog.startswith(k))
    bpm = int(prog.split('-')[1])
    return dict(name=name, player=int(player), style=style, bpm=bpm, kind=kind)


def strums(ns, window=0.07):
    """Groups notes whose onsets fall within `window` of the group's first onset."""
    groups, cur = [], []
    for n in ns:
        if cur and n[0] - cur[0][0] > window:
            groups.append(cur); cur = []
        cur.append(n)
    if cur: groups.append(cur)
    return groups


def files(ann_dir, kind=None):
    fs = sorted(glob.glob(os.path.join(ann_dir, '*.jams')))
    return [f for f in fs if kind is None or f.endswith('_' + kind + '.jams')]
