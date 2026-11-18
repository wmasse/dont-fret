"""ChordNet input features: a log-frequency magnitude spectrogram.

Must match `ChordNet.features` in Sources/App/Analysis/ChordNet.swift exactly (see parity.py).
44.1 kHz mono, 16384-point Hann FFT every 2048 samples (21.5 frames/s, frame j centred at
j * 2048 samples, signal zero-padded by half a window at both ends), 150 bins two per semitone
from MIDI 28 (E1) up, each a triangle in Hz over the FFT bins (half-width a quarter-tone, at
least one FFT bin), rows normalised to sum 1; then divided by the clip's 99th-percentile value
and compressed with log(1 + 100 x).
"""
import numpy as np

SR = 44100
N_FFT = 16384
HOP = 2048
MIDI_LO = 28
BPS = 2            # bins per semitone
NBINS = 150
FPS = SR / HOP

_fb = None


def filterbank(tuning=0.0):
    """[NBINS, N_FFT/2] weights. `tuning` (semitones) moves every centre, as the app's tuning estimate does."""
    df = SR / N_FFT
    f = np.arange(N_FFT // 2) * df
    W = np.zeros((NBINS, N_FFT // 2), dtype=np.float64)
    for b in range(NBINS):
        m = MIDI_LO + b / BPS + tuning
        fc = 440.0 * 2 ** ((m - 69) / 12)
        hw = max(fc * (2 ** (1 / 24) - 1), df)
        w = np.maximum(0.0, 1 - np.abs(f - fc) / hw)
        W[b] = w / w.sum()
    return W.astype(np.float32)


def spectrogram(x, tuning=0.0):
    """Linear filterbank energies [T, NBINS] (before normalisation)."""
    global _fb
    if tuning == 0.0:
        if _fb is None:
            _fb = filterbank()
        W = _fb
    else:
        W = filterbank(tuning)
    x = np.asarray(x, dtype=np.float32)
    pad = N_FFT // 2
    xp = np.concatenate([np.zeros(pad, np.float32), x, np.zeros(pad, np.float32)])
    T = 1 + len(x) // HOP
    need = (T - 1) * HOP + N_FFT
    if len(xp) < need:
        xp = np.concatenate([xp, np.zeros(need - len(xp), np.float32)])
    win = np.hanning(N_FFT + 1)[:-1].astype(np.float32)   # periodic Hann, like vDSP_hann_window(..., HANN_NORM)
    out = np.empty((T, NBINS), np.float32)
    for s in range(0, T, 256):
        e = min(T, s + 256)
        idx = (np.arange(s, e)[:, None] * HOP) + np.arange(N_FFT)[None, :]
        fr = xp[idx] * win
        mag = np.abs(np.fft.rfft(fr, axis=1))[:, : N_FFT // 2].astype(np.float32)
        out[s:e] = mag @ W.T
    return out


def normalise(S):
    flat = np.sort(S.ravel())
    ref = flat[int(0.99 * (len(flat) - 1))] if len(flat) else 1.0
    return np.log1p(100.0 * S / max(float(ref), 1e-9)).astype(np.float32)


def features(x, tuning=0.0):
    return normalise(spectrogram(x, tuning))


def load_audio(path):
    """Mono float32 at 44.1 kHz."""
    import soundfile as sf
    x, sr = sf.read(path, dtype='float32', always_2d=True)
    x = x.mean(axis=1)
    if sr != SR:
        import soxr
        x = soxr.resample(x, sr, SR).astype(np.float32)
    return x


# chord classes: 0-11 major on that root, 12-23 minor, 24 no chord, -1 ignore (other qualities)
N_CLASSES = 25
NO_CHORD = 24
PC = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11}
MAJ = {'maj', '', '7', 'maj7', '9', 'maj9', '6', 'add9', '11', '13', 'maj6', '7(#9)', '7(b9)'}
MIN = {'min', 'm', 'min7', 'm7', 'min9', 'm9', 'min6', 'm6', 'min11', 'minmaj7'}


def chord_class(label):
    """Harte-style label ('C:maj7', 'A:min/b3', 'N', 'X') → class index."""
    if label in ('N', 'n'):
        return NO_CHORD
    if label in ('X', '') or ':' not in label and label[:1] not in PC:
        return -1
    root, _, qual = label.partition(':')
    qual = qual.split('/')[0]
    qual = qual.split('(')[0] if qual not in MAJ else qual
    pc = PC.get(root[:1].upper())
    if pc is None:
        return -1
    for ch in root[1:]:
        pc += 1 if ch == '#' else (-1 if ch == 'b' else 0)
    pc %= 12
    if qual in MAJ:
        return pc
    if qual in MIN:
        return 12 + pc
    return -1


def frame_labels(segments, T):
    """segments: [(start, end, class)] → [T] int labels, frame j at j / FPS seconds. Unlabelled frames are -1."""
    y = np.full(T, -1, np.int64)
    t = np.arange(T) / FPS
    for s, e, c in segments:
        y[(t >= s) & (t < e)] = c
    return y


def shift_labels(y, k):
    """Labels for audio transposed up k semitones."""
    y = y.copy()
    m = (y >= 0) & (y < 24)
    y[m] = (y[m] // 12) * 12 + (y[m] % 12 + k) % 12
    return y
