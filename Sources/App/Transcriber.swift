import Foundation
import Accelerate
import AVFoundation

/// Works out tempo, key and a chord progression from a recording (e.g. a 30-second song preview).
/// Pipeline: onset envelope → tempo + dynamic-programming beat tracker → beat-synchronous
/// treble/bass chroma → key estimate → Viterbi over 24 major/minor chords with a key prior →
/// bars → repeating progression → easiest capo.
struct Transcription {
    struct Bar { var start: Double; var end: Double; var tokens: String }
    var bpm: Double
    var beatsPerBar: Int
    var keyRoot: Int
    var minorKey: Bool
    var bars: [Bar]
    var sections: [SongSection]
    var confidence: Double
    var capo: Int
    var duration: Double
    /// Strum pattern heard in the recording (D, U, - per slot across one bar).
    var strum: String = "D-DU-UDU"
    /// How sure we are about the strum (0–1).
    var strumClarity: Double = 0
    /// Playing feel: "strum", "reggae", "picked" or "power".
    var feel: String = "strum"

    // Beat-level detail, kept so a chord chart can be lined up against the recording.
    var beatTimes: [Double] = []
    var beatTreble: [[Float]] = []
    var beatBass: [[Float]] = []
    var beatRMS: [Float] = []
    /// Chord heard on each beat (0–11 major, 12–23 minor on that root).
    var beatPath: [Int] = []
    /// Index of the first downbeat.
    var barPhase = 0

    var keyName: String {
        let flat = Theory.flatKeys.contains(minorKey ? (keyRoot + 3) % 12 : keyRoot)
        return Theory.name(keyRoot, flat: flat) + (minorKey ? " minor" : " major")
    }
    var confidenceLabel: String { confidence > 0.62 ? "High" : (confidence > 0.42 ? "Medium" : "Low") }
}

enum TranscribeError: LocalizedError {
    case unreadable, tooQuiet, noBeat
    var errorDescription: String? {
        switch self {
        case .unreadable: return "Couldn't read that audio."
        case .tooQuiet: return "The recording is too quiet to analyse."
        case .noBeat: return "Couldn't find a steady beat in this recording."
        }
    }
}

enum Transcriber {

    // MARK: entry points

    /// `stage` is called with 1 (beat found), 2 (chords heard) and 3 (done).
    static func analyze(url: URL, stage: ((Int) -> Void)? = nil) throws -> Transcription {
        let (samples, sr) = try readMono(url)
        return try analyze(samples: samples, sampleRate: sr, stage: stage)
    }

