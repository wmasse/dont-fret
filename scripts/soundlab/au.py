# numpy-only audio analysis helpers: wav io, STFT, spectrogram PNGs, band stats
import wave, struct, zlib, numpy as np

def read(path):
    """RIFF/WAVE reader for 16/24-bit PCM and 32-bit float (incl. WAVE_FORMAT_EXTENSIBLE)."""
    b = open(path, 'rb').read()
    assert b[:4] == b'RIFF' and b[8:12] == b'WAVE', path
    i, fmt, data = 12, None, None
    while i + 8 <= len(b):
        cid, size = b[i:i + 4], struct.unpack('<I', b[i + 4:i + 8])[0]
        body = b[i + 8:i + 8 + size]
        if cid == b'fmt ': fmt = struct.unpack('<HHIIHH', body[:16]) + ((struct.unpack('<H', body[24:26])[0],) if len(body) >= 26 else (None,))
        elif cid == b'data': data = body
        i += 8 + size + (size & 1)
    tag, ch, sr, _, _, bits, sub = fmt
    if tag == 0xFFFE: tag = sub
    if tag == 3: x = np.frombuffer(data[:len(data) // 4 * 4], dtype='<f4').astype(np.float32)
    elif bits == 16: x = np.frombuffer(data[:len(data) // 2 * 2], dtype='<i2').astype(np.float32) / 32768
    elif bits == 24:
        a = np.frombuffer(data[:len(data) // 3 * 3], dtype=np.uint8).reshape(-1, 3).astype(np.int32)
        v = a[:, 0] | (a[:, 1] << 8) | (a[:, 2] << 16); v = np.where(v >= 1 << 23, v - (1 << 24), v)
        x = v.astype(np.float32) / (1 << 23)
    elif bits == 32: x = np.frombuffer(data[:len(data) // 4 * 4], dtype='<i4').astype(np.float32) / 2 ** 31
    else: raise ValueError(fmt)
    return x[:len(x) // ch * ch].reshape(-1, ch), sr

def mono(x): return x.mean(axis=1) if x.ndim == 2 else x

def stft(x, n=4096, hop=512):
    win = np.hanning(n).astype(np.float32)
    frames = 1 + max(0, (len(x) - n) // hop)
    idx = np.arange(n)[None, :] + hop * np.arange(frames)[:, None]
    return np.abs(np.fft.rfft(x[idx] * win, axis=1))

def rms_env(x, sr, hop=0.01):
    h = int(sr * hop); m = len(x) // h
    return np.sqrt((x[:m * h].reshape(m, h) ** 2).mean(axis=1) + 1e-12)

def onsets(x, sr, hop=512, n=2048, thresh=3.0):
    S = stft(x, n, hop); L = np.log1p(1000 * S)
    flux = np.maximum(0, np.diff(L, axis=0)).sum(axis=1)
    med = np.convolve(flux, np.ones(31) / 31, mode='same')
    peaks = [i for i in range(1, len(flux) - 1) if flux[i] > flux[i - 1] and flux[i] >= flux[i + 1] and flux[i] > thresh * med[i] + 1e-3]
    out, last = [], -1e9
    for p in peaks:
        t = (p + 1) * hop / sr
        if t - last > 0.05: out.append(t); last = t
    return np.array(out), flux

# --- PNG writing (no matplotlib) ---
def _png(path, rgb):
    h, w, _ = rgb.shape
    raw = b''.join(b'\x00' + rgb[y].astype(np.uint8).tobytes() for y in range(h))
    def chunk(t, d): c = struct.pack('>I', len(d)) + t + d; return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 6)) + chunk(b'IEND', b'')
    open(path, 'wb').write(png)

def cmap(v):  # v in 0..1 -> inferno-ish
    stops = np.array([[0, 0, 4], [40, 11, 84], [101, 21, 110], [159, 42, 99], [212, 72, 66], [245, 125, 21], [250, 193, 39], [252, 255, 164]], dtype=np.float32)
    v = np.clip(v, 0, 1) * (len(stops) - 1); i = np.minimum(len(stops) - 2, v.astype(int)); f = (v - i)[..., None]
    return stops[i] * (1 - f) + stops[i + 1] * f

def spec_img(x, sr, fmax=12000, n=4096, hop=256, db=80, logf=True, height=360):
    S = stft(x, n, hop); D = 20 * np.log10(S + 1e-9); D -= D.max()
    freqs = np.fft.rfftfreq(n, 1 / sr)
    if logf:
        fy = np.geomspace(40, fmax, height)
    else:
        fy = np.linspace(0, fmax, height)
    rows = np.array([np.interp(f, freqs, np.arange(len(freqs))) for f in fy])
    lo = np.floor(rows).astype(int); fr = rows - lo
    img = D[:, lo] * (1 - fr) + D[:, np.minimum(lo + 1, D.shape[1] - 1)] * fr
    img = ((img + db) / db).T[::-1]
    return cmap(img)

def save_specs(path, clips, sr, width=900, **kw):
    """clips: list of (label, samples) or (label, samples, sr). Stacks spectrograms vertically, each resampled to `width` columns."""
    panels = []
    for c in clips:
        x = c[1]; im = spec_img(x, c[2] if len(c) > 2 else sr, **kw)
        cols = np.linspace(0, im.shape[1] - 1, width).astype(int)
        panels.append(im[:, cols]); panels.append(np.full((6, width, 3), 255, np.float32))
    _png(path, np.concatenate(panels[:-1], axis=0))

def third_octave(x, sr, n=8192):
    S = stft(x, n, n // 4); P = (S ** 2).mean(axis=0); f = np.fft.rfftfreq(n, 1 / sr)
    centers = 1000 * 2 ** (np.arange(-17, 14) / 3)  # 20 Hz .. 20 kHz
    out = []
    for c in centers:
        m = (f >= c / 2 ** (1 / 6)) & (f < c * 2 ** (1 / 6))
        out.append(10 * np.log10(P[m].sum() + 1e-20))
    return centers, np.array(out)

def centroid(x, sr, n=2048):
    S = stft(x, n, n // 4); f = np.fft.rfftfreq(n, 1 / sr)
    return (S * f).sum(axis=1) / (S.sum(axis=1) + 1e-12)

def write_wav(path, x, sr):
    """16-bit PCM WAV, mono or (n, 2) stereo."""
    x = np.asarray(x, dtype=np.float32)
    ch = 1 if x.ndim == 1 else x.shape[1]
    data = (np.clip(x, -1, 1) * 32767).astype('<i2').tobytes()
    hdr = b'RIFF' + struct.pack('<I', 36 + len(data)) + b'WAVEfmt ' + struct.pack('<IHHIIHH', 16, 1, ch, sr, sr * ch * 2, ch * 2, 16)
    open(path, 'wb').write(hdr + b'data' + struct.pack('<I', len(data)) + data)
