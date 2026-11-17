import Foundation
import Accelerate

/// One note of a song's melody, on the same beat timeline as its chords (beat 0 = the first chord).
/// Like single-note tokens, `midi` is written relative to the capo: it sounds `capo` semitones higher.
struct MelodyNote: Codable, Hashable {
    var start: Double
    var beats: Double
    var midi: Int
    var end: Double { start + beats }

    enum CodingKeys: String, CodingKey { case start = "b", beats = "d", midi = "m" }
}

/// A melody note heard in a recording, in seconds.
struct HeardNote: Hashable {
    var start: Double
    var end: Double
    var midi: Int
    /// How clearly it stood out (0–1).
    var strength: Float
}

/// Finds the tune of a song (usually the lead vocal) in a full mix.
///
/// Pipeline: short-time spectrum → spectral peaks, weighted towards sound panned to the centre of
/// the stereo image (where lead vocals sit) → harmonic-sum pitch salience over a singer's range →
/// Viterbi tracking with a voiced/unvoiced state (smooth pitch, few jumps) → notes, split where the
/// voice dips between syllables → snapped to the song's beat grid → cleaned up for a guitar.
enum MelodyExtractor {
    /// Lowest and highest pitch searched (G2 to D6), in fifth-of-a-semitone steps.
    static let lowMidi: Float = 43, highMidi: Float = 86
    static let binsPerSemitone = 5
    static var binCount: Int { Int((highMidi - lowMidi) * Float(binsPerSemitone)) + 1 }
    static let hopSeconds = 0.01
    /// Weight of each further harmonic, and the power partial magnitudes are raised to
    /// (below 1 lets a pitch's number of matching harmonics count for more than one loud partial).
    static let harmonicDecay: Float = 0.85
    static let partialPower: Float = 0.85
    /// Notes weaker than this must show some pitch movement to count as sung.
    static let steadyCutoff: Float = 0.7
    /// Move a note down an octave when the octave below scores at least this share of it.
    static let octaveCutoff: Float = 0.8
    /// Note tracking: how far (semitones) a frame can sit from its note before it costs much, the cost
    /// of changing note, the per-frame cost of a note outside the key, and the longest glide (frames).
    /// Below `lowFullWeight` (MIDI) pitches count less, down to `lowFloor` at G2: the bass lives down
    /// there, but so do the lowest notes of baritones.
    static let lowFloor: Float = 0.15
    static let lowFullWeight: Float = 52
    static let noteSpread: Float = 0.5
    static let noteChange: Float = 10
    static let outOfKey: Float = 0.5
    static let glideFrames = 12

    // MARK: extraction

    /// - Parameters:
    ///   - mono: (L + R) / 2.  - side: (L − R) / 2, if the recording is stereo; lets the centre stand out.
    ///   - tuning: the recording's offset from A440 in semitones (see `Transcriber.estimateTuning`).
    ///   - keyRoot, minorKey: the song's key, when known; a pitch right between two notes leans to the one in the key.
    static func extract(mono: [Float], side: [Float]? = nil, sampleRate sr: Double, tuning: Float = 0,
                        keyRoot: Int? = nil, minorKey: Bool = false) -> [HeardNote] {
        let sal = salience(mono: mono, side: side, sampleRate: sr)
        guard !sal.frames.isEmpty else { return [] }
        let path = track(sal.frames, reference: sal.reference)
        return notes(path: path, frames: sal.frames, reference: sal.reference, tuning: tuning, keyRoot: keyRoot, minorKey: minorKey)
    }

    struct Salience {
        /// Per frame, salience of each pitch bin.
        var frames: [[Float]]
        /// A typical "clearly sung" salience level for this recording.
        var reference: Float
    }

    static func salience(mono: [Float], side: [Float]?, sampleRate sr: Double) -> Salience {
        // ~46 ms window, zero-padded 4× so peak frequencies come out precise
        let win = 1 << Int((log2(sr * 0.046)).rounded())
        let n = win * 4
        let log2n = vDSP_Length(log2(Double(n)))
        let hop = max(1, Int((sr * hopSeconds).rounded()))
        guard mono.count > win + hop, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return Salience(frames: [], reference: 1) }
        defer { vDSP_destroy_fftsetup(setup) }
        let stereo = side.map { $0.count == mono.count } ?? false

