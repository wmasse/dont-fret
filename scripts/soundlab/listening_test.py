"""Builds the clips for a blind listening test of the guitar sound (MUSHRA-style, ITU-R BS.1534,
asking how much each clip sounds like a real acoustic guitar recording).

    python3 -I scripts/soundlab/listening_test.py --lab build/soundlab --out <website>/app/static/dont-fret/listening-test \
        --key <website>/instance/dont_fret_listening_key.json \
        --app "Campfire strum=build/demos/strum-campfire.wav,build/old-demos/strum-campfire.wav" \
        --app "Fingerpicking=build/demos/fingerpicking.wav,build/old-demos/fingerpicking.wav"

`--lab` is a `resynth.py --legacy …` output folder (each clip's .real/.new/.old.wav). Each
"pro" trial plays one GuitarSet excerpt four ways: the real recording (hidden reference), the new
engine, the old engine and a low anchor (the real recording low-passed at 3.5 kHz, as BS.1534
prescribes). They're all mono, because the studio recording is, and stereo alone would give the
real one away. Each `--app` trial is a demo of the app's own playing: new, old, and the new one
low-passed as the anchor.

Every clip in a trial is the same 8 s, lined up note for note, loudness-matched (BS.1770) and
faded; files get random names. Writes `<out>/clips/*.mp4` (AAC) and `<out>/manifest.json`, which the
listening-test page loads. Which condition each clip is goes either in a separate file the server
keeps (`--key`, for jeremyzay.com/dont-fret/listening-test, which scores answers server-side; keep
that file out of any public repository) or,
without it, into the manifest as an obfuscated `key` (for a page that scores in the browser; a
curious listener can't read it at a glance, though it isn't secret from anyone who decodes it).
"""
import sys, os, json, base64, random, argparse, subprocess, tempfile, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import au

PRO = [  # (GuitarSet clip, what it is, start s)
    ('03_SS2-107-Ab_comp', 'Singer-songwriter strumming', 1.0),
    ('00_Funk3-98-A_comp', 'Funk strumming', 1.0),
    ('03_BN2-131-B_comp', 'Bossa nova, fingerstyle', 1.0),
    ('00_Rock3-148-C_comp', 'Rock strumming', 1.0),
    ('00_SS3-98-C_solo', 'Picked melody', 1.0),
    ('03_Jazz2-110-Bb_solo', 'Jazz single-note line', 1.0),
]
CONDITIONS = {'real': 'Real recording (hidden)', 'new': 'New engine', 'old': 'Old engine', 'anchor': 'Low anchor (3.5 kHz low-pass)'}

ap = argparse.ArgumentParser()
ap.add_argument('--lab', required=True)
ap.add_argument('--out', required=True)
ap.add_argument('--app', action='append', default=[], help='"Label=new.wav,old.wav" (repeatable)')
ap.add_argument('--seconds', type=float, default=8.0)
ap.add_argument('--lufs', type=float, default=-20.0)
ap.add_argument('--key', help='write which clip is which to this JSON file and leave it out of the manifest '
                              '(for a site whose server scores the answers, e.g. jeremyzay.com/dont-fret/listening-test)')
args = ap.parse_args()
SR = 44100
# file names and order come from the OS's randomness, never a seed: the script is public, and a
# seeded generator would let anyone rebuild which file is which without hearing a note
rng = random.SystemRandom()
os.makedirs(os.path.join(args.out, 'clips'), exist_ok=True)


def lowpass(x, fc=3500.0, width=400.0):
    """Zero-phase low-pass with a short raised-cosine transition (the BS.1534 3.5 kHz anchor)."""
    n = len(x); X = np.fft.rfft(x, axis=0); f = np.fft.rfftfreq(n, 1 / SR)
    g = np.clip((fc + width / 2 - f) / width, 0, 1); g = 0.5 - 0.5 * np.cos(np.pi * g)
    return np.fft.irfft(X * (g[:, None] if x.ndim == 2 else g), n=n, axis=0).astype(np.float32)