    static func readMono(_ url: URL) throws -> ([Float], Double) {
        guard let file = try? AVAudioFile(forReading: url) else { throw TranscribeError.unreadable }
        let fmt = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { throw TranscribeError.unreadable }
        try file.read(into: buf)
        guard let ch = buf.floatChannelData else { throw TranscribeError.unreadable }
        let n = Int(buf.frameLength), chans = Int(fmt.channelCount)
        var mono = [Float](repeating: 0, count: n)
        for c in 0..<chans { vDSP_vadd(mono, 1, ch[c], 1, &mono, 1, vDSP_Length(n)) }
        var scale = 1 / Float(max(1, chans))
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))
        return (mono, fmt.sampleRate)
    }

    static func analyze(samples: [Float], sampleRate sr: Double, stage: ((Int) -> Void)? = nil) throws -> Transcription {
        guard samples.count > Int(sr * 4) else { throw TranscribeError.unreadable }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        guard peak > 0.003 else { throw TranscribeError.tooQuiet }

        // 1. beats
        let hop = 512
        let onset = onsetEnvelope(samples, n: 2048, hop: hop)
        let fps = sr / Double(hop)
        guard var period = tempoPeriod(onset, fps: fps) else { throw TranscribeError.noBeat }
        var bpm = 60 * fps / period
        var beatFrames = trackBeats(onset, period: period)
        guard beatFrames.count >= 8 else { throw TranscribeError.noBeat }
        var beatTimes = beatFrames.map { Double($0) / fps }

        stage?(1)

        // 2. chroma per beat
        let big = 16384, bigHop = 2048
        let frames = peakFrames(samples, sr: sr, n: big, hop: bigHop)
        let tuning = estimateTuning(frames)
        let frameChroma = frames.map { chroma(of: $0, tuning: tuning) }
        let frameTimes = (0..<frames.count).map { (Double($0 * bigHop) + Double(big) / 2) / sr }
        let frameRMS = rmsFrames(samples, n: big, hop: bigHop)

        // very fast tempos are usually double-time; fold to a strummable tempo
        if bpm > 165 {
            bpm /= 2; period *= 2
            beatFrames = stride(from: 0, to: beatFrames.count, by: 2).map { beatFrames[$0] }
            beatTimes = beatFrames.map { Double($0) / fps }
        }

        var beats: [(treble: [Float], bass: [Float], rms: Float)] = []
        for i in 0..<beatTimes.count {
            let a = beatTimes[i]
            let b = i + 1 < beatTimes.count ? beatTimes[i + 1] : a + period / fps
            var t = [Float](repeating: 0, count: 12), ba = t
            var r: Float = 0, cnt: Float = 0
            for (j, ft) in frameTimes.enumerated() where ft >= a && ft < b {
                vDSP_vadd(t, 1, frameChroma[j].0, 1, &t, 1, 12)
                vDSP_vadd(ba, 1, frameChroma[j].1, 1, &ba, 1, 12)
                r += frameRMS[j]; cnt += 1
            }
            if cnt == 0, let j = frameTimes.indices.min(by: { abs(frameTimes[$0] - (a + b) / 2) < abs(frameTimes[$1] - (a + b) / 2) }) {
                t = frameChroma[j].0; ba = frameChroma[j].1; r = frameRMS[j]; cnt = 1
            }
            beats.append((normalize(t), normalize(ba), r / max(1, cnt)))
        }

        // 3. key
        var total = [Float](repeating: 0, count: 12)
        for b in beats { for i in 0..<12 { total[i] += b.treble[i] + 0.5 * b.bass[i] } }
        var (keyRoot, minorKey) = estimateKey(total)

        // 4. chords per beat, then re-check the key against the chords actually heard
        let obs = beats.map { ($0.treble, $0.bass) }
        var (path, margin) = viterbi(obs, keyRoot: keyRoot, minorKey: minorKey)
        let refined = refineKey(path: path, chroma: total)
        if refined.0 != keyRoot || refined.1 != minorKey {
            (keyRoot, minorKey) = refined
            (path, margin) = viterbi(obs, keyRoot: keyRoot, minorKey: minorKey)
        }

        // chords that only change every 8+ beats at a fast tempo usually mean we counted double time
        var runs: [Int] = []
        var run = 1
        for i in 1..<path.count { if path[i] == path[i - 1] { run += 1 } else { runs.append(run); run = 1 } }
        let medianRun = runs.isEmpty ? path.count : runs.sorted()[runs.count / 2]
        if bpm >= 120 && medianRun >= 8 {
            bpm /= 2; period *= 2
            let keep = stride(from: 0, to: path.count, by: 2).map { $0 }
            path = keep.map { path[$0] }
            beatTimes = keep.map { beatTimes[$0] }
            beats = keep.map { beats[$0] }
        }

        stage?(2)

        // 5. meter and bar phase from where the chords change
        let changes = (1..<path.count).filter { path[$0] != path[$0 - 1] }
        func fit(_ m: Int) -> (phase: Int, frac: Double) {
            guard !changes.isEmpty else { return (0, 0) }
            var best = (phase: 0, frac: -1.0)
            for p in 0..<m {
                let hits: Int = changes.filter { $0 % m == p }.count
                let frac = Double(hits) / Double(changes.count)
                if frac > best.frac { best = (p, frac) }
            }
            return best
        }
        let f4 = fit(4), f3 = fit(3)
        // 3/4 needs real evidence: enough chord changes that land on a 3-beat grid
        let meter = (changes.count >= 6 && f3.frac > f4.frac + 0.18 && f3.frac > 0.7) ? 3 : 4
        let phase = meter == 3 ? f3.phase : f4.phase

        // second pass: chords change on the downbeat far more often than mid-bar
        let obs2 = beats.map { ($0.treble, $0.bass) }
        (path, margin) = viterbi(obs2, keyRoot: keyRoot, minorKey: minorKey) { b in
            let pos = ((b - phase) % meter + meter) % meter
            return pos == 0 ? 2.0 : (meter == 4 && pos == 2 ? 4.2 : 6.5)
        }

        // 6. bars
        let flat = Theory.flatKeys.contains(minorKey ? (keyRoot + 3) % 12 : keyRoot)
        func name(_ c: Int) -> String { chordName(c, flatKey: flat) }
        let medianRMS = beats.map(\.rms).sorted()[beats.count / 2]
        var bars: [Transcription.Bar] = []
        var b = phase
        while b + meter <= path.count {
            let seg = Array(path[b..<(b + meter)])
            let rms = beats[b..<(b + meter)].map(\.rms).reduce(0, +) / Float(meter)
            var counts: [Int: Int] = [:]
            for c in seg { counts[c, default: 0] += 1 }
            let top = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!
            var tokens: String
            if top.value >= meter - 1 {
                tokens = name(top.key)
            } else if meter == 4, seg[0] == seg[1], seg[2] == seg[3], seg[0] != seg[2] {
                tokens = "\(name(seg[0])):2 \(name(seg[2])):2"
            } else {
                tokens = name(seg[0] == seg[1] ? seg[0] : top.key)
            }
            let end = b + meter < beatTimes.count ? beatTimes[b + meter] : beatTimes[b] + Double(meter) * period / fps
            bars.append(.init(start: beatTimes[b], end: end, tokens: tokens))
            bars[bars.count - 1].tokens = tokens
            if rms < medianRMS * 0.3 { bars[bars.count - 1].tokens = "?" }
            b += meter
        }
        // drop quiet fade-in / fade-out bars
        while bars.first?.tokens == "?" { bars.removeFirst() }
        while bars.last?.tokens == "?" { bars.removeLast() }
        for i in bars.indices where bars[i].tokens == "?" { bars[i].tokens = i > 0 ? bars[i - 1].tokens : "C" }
        guard !bars.isEmpty else { throw TranscribeError.noBeat }

        // 7. sections
        let sections = makeSections(bars.map(\.tokens), keyRoot: keyRoot, minorKey: minorKey, flat: flat)

        // 8. easiest capo
        let capo = easiestCapo(Set(sections.flatMap { $0.tokens(beatsPerBar: meter).map(\.chord) }))

        // 9. the strumming rhythm, from attacks in the guitar's range (≈200 Hz – 3 kHz, mostly
        //    skipping kick drum and hi-hats)
        let mid = onsetEnvelope(samples, n: 2048, hop: hop, binRange: 10..<140)
        let rhythm = detectStrum(mid, fps: fps, beatTimes: beatTimes, phase: phase, meter: meter, bpm: bpm,
                                 quietBeats: Set(beats.indices.filter { beats[$0].rms < medianRMS * 0.3 }))

        stage?(3)
        var t = Transcription(bpm: bpm, beatsPerBar: meter, keyRoot: keyRoot, minorKey: minorKey, bars: bars, sections: sections,
                              confidence: Double(margin), capo: capo, duration: Double(samples.count) / sr)
        t.strum = rhythm.pattern
        t.strumClarity = rhythm.clarity
        t.feel = rhythm.feel
        t.beatTimes = Array(beatTimes.prefix(beats.count))
        t.beatTreble = beats.map(\.treble)
        t.beatBass = beats.map(\.bass)
        t.beatRMS = beats.map(\.rms)
        t.beatPath = path
        t.barPhase = phase
        return t
    }

    // MARK: onset & tempo

    static func onsetEnvelope(_ x: [Float], n: Int, hop: Int, binRange: Range<Int> = 1..<700) -> [Float] {
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let half = n / 2
        var prev = [Float](repeating: 0, count: half)
        var out: [Float] = []
        var re = [Float](repeating: 0, count: half), im = re, mags = re, w = window
        var start = 0
        while start + n <= x.count {
            x.withUnsafeBufferPointer { p in vDSP_vmul(p.baseAddress! + start, 1, window, 1, &w, 1, vDSP_Length(n)) }
            fft(&w, &re, &im, &mags, setup: setup, log2n: log2n)
            var one: Float = 1
            vDSP_vsadd(mags, 1, &one, &mags, 1, vDSP_Length(half))   // log(1 + |X|)
            var cnt = Int32(half)
            vvlogf(&mags, mags, &cnt)
            var flux: Float = 0
            for k in max(1, binRange.lowerBound)..<min(half, binRange.upperBound) { flux += max(0, mags[k] - prev[k]) }
            out.append(flux)
            prev = mags
            start += hop
        }
        // remove the slow trend, half-wave rectify, normalise
        let win = 16
        var res = [Float](repeating: 0, count: out.count)
        for i in out.indices {
            let a = max(0, i - win), b = min(out.count, i + win + 1)
            var mean: Float = 0
            out.withUnsafeBufferPointer { p in vDSP_meanv(p.baseAddress! + a, 1, &mean, vDSP_Length(b - a)) }
            res[i] = max(0, out[i] - mean)
        }
        var mean: Float = 0, sd: Float = 0
        vDSP_normalize(res, 1, nil, 1, &mean, &sd, vDSP_Length(res.count))
        if sd > 0 { res = res.map { $0 / sd } }
        return res
    }

    /// Beat period in onset frames, from autocorrelation with a prior around 115 BPM.
    static func tempoPeriod(_ o: [Float], fps: Double) -> Double? {
        let minLag = Int(fps * 60 / 200), maxLag = min(o.count / 3, Int(fps * 60 / 55))
        guard maxLag > minLag + 2 else { return nil }
        var ac = [Float](repeating: 0, count: maxLag + 2)
        for lag in minLag...maxLag + 1 {
            var s: Float = 0
            o.withUnsafeBufferPointer { p in vDSP_dotpr(p.baseAddress!, 1, p.baseAddress! + lag, 1, &s, vDSP_Length(o.count - lag)) }
            ac[lag] = s / Float(o.count - lag)
        }
        var best = -1, bestV: Float = -.infinity
        for lag in (minLag + 1)...maxLag {
            let bpm = 60 * fps / Double(lag)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 115) / 0.9, 2)))
            // reward lags whose double also correlates (metrical consistency)
            let dbl = 2 * lag <= maxLag + 1 ? ac[2 * lag] * 0.5 : 0
            let v = (ac[lag] + dbl) * prior
            if v > bestV, ac[lag] >= ac[lag - 1], ac[lag] >= ac[lag + 1] { bestV = v; best = lag }
        }
        guard best > 0 else { return nil }
        let a = ac[best - 1], b = ac[best], c = ac[best + 1]
        let d = a - 2 * b + c
        return Double(best) + (d != 0 ? Double(0.5 * (a - c) / d) : 0)
    }

    /// Ellis (2007) dynamic-programming beat tracker.
    static func trackBeats(_ o: [Float], period: Double, tightness: Double = 120) -> [Int] {
        let n = o.count
        var score = o.map(Double.init)
        var back = [Int](repeating: -1, count: n)
        let lo = Int(period / 2), hi = Int(period * 2)
        for t in 0..<n {
            var best = -Double.infinity, arg = -1
            let a = max(0, t - hi), b = t - lo
            if b > a {
                for tau in a..<b {
                    let pen = log(Double(t - tau) / period)
                    let v = score[tau] - tightness * pen * pen
                    if v > best { best = v; arg = tau }
                }
            }
            if arg >= 0 && best > 0 { score[t] += best; back[t] = arg }
        }
        let tailStart = max(0, n - Int(period))
        var t = (tailStart..<n).max { score[$0] < score[$1] } ?? (n - 1)
        var beats: [Int] = []
        while t >= 0 { beats.append(t); t = back[t] }
        return beats.reversed()
    }

    // MARK: spectra & chroma

    struct Peak { var midi: Float; var mag: Float }

    static func peakFrames(_ x: [Float], sr: Double, n: Int, hop: Int) -> [[Peak]] {
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let half = n / 2
        let binHz = Float(sr) / Float(n)
        let kMin = max(2, Int(38 / binHz)), kMax = min(half - 2, Int(1800 / binHz))
        var re = [Float](repeating: 0, count: half), im = re, mags = re, w = window
        var out: [[Peak]] = []
        var start = 0
        while start + n <= x.count {
            x.withUnsafeBufferPointer { p in vDSP_vmul(p.baseAddress! + start, 1, window, 1, &w, 1, vDSP_Length(n)) }
            fft(&w, &re, &im, &mags, setup: setup, log2n: log2n)
            var mx: Float = 0
            mags.withUnsafeBufferPointer { p in vDSP_maxv(p.baseAddress! + kMin, 1, &mx, vDSP_Length(kMax - kMin)) }
            var peaks: [Peak] = []
            if mx > 0 {
                let th = mx * 0.015
                for k in kMin...kMax {
                    let m = mags[k]
                    guard m > th, m > mags[k - 1], m >= mags[k + 1] else { continue }
                    let a = mags[k - 1], g = mags[k + 1]
                    let d = a - 2 * m + g
                    let p: Float = d != 0 ? 0.5 * (a - g) / d : 0
                    let f = (Float(k) + p) * binHz
                    peaks.append(Peak(midi: 69 + 12 * log2(f / 440), mag: m / mx))
                }
            }
            out.append(peaks)
            start += hop
        }
        return out
    }

    /// Global tuning offset in semitones (recordings are often a little off A440).
    static func estimateTuning(_ frames: [[Peak]]) -> Float {
        var sx: Float = 0, sy: Float = 0
        for f in frames { for p in f where p.mag > 0.1 {
            let ang = 2 * Float.pi * (p.midi - p.midi.rounded())
            sx += p.mag * cos(ang); sy += p.mag * sin(ang)
        } }
        return atan2(sy, sx) / (2 * .pi)
    }

    static func chroma(of peaks: [Peak], tuning: Float) -> ([Float], [Float]) {
        var treble = [Float](repeating: 0, count: 12), bass = treble
        for p in peaks {
            let m = p.midi - tuning
            let r = m.rounded()
            let close = max(0, 1 - abs(m - r) * 2.2)
            guard close > 0 else { continue }
            let pc = ((Int(r) % 12) + 12) % 12
            let v = sqrt(p.mag) * close
            if m < 55 { bass[pc] += v }                     // below ~G3
            if m >= 45 && m < 88 { treble[pc] += v * (m < 72 ? 1 : 0.6) }
        }
        return (treble, bass)
    }

    static func rmsFrames(_ x: [Float], n: Int, hop: Int) -> [Float] {
        var out: [Float] = []
        var start = 0
        while start + n <= x.count {
            var r: Float = 0
            x.withUnsafeBufferPointer { p in vDSP_rmsqv(p.baseAddress! + start, 1, &r, vDSP_Length(n)) }
            out.append(r)
            start += hop
        }
        return out
    }

    private static func fft(_ w: inout [Float], _ re: inout [Float], _ im: inout [Float], _ mags: inout [Float], setup: FFTSetup, log2n: vDSP_Length) {
        let half = w.count / 2
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            w.withUnsafeBufferPointer { wp in
                wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
            }
            vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
        } }
    }

    private static func normalize(_ v: [Float]) -> [Float] {
        let m = v.max() ?? 0
        return m > 0 ? v.map { $0 / m } : v
    }

    // MARK: key & chords

    static let majorProfile: [Float] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let minorProfile: [Float] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func estimateKey(_ chroma: [Float]) -> (Int, Bool) {
        func corr(_ a: [Float], _ b: [Float]) -> Float {
            let ma = a.reduce(0, +) / 12, mb = b.reduce(0, +) / 12
            var num: Float = 0, da: Float = 0, db: Float = 0
            for i in 0..<12 { num += (a[i] - ma) * (b[i] - mb); da += (a[i] - ma) * (a[i] - ma); db += (b[i] - mb) * (b[i] - mb) }
            return num / max(1e-6, sqrt(da * db))
        }
        var best: (Int, Bool) = (0, false), bv: Float = -2
        for r in 0..<12 {
            let rot = (0..<12).map { chroma[($0 + r) % 12] }
            let maj = corr(rot, majorProfile), mi = corr(rot, minorProfile)
            if maj > bv { bv = maj; best = (r, false) }
            if mi > bv { bv = mi; best = (r, true) }
        }
        return best
    }

    /// Chord index: 0–11 major on that root, 12–23 minor on (index − 12).
    static func diatonicBonus(_ c: Int, keyRoot: Int, minorKey: Bool) -> Float {
        let root = c % 12, minor = c >= 12
        let deg = ((root - keyRoot) % 12 + 12) % 12
        if !minorKey {
            switch (deg, minor) {
            case (0, false), (5, false), (7, false): return 0.09
            case (9, true): return 0.08
            case (2, true), (4, true): return 0.05
            case (10, false), (2, false), (4, false): return 0.015   // bVII, II, III — common borrowings
            default: return 0
            }
        } else {
            switch (deg, minor) {
            case (0, true): return 0.09
            case (3, false), (8, false), (10, false): return 0.08
            case (5, true), (7, true), (7, false): return 0.05
            case (5, false): return 0.015
            default: return 0
            }
        }
    }

    /// Guitar-friendly spelling: Bb, Eb and Ab but C#, F# and G#m, unless the key uses flats.
    static func chordName(_ c: Int, flatKey: Bool) -> String {
        let pc = c % 12, minor = c >= 12
        let flat = flatKey || pc == 10 || pc == 3 || (pc == 8 && !minor)
        return Theory.name(pc, flat: flat) + (minor ? "m" : "")
    }

    /// Key that best fits both the overall pitch content and the chords heard.
    static func refineKey(path: [Int], chroma: [Float]) -> (Int, Bool) {
        var best = (0, false), bv: Float = -10
        for r in 0..<12 { for minor in [false, true] {
            let rot = (0..<12).map { chroma[($0 + r) % 12] }
            let prof = minor ? minorProfile : majorProfile
            let ma = rot.reduce(0, +) / 12, mb = prof.reduce(0, +) / 12
            var num: Float = 0, da: Float = 0, db: Float = 0
            for i in 0..<12 { num += (rot[i] - ma) * (prof[i] - mb); da += (rot[i] - ma) * (rot[i] - ma); db += (prof[i] - mb) * (prof[i] - mb) }
            let corr = num / max(1e-6, sqrt(da * db))
            var fit: Float = 0
            for c in path { fit += diatonicBonus(c, keyRoot: r, minorKey: minor) > 0.03 ? 1 : 0 }
            fit /= Float(max(1, path.count))
            // the first and last chords are often home
            var home: Float = 0
            let tonic = minor ? 12 + r : r
            if path.first == tonic { home += 0.06 }
            if path.last == tonic { home += 0.06 }
            let v = corr * 0.5 + fit + home
            if v > bv { bv = v; best = (r, minor) }
        } }
        return best
    }

    static func viterbi(_ obs: [([Float], [Float])], keyRoot: Int, minorKey: Bool,
                        changeCost: (Int) -> Float = { _ in 2.6 }) -> ([Int], Float) {
        let templates: [[Float]] = (0..<24).map { c in
            let r = c % 12
            let tones = c >= 12 ? [r, (r + 3) % 12, (r + 7) % 12] : [r, (r + 4) % 12, (r + 7) % 12]
            var t = [Float](repeating: 0, count: 12)
            t[tones[0]] = 1; t[tones[1]] = 0.8; t[tones[2]] = 0.8
            let norm = sqrt(t.reduce(0) { $0 + $1 * $1 })
            return t.map { $0 / norm }
        }
        let bonus = (0..<24).map { diatonicBonus($0, keyRoot: keyRoot, minorKey: minorKey) }
        var emis: [[Float]] = []
        var marginSum: Float = 0
        for (tr, ba) in obs {
            let n = sqrt(tr.reduce(0) { $0 + $1 * $1 })
            let v = n > 0 ? tr.map { $0 / n } : tr
            let s: [Float] = (0..<24).map { c in
                var dot: Float = 0
                for i in 0..<12 { dot += v[i] * templates[c][i] }
                let r = c % 12
                let third = c >= 12 ? (r + 3) % 12 : (r + 4) % 12
                return dot + 0.18 * ba[r] - 0.1 * ba[third] + bonus[c]
            }
            let sorted = s.sorted(by: >)
            marginSum += min(1, (sorted[0] - sorted[1]) * 8)
            emis.append(s)
        }
        let k: Float = 14
        var delta = emis[0].map { $0 * k }
        var back: [[Int]] = []
        for t in 1..<emis.count {
            let bestPrev = delta.indices.max { delta[$0] < delta[$1] }!
            let change = changeCost(t)
            var nd = [Float](repeating: 0, count: 24), bk = [Int](repeating: 0, count: 24)
            for c in 0..<24 {
                let stay = delta[c], move = delta[bestPrev] - change
                if stay >= move { nd[c] = stay; bk[c] = c } else { nd[c] = move; bk[c] = bestPrev }
                nd[c] += emis[t][c] * k
            }
            delta = nd; back.append(bk)
        }
        var c = delta.indices.max { delta[$0] < delta[$1] }!
        var path = [c]
        for bk in back.reversed() { c = bk[c]; path.append(c) }
        return (path.reversed(), marginSum / Float(max(1, obs.count)) + 0.3)
    }

    // MARK: strumming rhythm

    static var debugRhythm = false

    /// Averages attack strength at every 16th-note position of the bar across the recording,
    /// then writes the strong positions as a down/up pattern (down on the beat, up on the "&").
    static func detectStrum(_ env: [Float], fps: Double, beatTimes: [Double], phase: Int, meter: Int, bpm: Double,
                            quietBeats: Set<Int>) -> (pattern: String, clarity: Double, feel: String) {
        let fallback = (meter == 3 ? "D-DUDU" : "D-DU-UDU", 0.0, "strum")
        guard env.count > 10, beatTimes.count > phase + meter * 2 else { return fallback }
        let slots = meter * 4
        var profile = [Double](repeating: 0, count: slots)
        var bars = 0
        var b = phase
        while b + meter < beatTimes.count {
            if (b..<(b + meter)).contains(where: { quietBeats.contains($0) }) { b += meter; continue }
            var row = [Double](repeating: 0, count: slots)
            for j in 0..<slots {
                let beat = b + j / 4
                let len = beatTimes[beat + 1] - beatTimes[beat]
                let t = beatTimes[beat] + Double(j % 4) / 4 * len
                let lo = max(0, Int((t - 0.035) * fps)), hi = min(env.count - 1, Int((t + 0.035) * fps))
                guard hi >= lo else { continue }
                row[j] = Double(env[lo...hi].max() ?? 0)
            }
            let mx = row.max() ?? 0
            if mx > 0 { for j in 0..<slots { profile[j] += row[j] / mx } }
            bars += 1
            b += meter
        }
        guard bars >= 2 else { return fallback }
        profile = profile.map { $0 / Double(bars) }
        let top = profile.max() ?? 1
        profile = profile.map { $0 / max(1e-6, top) }
        if debugRhythm { print("      16ths:", profile.map { String(format: "%.2f", $0) }.joined(separator: " ")) }

        // the in-between 16th positions ("e" and "a") are the background level in 8th-note playing
        let between = stride(from: 1, to: slots, by: 2).map { profile[$0] }
        let floor = between.reduce(0, +) / Double(between.count)
        let use16 = bpm <= 104 && floor > 0.3
        let grid: [Double] = use16 ? profile : stride(from: 0, to: slots, by: 2).map { profile[$0] }
        let reference = use16 ? 0.05 : floor
        let onIdx = stride(from: 0, to: grid.count, by: 2).map { $0 }
        let onSorted = onIdx.map { grid[$0] }.sorted()
        let onMedian = onSorted[onSorted.count / 2]
        let offThreshold = reference + max(0.1, 0.25 * (onMedian - reference))
        // beats nearly always carry a strum (drums blur them, so only drop near-silent ones);
        // off-beats are up-strums when they clearly rise above the background
        var chars: [Character] = grid.enumerated().map { j, v in
            if j % 2 == 0 { return v >= max(0.25, reference * 3) ? "D" : "-" }
            return v >= offThreshold ? "U" : "-"
        }
        chars[0] = "D"   // the bar always starts with a strum
        let feel = "strum"
        let threshold = offThreshold
        var pattern = String(chars)
        // use a known pattern's name when exactly one is within a single slot
        let near = StrumPattern.library.filter { $0.beatsPerBar == meter && $0.pattern.count == pattern.count }
            .map { p in (p, zip(p.pattern, pattern).filter { $0 != $1 }.count) }
        if !near.contains(where: { $0.1 == 0 }) {
            let close = near.filter { $0.1 == 1 }
            if close.count == 1 { pattern = close[0].0.pattern }
        }
        // clarity: how far apart strong and weak positions are
        let strong = grid.filter { $0 >= threshold }, weak = grid.filter { $0 < threshold }
        let clarity = strong.isEmpty || weak.isEmpty ? 0.3 :
            min(1, (strong.reduce(0, +) / Double(strong.count) - weak.reduce(0, +) / Double(weak.count)) * 1.6)
        return (pattern, clarity, feel)
    }

    // MARK: structure

    static func makeSections(_ bars: [String], keyRoot: Int, minorKey: Bool, flat: Bool) -> [SongSection] {
        let n = bars.count
        // shortest period that explains most of the bars
        // a whole song can cycle through a longer progression (say a 12- or 16-bar verse and chorus)
        for p in [1, 2, 3, 4, 6, 8] + (n >= 32 ? [12, 16] : []) where p * (p >= 12 ? 3 : 2) <= n {
            let matches = (p..<n).filter { bars[$0] == bars[$0 - p] }.count
            let rate = Double(matches) / Double(n - p)
            guard rate >= 0.72 else { continue }
            if p == 1 && Set(bars).count > 1 { continue }
            var loop = (0..<p).map { i -> String in
                let col = stride(from: i, to: n, by: p).map { bars[$0] }
                var counts: [String: Int] = [:]
                for c in col { counts[c, default: 0] += 1 }
                return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
            }
            // start the loop on the home chord if it's in there
            let tonic = chordName(minorKey ? 12 + keyRoot : keyRoot, flatKey: flat)
            if let i = loop.firstIndex(where: { $0.split(separator: ":").first.map(String.init) == tonic }) {
                loop = Array(loop[i...] + loop[..<i])
            }
            // a 1- or 2-bar loop reads better written out over 4 bars
            while loop.count < 4 && 4 % loop.count == 0 { loop += loop }
            let repeats = max(2, Int((Double(n) / Double(loop.count)).rounded()))
            return [SongSection(name: "Main progression", chords: loop.joined(separator: " "), repeats: repeats)]
        }
        // no clear loop: 4-bar lines, identical neighbours become repeats, identical lines share a name
        func close(_ a: [Substring], _ b: [Substring]) -> Bool { a.count == b.count && a.count >= 4 && zip(a, b).filter { $0 != $1 }.count <= 1 }
        func split(from k: Int) -> [String] {
            var ls: [String] = k > 0 ? [bars[0..<k].joined(separator: " ")] : []
            ls += stride(from: k, to: n, by: 4).map { bars[$0..<min(n, $0 + 4)].joined(separator: " ") }
            if ls.count > 1, ls.last!.split(separator: " ").count < 2 { ls.removeLast() }
            return ls
        }
        var lines = split(from: 0)
        var lead = 0
        if n >= 32 {
            // a whole song: start the 4-bar phrases where they repeat best (any bars before that are the intro),
            // and treat a line that's one bar off a line already heard as that line, misheard
            func snapped(_ ls: [String]) -> (lines: [String], repeats: Int) {
                var seen: [String] = [], out = ls, hits = 0
                for i in ls.indices {
                    let bs = ls[i].split(separator: " ")
                    if let same = seen.first(where: { close($0.split(separator: " "), bs) }) { out[i] = same; hits += 1 } else { seen.append(ls[i]) }
                }
                return (out, hits)
            }
            let best = (0..<4).map { k in (k, snapped(split(from: k))) }.max { $0.1.repeats < $1.1.repeats }!
            lead = best.0
            lines = best.1.lines
        }
        var names: [String: String] = [:]
        var out: [SongSection] = []
        for (i, l) in lines.enumerated() {
            if i == 0 && lead > 0 { out.append(SongSection(name: "Intro", chords: l)); continue }
            if names[l] == nil { names[l] = "Part \(Character(UnicodeScalar(65 + min(25, names.count))!))" }
            if var last = out.last, last.chords == l {
                last.repeats += 1
                out[out.count - 1] = last
            } else {
                out.append(SongSection(name: names[l]!, chords: l))
            }
        }
        return out
    }

    /// The capo fret (0–5) that turns the chords into the easiest shapes.
    static func easiestCapo(_ chords: Set<String>) -> Int {
        func cost(_ c: Int) -> Int {
            chords.reduce(0) { sum, name in
                guard let sym = ChordSymbol.parse(name) else { return sum }
                let shape = sym.transposed(by: -c, preferFlat: false).displayName
                return sum + (ChordLibrary.shape(for: shape) == nil ? 4 : ChordLibrary.level(of: shape))
            }
        }
        let base = cost(0)
        var best = 0, bestCost = base
        for c in 1...5 {
            let v = cost(c)
            if v < bestCost { best = c; bestCost = v }
        }
        // only worth a capo if it really makes it easier
        return base - bestCost >= 2 ? best : 0
    }

    /// Turns an analysis into a playable song.
    static func song(from t: Transcription, title: String, artist: String, genre: String, capo: Int? = nil,
                     note: String? = nil, wholeSong: Bool = false) -> Song {
        let useCapo = capo ?? t.capo
        var t = t
        if genre == "Reggae" && t.beatsPerBar == 4 { t.strum = "-U-U-U-U"; t.feel = "reggae" }
        var s = Song(id: "custom-\(UUID().uuidString.prefix(8))", title: title, artist: artist, genre: genre,
                     bpm: Int(t.bpm.rounded()), beatsPerBar: t.beatsPerBar, capo: 0,
                     strum: t.strum,
                     sections: t.sections, isCustom: true,
                     note: note ?? "Chords and strum worked out automatically from the song's preview — check them by ear and tap Edit to fix anything.",
                     feel: t.feel)
        // a preview is only ~30 s; repeat the progression so there's about a minute to practise
        if wholeSong {
            // already the full song
        } else if s.sections.count == 1, s.duration > 0, s.duration < 55 {
            let perPass = s.duration / Double(max(1, s.sections[0].repeats))
            s.sections[0].repeats = max(s.sections[0].repeats, Int((60 / perPass).rounded(.up)))
        } else if s.duration > 0, s.duration < 55 {
            // several parts: play the whole thing through again until it's about a minute
            let passes = Int((60 / s.duration).rounded(.up))
            s.sections = Array(repeating: s.sections, count: passes).flatMap { $0 }
        }
        if useCapo > 0 {
            s = s.transposed(by: -useCapo)
            s.capo = useCapo
        }
        return s
    }
}