        var window = [Float](repeating: 0, count: win)
        vDSP_hann_window(&window, vDSP_Length(win), Int32(vDSP_HANN_NORM))
        let half = n / 2
        let binHz = Float(sr) / Float(n)
        let kMin = max(2, Int(80 / binHz)), kMax = min(half - 2, Int(5000 / binHz))
        var buf = [Float](repeating: 0, count: n)
        var re = [Float](repeating: 0, count: half), im = re
        var mags = re, sideMags = re
        let bins = binCount
        let bps = Float(binsPerSemitone)
        let harmonics = 10
        let alpha = harmonicDecay
        let hWeight = (0..<harmonics).map { pow(alpha, Float($0)) }
        // a singer's range gets full weight; very low pitches (bass, guitar roots) much less
        let prior: [Float] = (0..<bins).map { b in
            let m = lowMidi + Float(b) / bps
            if m < lowFullWeight { return lowFloor + (1 - lowFloor) * max(0, (m - 43) / (lowFullWeight - 43)) }
            if m > 81 { return max(0.4, 1 - (m - 81) / 10) }
            return 1
        }

        func spectrum(_ x: [Float], at start: Int, into out: inout [Float]) {
            for i in 0..<n { buf[i] = 0 }
            x.withUnsafeBufferPointer { p in vDSP_vmul(p.baseAddress! + start, 1, window, 1, &buf, 1, vDSP_Length(win)) }
            re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &out, 1, vDSP_Length(half))
            } }
        }

        var frames: [[Float]] = []
        frames.reserveCapacity((mono.count - win) / hop + 1)
        var peakMax: [Float] = []
        var start = 0
        var sal = [Float](repeating: 0, count: bins), fund = sal
        while start + win <= mono.count {
            for b in 0..<bins { sal[b] = 0; fund[b] = 0 }
            var rms: Float = 0
            mono.withUnsafeBufferPointer { p in vDSP_rmsqv(p.baseAddress! + start, 1, &rms, vDSP_Length(win)) }
            if rms > 0.002 {
                spectrum(mono, at: start, into: &mags)
                if stereo, let side {
                    spectrum(side, at: start, into: &sideMags)
                    // keep what's in the middle of the stereo picture: weight = (|M|² − |S|²) / (|M|² + |S|²),
                    // 1 for centre-panned sound, 0 for hard-panned or wide, decorrelated sound
                    for k in kMin - 1...kMax + 1 {
                        let m2 = mags[k] * mags[k], s2 = sideMags[k] * sideMags[k]
                        let c = max(0, (m2 - s2) / (m2 + s2 + 1e-12))
                        mags[k] *= c
                    }
                }
                var mx: Float = 0
                mags.withUnsafeBufferPointer { p in vDSP_maxv(p.baseAddress! + kMin, 1, &mx, vDSP_Length(kMax - kMin)) }
                if mx > 0 {
                    let th = mx * 0.01           // peaks within 40 dB of the loudest
                    for k in kMin...kMax {
                        let m = mags[k]
                        guard m > th, m > mags[k - 1], m >= mags[k + 1] else { continue }
                        let a = mags[k - 1], g = mags[k + 1]
                        let d = a - 2 * m + g
                        let p: Float = d != 0 ? 0.5 * (a - g) / d : 0
                        let f = (Float(k) + p) * binHz
                        let amp = pow(m - 0.25 * (a - g) * p, partialPower)
                        let pm = 69 + 12 * log2(f / 440)
                        // spread this partial to every pitch it could be harmonic h of
                        for h in 0..<harmonics {
                            let f0m = pm - 12 * log2(Float(h + 1))
                            let centre = (f0m - lowMidi) * bps
                            if centre < -bps { break }
                            if centre > Float(bins - 1) + bps { continue }
                            let lo = max(0, Int((centre - bps).rounded(.up))), hi = min(bins - 1, Int((centre + bps).rounded(.down)))
                            guard lo <= hi else { continue }
                            for b in lo...hi {
                                let dist = (Float(b) - centre) / bps          // in semitones, −1…1
                                let c = cos(dist * .pi / 2)
                                let v = amp * hWeight[h] * c * c
                                sal[b] += v
                                if h == 0 { fund[b] += v }
                            }
                        }
                    }
                }
                // a pitch whose own fundamental is missing is usually an octave (or fifth) below the real one
                var top: Float = 0
                for b in 0..<bins {
                    let hasRoot = sal[b] > 0 ? min(1, fund[b] / (0.2 * sal[b])) : 0
                    sal[b] *= prior[b] * (0.4 + 0.6 * hasRoot)
                    top = max(top, sal[b])
                }
                peakMax.append(top)
            } else {
                peakMax.append(0)
            }
            frames.append(sal)
            start += hop
        }
        let loud = peakMax.filter { $0 > 0 }.sorted()
        let reference = loud.isEmpty ? 1 : loud[min(loud.count - 1, Int(Double(loud.count) * 0.9))]
        return Salience(frames: frames, reference: max(1e-6, reference))
    }

    /// Best pitch path through the salience: a bin per frame, or -1 when nothing is sung.
    /// Pitch moves cost in proportion to their size, so the path follows one voice instead of
    /// hopping between instruments; going silent and coming back costs a fixed amount.
    static func track(_ frames: [[Float]], reference: Float) -> [Int] {
        let bins = binCount
        let T = frames.count
        guard T > 0 else { return [] }
        let jump: Float = 0.06        // per fifth-of-a-semitone moved
        let voicing: Float = 1.2      // to start or stop singing
        let silentScore = log(Float(0.3))
        var score = [Float](repeating: 0, count: bins + 1)       // last = unvoiced
        var back = [Int16](repeating: 0, count: T * (bins + 1))
        var left = [Float](repeating: 0, count: bins), leftArg = [Int](repeating: 0, count: bins)
        var right = left, rightArg = leftArg
        func emit(_ s: Float) -> Float { log(max(s / reference, 1e-4)) }
        for b in 0..<bins { score[b] = emit(frames[0][b]) - voicing }
        score[bins] = silentScore
        var next = score
        for t in 1..<T {
            // best voiced predecessor for every bin with a linear jump cost, in two sweeps
            left[0] = score[0]; leftArg[0] = 0
            for b in 1..<bins {
                let carry = left[b - 1] - jump
                if carry > score[b] { left[b] = carry; leftArg[b] = leftArg[b - 1] } else { left[b] = score[b]; leftArg[b] = b }
            }
            right[bins - 1] = score[bins - 1]; rightArg[bins - 1] = bins - 1
            for b in stride(from: bins - 2, through: 0, by: -1) {
                let carry = right[b + 1] - jump
                if carry > score[b] { right[b] = carry; rightArg[b] = rightArg[b + 1] } else { right[b] = score[b]; rightArg[b] = b }
            }
            let fromSilence = score[bins] - voicing
            let row = t * (bins + 1)
            let f = frames[t]
            var bestVoiced: Float = -.infinity, bestVoicedArg = 0
            for b in 0..<bins {
                var v = left[b], arg = leftArg[b]
                if right[b] > v { v = right[b]; arg = rightArg[b] }
                if fromSilence > v { v = fromSilence; arg = bins }
                next[b] = v + emit(f[b])
                back[row + b] = Int16(arg)
                if score[b] > bestVoiced { bestVoiced = score[b]; bestVoicedArg = b }
            }
            if score[bins] >= bestVoiced - voicing {
                next[bins] = score[bins] + silentScore; back[row + bins] = Int16(bins)
            } else {
                next[bins] = bestVoiced - voicing + silentScore; back[row + bins] = Int16(bestVoicedArg)
            }
            // keep numbers small
            let m = next.max() ?? 0
            for i in 0...bins { score[i] = next[i] - m }
        }
        var state = score.indices.max { score[$0] < score[$1] } ?? bins
        var path = [Int](repeating: -1, count: T)
        for t in stride(from: T - 1, through: 0, by: -1) {
            path[t] = state == bins ? -1 : state
            if t > 0 { state = Int(back[t * (bins + 1) + state]) }
        }
        return path
    }

    /// Turns a pitch path into notes. A note-level Viterbi decides which semitone each stretch of
    /// singing is (vibrato, scoops and a singer sitting between two pitches don't flip it back and
    /// forth), then short glides are folded into the note they slide to, dips in strength split
    /// repeated notes, and weak, dead-steady notes (the band) are dropped.
    static func notes(path: [Int], frames: [[Float]], reference: Float, tuning: Float,
                      keyRoot: Int? = nil, minorKey: Bool = false) -> [HeardNote] {
        let bins = binCount
        let bps = Float(binsPerSemitone)
        let T = path.count
        // fine pitch (salience-weighted around the chosen bin) and strength per voiced frame
        var pitch = [Float](repeating: .nan, count: T), strength = [Float](repeating: 0, count: T)
        // how well the octave below explains the same sound (its harmonics include all of this pitch's)
        var lower = [Float](repeating: 0, count: T)
        let octave = 12 * binsPerSemitone
        for t in 0..<T where path[t] >= 0 {
            let b = path[t]
            var w: Float = 0, s: Float = 0
            for k in max(0, b - 2)...min(bins - 1, b + 2) { w += frames[t][k]; s += frames[t][k] * Float(k) }
            let fb = w > 0 ? s / w : Float(b)
            pitch[t] = lowMidi + fb / bps - tuning
            // strength around the pitch, so vibrato moving between bins doesn't look like the voice dipping
            var near: Float = 0
            for k in max(0, b - 3)...min(bins - 1, b + 3) { near = max(near, frames[t][k]) }
            strength[t] = min(1, near / reference)
            if b >= octave {
                var below: Float = 0
                for k in max(0, b - octave - 2)...(b - octave + 2) { below = max(below, frames[t][k]) }
                lower[t] = near > 0 ? below / near : 0
            }
        }
        // the singer's own tuning: singers (and older recordings) often sit a little off the band's
        // A440 grid, which would put held notes right between two semitones
        var sx: Float = 0, sy: Float = 0, sw: Float = 0
        for t in 0..<T where !pitch[t].isNaN && strength[t] > 0.4 {
            let ang = 2 * Float.pi * (pitch[t] - pitch[t].rounded())
            sx += strength[t] * cos(ang); sy += strength[t] * sin(ang); sw += strength[t]
        }
        if sw > 0, (sx * sx + sy * sy).squareRoot() / sw > 0.2 {
            let offset = atan2(sy, sx) / (2 * .pi)
            for t in 0..<T where !pitch[t].isNaN { pitch[t] -= offset }
        }
        let scale: Set<Int>? = keyRoot.map { r in Set((minorKey ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]).map { (r + $0) % 12 }) }
        // voiced runs → notes
        var out: [HeardNote] = []
        var t = 0
        while t < T {
            guard !pitch[t].isNaN else { t += 1; continue }
            var e = t
            while e < T && !pitch[e].isNaN { e += 1 }
            out += segment(Array(pitch[t..<e]), Array(strength[t..<e]), Array(lower[t..<e]), offset: t, scale: scale)
            t = e
        }
        // a note that drops out for a moment and comes back on the same pitch is one note
        var merged: [HeardNote] = []
        for n in out {
            if var last = merged.last, last.midi == n.midi, n.start - last.end <= 0.05, n.strength <= last.strength * 1.3 {
                last.strength = (last.strength * Float(last.end - last.start) + n.strength * Float(n.end - n.start)) / Float(n.end - last.start)
                last.end = n.end
                merged[merged.count - 1] = last
            } else { merged.append(n) }
        }
        return fixOctaveSlips(merged)
    }

    /// A note an octave (or two) away from both neighbours, which agree with each other, is an
    /// octave slip of the pitch tracker: bring it back next to them.
    static func fixOctaveSlips(_ notes: [HeardNote]) -> [HeardNote] {
        guard notes.count >= 3 else { return notes }
        var out = notes
        for i in 1..<(out.count - 1) {
            let p = out[i - 1], q = out[i + 1], m = out[i].midi
            // only within a phrase
            guard out[i].start - p.end < 1.5, q.start - out[i].end < 1.5, abs(p.midi - q.midi) <= 7 else { continue }
            let mid = Double(p.midi + q.midi) / 2
            var best = m
            for k in [-24, -12, 12, 24] where abs(Double(m + k) - mid) < abs(Double(best) - mid) { best = m + k }
            if abs(Double(m) - mid) >= 9, abs(Double(best) - mid) <= 6 { out[i].midi = best }
        }
        return out
    }

    /// Which semitone each frame of one voiced run belongs to: staying on a note is free, changing
    /// costs `noteChange`; a frame costs its squared distance from the note (in `noteSpread`s, capped
    /// so a stray frame can't drag a whole note), plus a little for notes outside the key.
    static func noteStates(_ p: [Float], scale: Set<Int>?) -> [Int] {
        let n = p.count
        let lo = Int((p.min() ?? 60).rounded(.down)) - 1, hi = Int((p.max() ?? 60).rounded(.up)) + 1
        let notes = Array(lo...hi)
        let k = notes.count
        let spread: Float = noteSpread, change: Float = noteChange
        func emit(_ i: Int, _ j: Int) -> Float {
            let d = (p[i] - Float(notes[j])) / spread
            var c = min(9, d * d)
            if let scale, !scale.contains(((notes[j] % 12) + 12) % 12) { c += outOfKey }
            return c
        }
        var cost = (0..<k).map { emit(0, $0) }
        var back = [[Int]](repeating: [Int](repeating: 0, count: k), count: n)
        for i in 1..<max(1, n) {
            let best = cost.indices.min { cost[$0] < cost[$1] }!
            var next = [Float](repeating: 0, count: k)
            for j in 0..<k {
                let stay = cost[j], move = cost[best] + change
                if stay <= move { next[j] = stay; back[i][j] = j } else { next[j] = move; back[i][j] = best }
                next[j] += emit(i, j)
            }
            cost = next
        }
        var j = cost.indices.min { cost[$0] < cost[$1] }!
        var out = [Int](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) { out[i] = notes[j]; j = back[i][j] }
        return out
    }

    private static func segment(_ p: [Float], _ s: [Float], _ lower: [Float], offset: Int, scale: Set<Int>?) -> [HeardNote] {
        let n = p.count
        guard n >= 6 else { return [] }
        let states = noteStates(p, scale: scale)
        // pieces of one note
        var pieces: [(a: Int, b: Int, m: Int)] = []
        var a = 0
        for k in 1...n where k == n || states[k] != states[a] { pieces.append((a, k, states[a])); a = k }
        // glides: a short piece sliding into (or out of) a neighbour within two semitones belongs to it
        var changed = true
        while changed && pieces.count > 1 {
            changed = false
            for i in pieces.indices where pieces[i].b - pieces[i].a < glideFrames {
                let next = i + 1 < pieces.count ? pieces[i + 1] : nil, prev = i > 0 ? pieces[i - 1] : nil
                if let nx = next, abs(nx.m - pieces[i].m) <= 2, nx.b - nx.a >= pieces[i].b - pieces[i].a {
                    pieces[i + 1].a = pieces[i].a; pieces.remove(at: i); changed = true; break
                }
                if let pv = prev, abs(pv.m - pieces[i].m) <= 2, pv.b - pv.a >= pieces[i].b - pieces[i].a {
                    pieces[i - 1].b = pieces[i].b; pieces.remove(at: i); changed = true; break
                }
            }
        }
        // split repeated notes where the voice dips (a new syllable)
        var split: [(a: Int, b: Int, m: Int)] = []
        for pc in pieces {
            var start = pc.a
            var peak: Float = 0
            var k = pc.a
            while k < pc.b {
                peak = max(peak, s[k])
                if k - start >= 8, s[k] < peak * 0.3 {
                    // find the bottom of the dip and see whether the voice comes back
                    var low = k
                    while low + 1 < pc.b && s[low + 1] <= s[low] { low += 1 }
                    var up = low
                    while up + 1 < pc.b && s[up] < peak * 0.7 { up += 1 }
                    if up > low && s[up] >= peak * 0.7 && pc.b - low >= 8 {
                        split.append((start, low, pc.m))
                        start = low; peak = 0; k = up
                        continue
                    }
                }
                k += 1
            }
            split.append((start, pc.b, pc.m))
        }
        let hop = hopSeconds
        return split.compactMap { pc in
            let len = pc.b - pc.a
            guard len >= 7 else { return nil }       // 70 ms
            let st = s[pc.a..<pc.b].reduce(0, +) / Float(len)
            guard st > 0.3 else { return nil }
            // voices wobble (vibrato, scoops, drift); strummed and picked accompaniment holds dead
            // steady. A weak note that doesn't move at all is the band, not the singer.
            if st < steadyCutoff {
                let inner = Array(p[(pc.a + min(2, len / 4))..<(pc.b - min(2, len / 4))])
                let mean = inner.reduce(0, +) / Float(max(1, inner.count))
                let sd = (inner.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(max(1, inner.count))).squareRoot()
                if sd < 0.05 { return nil }
            }
            // when the octave below accounts for the sound almost as well, that's the real pitch
            // (a vowel can make the second harmonic louder than the first)
            let low = lower[pc.a..<pc.b].reduce(0, +) / Float(len)
            let midi = low > octaveCutoff && Float(pc.m - 12) >= lowMidi ? pc.m - 12 : pc.m
            // a frame's window first catches a note ~45 ms after the frame starts
            return HeardNote(start: Double(offset + pc.a) * hop + 0.045, end: Double(offset + pc.b) * hop + 0.045, midi: midi, strength: st)
        }
    }

    // MARK: onto the song's beats

    /// Fractional beat index of a time, from the beat times (extrapolated outside them).
    static func beatPosition(_ t: Double, beatTimes: [Double]) -> Double {
        guard beatTimes.count >= 2 else { return 0 }
        let first = beatTimes[0], last = beatTimes[beatTimes.count - 1]
        let period = (last - first) / Double(beatTimes.count - 1)
        if t <= first { return (t - first) / period }
        if t >= last { return Double(beatTimes.count - 1) + (t - last) / period }
        var lo = 0, hi = beatTimes.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if beatTimes[mid] <= t { lo = mid } else { hi = mid } }
        return Double(lo) + (t - beatTimes[lo]) / (beatTimes[hi] - beatTimes[lo])
    }

    /// Places heard notes on the song's beats. `zeroBeat` is the (fractional) index into `beatTimes`
    /// where song beat 0 falls. Notes snap to `grid` beats; they're kept monophonic, inside
    /// `0..<length`, in a guitar's range, and short stray notes outside the key are tidied up.
    static func place(_ heard: [HeardNote], beatTimes: [Double], zeroBeat: Double, length: Double,
                      keyRoot: Int? = nil, minorKey: Bool = false, grid: Double = 0.25) -> [MelodyNote] {
        guard beatTimes.count >= 2 else { return [] }
        func snap(_ x: Double) -> Double { (x / grid).rounded() * grid }
        var notes: [(n: MelodyNote, s: Float)] = heard.compactMap { h in
            let a = snap(beatPosition(h.start, beatTimes: beatTimes) - zeroBeat)
            var b = snap(beatPosition(h.end, beatTimes: beatTimes) - zeroBeat)
            if b <= a { b = a + grid }
            guard a >= 0, a < length else { return nil }
            return (MelodyNote(start: a, beats: min(b, length) - a, midi: h.midi), h.strength)
        }
        notes.sort { $0.n.start < $1.n.start }
        // one note at a time: on a tie keep the stronger, otherwise end the earlier one where the next starts
        var mono: [(n: MelodyNote, s: Float)] = []
        for x in notes {
            if let last = mono.last, last.n.start == x.n.start {
                if x.s > last.s { mono[mono.count - 1] = x }
                continue
            }
            if let last = mono.last, last.n.end > x.n.start { mono[mono.count - 1].n.beats = x.n.start - last.n.start }
            mono.append(x)
        }
        var out = mono.map(\.n)
        // a lone note an octave away from both neighbours is an octave slip
        if out.count >= 3 {
            for i in 1..<(out.count - 1) {
                let p = out[i - 1].midi, q = out[i + 1].midi, m = out[i].midi
                if abs(p - q) <= 5, abs(m - p) >= 10, abs(m - q) >= 10 {
                    let shifted = m + (m > p ? -12 : 12)
                    if abs(shifted - p) <= 7 { out[i].midi = shifted }
                }
            }
        }
        // short out-of-key notes right next to a key note are usually scoops and slides
        if let root = keyRoot {
            let steps = minorKey ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
            let scale = Set(steps.map { (root + $0) % 12 })
            for i in out.indices where out[i].beats <= 0.5 && !scale.contains(((out[i].midi % 12) + 12) % 12) {
                let up = scale.contains((out[i].midi + 1) % 12), down = scale.contains(((out[i].midi - 1) % 12 + 12) % 12)
                let prev = i > 0 ? out[i - 1].midi : out[i].midi
                if up && down { out[i].midi += prev > out[i].midi ? 1 : -1 } else if up { out[i].midi += 1 } else if down { out[i].midi -= 1 }
            }
        }
        // fold into the range a guitar can play comfortably (E2 – C6)
        for i in out.indices {
            while out[i].midi < 40 { out[i].midi += 12 }
            while out[i].midi > 84 { out[i].midi -= 12 }
        }
        return out.filter { $0.beats > 0 }
    }

    /// The melody repeated every `period` beats until `length` (for songs whose chords were
    /// repeated to make a short preview last longer).
    static func tiled(_ notes: [MelodyNote], period: Double, length: Double) -> [MelodyNote] {
        guard period > 0, !notes.isEmpty else { return notes }
        var out: [MelodyNote] = []
        var k = 0.0
        while k < length {
            out += notes.compactMap { n in
                let s = n.start + k
                guard s < length else { return nil }
                return MelodyNote(start: s, beats: min(n.beats, length - s), midi: n.midi)
            }
            k += period
        }
        return out
    }

    // MARK: playing it

    /// One melody note as the guitar plays it.
    struct Pick {
        var index: Int
        /// Seconds after playback starts.
        var at: Double
        var string: Int
        /// Fret with the capo included.
        var fret: Int
        /// "" pick, "h" hammer-on, "p" pull-off, "~" vibrato (see `GuitarSynth.lead`).
        var tech: String
        var length: Double
        /// Let go of the string this long after picking it (nil when the next note carries straight on).
        var release: Double?
    }

    /// How to play the melody from song beat `offset`, `beat` seconds per beat: fretted where a player
    /// would, notes that follow straight on along one string hammered on or pulled off, long notes with vibrato.
    static func picks(_ melody: [MelodyNote], from offset: Double = 0, beat: Double, capo: Int) -> [Pick] {
        let frets = positions(melody)
        var out: [Pick] = []
        for (i, n) in melody.enumerated() where n.start >= offset - 0.01 {
            let pos = frets[i]
            let length = n.beats * beat
            var tech = ""
            if i > 0 {
                let prev = melody[i - 1], pp = frets[i - 1]
                if pp.string == pos.string, (n.start - prev.end) * beat < 0.03, abs(pp.fret - pos.fret) <= 3, pp.fret != pos.fret, pos.fret > 0 {
                    tech = pos.fret > pp.fret ? "h" : "p"
                }
            }
            if tech.isEmpty && length >= 0.7 { tech = "~" }
            // let go at the end of the note, unless the next one carries straight on from this string
            var release: Double? = max(0.08, length - 0.02)
            if melody.indices.contains(i + 1), frets[i + 1].string == pos.string, (melody[i + 1].start - n.end) * beat <= 0.12 { release = nil }
            out.append(Pick(index: i, at: (n.start - offset) * beat, string: pos.string, fret: pos.fret + capo, tech: tech, length: length, release: release))
        }
        return out
    }

    // MARK: on the fretboard

    /// Where to play each note: a path along the neck that keeps the hand in one area,
    /// prefers the lower frets and avoids big shifts (a small Viterbi over string/fret choices).
    static func positions(_ notes: [MelodyNote], maxFret: Int = 17) -> [(string: Int, fret: Int)] {
        let options: [[(string: Int, fret: Int)]] = notes.map { n in
            let o = Theory.openStrings.enumerated().compactMap { s, open -> (string: Int, fret: Int)? in
                let f = n.midi - open
                return f >= 0 && f <= maxFret ? (s, f) : nil
            }
            return o.isEmpty ? [(5, max(0, n.midi - Theory.openStrings[5]))] : o
        }
        guard !options.isEmpty else { return [] }
        func own(_ p: (string: Int, fret: Int)) -> Double { Double(p.fret) * 0.08 + (p.string == 0 ? 0.4 : 0) }
        func move(_ a: (string: Int, fret: Int), _ b: (string: Int, fret: Int)) -> Double {
            let shift = abs(a.fret - b.fret)
            let stretch = a.fret == 0 || b.fret == 0 ? 0 : max(0, shift - 3)
            return Double(stretch) * 1.0 + Double(min(shift, 3)) * 0.1 + Double(abs(a.string - b.string)) * 0.05
        }
        var cost = options[0].map(own)
        var back: [[Int]] = [Array(repeating: 0, count: options[0].count)]
        for i in 1..<options.count {
            var next: [Double] = [], arg: [Int] = []
            for p in options[i] {
                var best = Double.infinity, bi = 0
                for (j, q) in options[i - 1].enumerated() {
                    let c = cost[j] + move(q, p)
                    if c < best { best = c; bi = j }
                }
                next.append(best + own(p)); arg.append(bi)
            }
            cost = next; back.append(arg)
        }
        var j = cost.indices.min { cost[$0] < cost[$1] } ?? 0
        var out = [(string: Int, fret: Int)](repeating: (0, 0), count: options.count)
        for i in stride(from: options.count - 1, through: 0, by: -1) {
            out[i] = options[i][j]
            j = back[i][j]
        }
        return out
    }
}