def fade(x, t=0.025):
    k = int(t * SR); w = np.linspace(0, 1, k, dtype=np.float32)
    if x.ndim == 2: w = w[:, None]
    x = x.copy(); x[:k] *= w; x[-k:] *= w[::-1]
    return x


def encode(x, stereo):
    name = '%08x' % rng.getrandbits(32)
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, 'x.wav')
        au.write_wav(wav, x, SR)
        # AAC in an .mp4 container (web pages, artifacts included, serve .mp4 but often not .m4a)
        subprocess.run(['afconvert', '-f', 'mp4f', '-d', 'aac', '-b', '192000' if stereo else '128000', wav,
                        os.path.join(args.out, 'clips', name + '.mp4')], check=True)
    return 'clips/' + name + '.mp4'


def trial(tid, kind, label, source, clips, stereo):
    """clips: {condition: samples}. Loudness-matches them and writes the files."""
    louds = {c: au.lufs(x, SR) for c, x in clips.items()}
    target = args.lufs
    peak = max(np.abs(x).max() * 10 ** ((target - louds[c]) / 20) for c, x in clips.items())
    if peak > 0.94: target -= 20 * np.log10(peak / 0.94)       # keep every clip in the trial at the same loudness
    stimuli = []
    for c, x in clips.items():
        y = fade(x * 10 ** ((target - louds[c]) / 20))
        stimuli.append({'file': encode(y, stereo), 'cond': c})
    rng.shuffle(stimuli)
    print(f'{tid} {label:30s} {", ".join(s["cond"] for s in stimuli)} at {target:.1f} LUFS')
    return {'id': tid, 'kind': kind, 'label': label, 'source': source, 'stimuli': stimuli}


trials = []
L = int(args.seconds * SR)
for k, (name, label, start) in enumerate(PRO):
    real, _ = au.read(os.path.join(args.lab, name + '.real.wav')); real = au.mono(real)
    a = int(start * SR)
    clips = {'real': real[a:a + L]}
    for c in ('new', 'old'):
        y, _ = au.read(os.path.join(args.lab, f'{name}.{c}.wav'))
        clips[c] = au.mono(au.align(real, au.mono(y), SR))[a:a + L].astype(np.float32)
    clips['anchor'] = lowpass(clips['real'])
    trials.append(trial(f'p{k + 1}', 'pro', label, f'GuitarSet {name} (CC BY 4.0)', clips, stereo=False))
for k, spec in enumerate(args.app):
    label, files = spec.split('=', 1); new_path, old_path = files.split(',')
    new, _ = au.read(new_path); old, _ = au.read(old_path)
    a = int(0.1 * SR)
    clips = {'new': new[a:a + L], 'old': old[a:a + L]}
    clips['anchor'] = lowpass(clips['new'])
    trials.append(trial(f'a{k + 1}', 'app', label, "Don't Fret demo", clips, stereo=True))

# the page shows letters only; which condition each file is goes in an obfuscated key
key = {s['file']: s['cond'] for t in trials for s in t['stimuli']}
for t in trials:
    for s in t['stimuli']: del s['cond']
manifest = {
    'version': 1,
    'seconds': args.seconds,
    'question': 'How much does each clip sound like a recording of a real acoustic guitar?',
    'conditions': CONDITIONS,
    'trials': trials,
}
if args.key:
    # the server keeps the key and its own names for the conditions: the page learns neither
    json.dump(key, open(args.key, 'w'), indent=1, sort_keys=True)
    del manifest['conditions']
else:
    manifest['key'] = base64.b64encode(json.dumps(key)[::-1].encode()).decode()
json.dump(manifest, open(os.path.join(args.out, 'manifest.json'), 'w'), indent=1)
print(f'{sum(len(t["stimuli"]) for t in trials)} clips → {args.out}')
