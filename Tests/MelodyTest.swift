// Synthesises stereo band mixes with a sung-style lead melody (centre) over wide strummed guitars,
// bass and drums, and checks the melody finder gets the tune back — notes, pitch and beat placement.
// Run on its own: build/selftest --melody
#if SELFTEST
import Foundation

extension SelfTest {
    struct MelodyCase { var chords: [String]; var bpm: Double; var keyRoot: Int; var minor = false; var low = 57; var voiceGain: Float = 0.5; var seed: UInt64 }
    struct TrueNote { var start: Double; var end: Double; var midi: Int }

    /// Small deterministic random numbers, so every run tests the same songs.
    struct Lcg { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }

    /// A tune in the key: a random walk over the scale with mixed rhythms, rests and repeated notes.
    static func makeTune(_ c: MelodyCase, seconds: Double) -> [TrueNote] {
        var rng = Lcg(s: c.seed)
        let beat = 60 / c.bpm
        let steps = c.minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        let scale = (c.low...(c.low + 17)).filter { steps.contains((($0 - c.keyRoot) % 12 + 12) % 12) }
        let rhythms: [[Double]] = [[1, 1, 1, 1], [2, 1, 1], [1.5, 0.5, 2], [0.5, 0.5, 1, 2], [1, 1, -2], [1, 0.5, 0.5, 1, 1], [3, -1], [0.5, 0.5, 0.5, 0.5, 2]]
        var out: [TrueNote] = []
        var idx = scale.count / 2
        var t = 2 * beat            // the first bar is instrumental... but sung from beat 3
        var bar = 0
        while t < seconds - 4 * beat {
            let r = rhythms[Int(rng.next() * Double(rhythms.count))]
            for d in r {
                if d < 0 { t += -d * beat; continue }
                let move = Int((rng.next() * 5).rounded()) - 2
                if rng.next() > 0.2 { idx = max(0, min(scale.count - 1, idx + move)) }   // 20%: repeat the note
                out.append(TrueNote(start: t, end: t + d * beat * 0.9, midi: scale[idx]))
                t += d * beat
            }
            bar += 1
            if bar % 4 == 3 { t += 2 * beat }   // a breath at the end of a phrase
        }
        return out
    }

    /// A voice-like tone: harmonics shaped by vowel formants, vibrato, a little scoop into each note.
    static func voice(_ midi: Int, dur: Double, formants: [(f: Double, bw: Double)]) -> [Float] {
        let n = Int(dur * sr)
        let f0 = Theory.frequency(midi: Double(midi))
        var harm: [(h: Double, a: Double)] = []
        var h = 1.0
        while h * f0 < 6000 {
            let f = h * f0
            var a = 0.0
            for fm in formants { a += 1 / (1 + pow((f - fm.f) / fm.bw, 2)) }
            harm.append((h, (0.15 + a) / h.squareRoot()))
            h += 1
        }
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        for i in 0..<n {
            let t = Double(i) / sr
            let scoop = t < 0.05 ? -0.4 * (1 - t / 0.05) : 0
            let vib = t > 0.18 ? 0.25 * sin(2 * .pi * 5.4 * t) * min(1, (t - 0.18) / 0.2) : 0
            let f = f0 * pow(2, (scoop + vib) / 12)
            phase += 2 * .pi * f / sr
            var v = 0.0
            for x in harm { v += x.a * sin(x.h * phase) }
            let env = min(1, t / 0.03) * min(1, (dur - t) / 0.04)
            out[i] = Float(v * env * 0.25)
        }
        return out
    }

    static func renderStereoMix(_ c: MelodyCase, tune: [TrueNote], seconds: Double) -> (l: [Float], r: [Float]) {
        let total = Int(sr * seconds)
        var L = [Float](repeating: 0, count: total), R = L
        let beat = 60 / c.bpm
        var rng = SystemRandomNumberGenerator()
        func add(_ s: [Float], at t: Double, gain: Float, pan: Float) {
            let start = Int(t * sr)
            let gl = gain * (1 - pan) , gr = gain * (1 + pan)
            for (i, v) in s.enumerated() where start + i < total && start + i >= 0 { L[start + i] += v * gl; R[start + i] += v * gr }
        }
        func ks(_ midi: Int, dur: Double) -> [Float] {
            let f = Theory.frequency(midi: Double(midi))
            let period = max(2, Int((sr / f).rounded()))
            var buf = (0..<period).map { _ in Float.random(in: -1...1, using: &rng) }
            var o = [Float](repeating: 0, count: Int(dur * sr))
            var p = 0
            for k in o.indices { let nx = (p + 1) % period; o[k] = buf[p]; buf[p] = (buf[p] + buf[nx]) * 0.4985; p = nx }
            return o
        }
        func sine(_ midi: Int, dur: Double, decay: Double) -> [Float] {
            let f = Theory.frequency(midi: Double(midi))
            return (0..<Int(dur * sr)).map { i in let t = Double(i) / sr; return Float(sin(2 * .pi * f * t) * exp(-t / decay) * min(1, t * 200)) }
        }
        func noise(_ dur: Double, decay: Double) -> [Float] {
            (0..<Int(dur * sr)).map { i in Float.random(in: -1...1, using: &rng) * Float(exp(-Double(i) / sr / decay)) }
        }
        var t = 0.0, i = 0
        while t < seconds - beat {
            let name = c.chords[(i / 4) % c.chords.count]
            let shape = ChordLibrary.shape(for: name)!
            let sym = ChordSymbol.parse(name)!
            // two strummed guitars, one each side
            for (side, pan) in [(0, Float(-0.8)), (1, Float(0.8))] {
                for half in 0..<2 where half == 0 || i % 2 == side {
                    let at = t + Double(half) * beat / 2 + Double(side) * 0.012
                    let notes = half == 0 ? shape.midiNotes : Array(shape.midiNotes.reversed().prefix(4))
                    for (k, m) in notes.enumerated() { add(ks(m, dur: beat * 1.1), at: at + Double(k) * 0.007, gain: half == 0 ? 0.13 : 0.09, pan: pan) }
                }
            }
            if i % 2 == 0 { add(sine(36 + sym.root, dur: beat * 1.8, decay: 0.5), at: t, gain: 0.32, pan: 0) }
            if i % 2 == 0 { add(sine(36, dur: 0.15, decay: 0.05), at: t, gain: 0.45, pan: 0) }
            else { add(noise(0.2, decay: 0.06), at: t, gain: 0.16, pan: 0.1) }
            add(noise(0.04, decay: 0.01), at: t + beat / 2, gain: 0.05, pan: 0.4)
            t += beat; i += 1
        }
        // the singer, centre, changing vowel now and then
        let vowels: [[(f: Double, bw: Double)]] = [[(730, 90), (1090, 110), (2440, 160)], [(530, 70), (1840, 100), (2480, 160)],
                                                    [(300, 60), (870, 90), (2240, 150)], [(570, 80), (840, 90), (2410, 160)]]
        for (k, n) in tune.enumerated() {
            add(voice(n.midi, dur: n.end - n.start, formants: vowels[k % vowels.count]), at: n.start, gain: c.voiceGain, pan: 0)
        }
        // a touch of stereo room on everything, so the sides aren't silent
        let d = Int(0.023 * sr)
        for k in stride(from: total - 1, through: d, by: -1) { L[k] += 0.12 * R[k - d]; R[k] += 0.12 * L[k - d] }
        return (L, R)
    }

    static func melodyChecks() {
        let cases = [
            MelodyCase(chords: ["G", "D", "Em", "C"], bpm: 96, keyRoot: 7, seed: 1),
            MelodyCase(chords: ["C", "G", "Am", "F"], bpm: 120, keyRoot: 0, low: 60, seed: 2),
            MelodyCase(chords: ["Am", "F", "C", "G"], bpm: 84, keyRoot: 9, minor: true, seed: 3),
            MelodyCase(chords: ["D", "A", "Bm", "G"], bpm: 132, keyRoot: 2, low: 52, seed: 4),
            MelodyCase(chords: ["E", "A", "B", "A"], bpm: 104, keyRoot: 4, low: 64, seed: 5),
            MelodyCase(chords: ["Em", "C", "G", "D"], bpm: 72, keyRoot: 4, minor: true, seed: 6),
            MelodyCase(chords: ["F", "Bb", "C", "C"], bpm: 110, keyRoot: 5, voiceGain: 0.3, seed: 7),
            MelodyCase(chords: ["C", "Am", "F", "G"], bpm: 90, keyRoot: 0, low: 55, voiceGain: 0.3, seed: 8),
        ]
        let seconds = 40.0
        var report: [String] = []
        var tot = (stereo: (hit: 0, heard: 0, truth: 0, frames: 0, framesOK: 0), mono: (hit: 0, heard: 0, truth: 0, frames: 0, framesOK: 0))
        var placedOK = 0, placedTotal = 0
        for c in cases {
            let tune = makeTune(c, seconds: seconds)
            let (L, R) = renderStereoMix(c, tune: tune, seconds: seconds)
            let mid = zip(L, R).map { ($0 + $1) / 2 }, side = zip(L, R).map { ($0 - $1) / 2 }
            var line = "\(c.chords.joined(separator: " ")) @\(Int(c.bpm)) voice \(c.voiceGain):"
            for stereo in [true, false] {
                guard let r = try? Transcriber.analyze(samples: mid, side: stereo ? side : nil, sampleRate: sr) else { line += " FAILED"; continue }
                let heard = r.heardMelody
                // notes: same pitch, onset within 100 ms (each truth note matched once)
                var used = Set<Int>()
                var hits = 0
                for h in heard {
                    if let j = tune.indices.first(where: { !used.contains($0) && tune[$0].midi == h.midi && abs(tune[$0].start - h.start) < 0.1 }) { used.insert(j); hits += 1 }
                }
                // frames: of the time something is sung, how much has the right pitch
                var frames = 0, ok = 0
                for n in tune {
                    var x = n.start + 0.06
                    while x < n.end - 0.02 {
                        frames += 1
                        if heard.contains(where: { $0.start <= x && $0.end > x && $0.midi == n.midi }) { ok += 1 }
                        x += 0.02
                    }
                }
                let p = Double(hits) / Double(max(1, heard.count)), rc = Double(hits) / Double(max(1, tune.count))
                let f = p + rc > 0 ? 2 * p * rc / (p + rc) : 0
                line += String(format: " %@ F %.0f%% (P %.0f%% R %.0f%%) pitch-on-time %.0f%%", stereo ? "stereo" : "| mono", f * 100, p * 100, rc * 100, 100 * Double(ok) / Double(max(1, frames)))
                if stereo {
                    tot.stereo.hit += hits; tot.stereo.heard += heard.count; tot.stereo.truth += tune.count; tot.stereo.frames += frames; tot.stereo.framesOK += ok
                    // placed on the song's beats: map each placed note back to a time and check it against the tune
                    let song = Transcriber.song(from: r, title: "t", artist: "a", genre: "Pop", capo: 0, wholeSong: true)
                    let beat = 60 / r.bpm
                    for n in song.melody ?? [] {
                        let pos = n.start + r.songZeroBeat
                        let k = Int(pos.rounded(.down))
                        guard k >= 0, k + 1 < r.beatTimes.count else { continue }
                        let time = r.beatTimes[k] + (pos - Double(k)) * (r.beatTimes[k + 1] - r.beatTimes[k])
                        placedTotal += 1
                        if tune.contains(where: { $0.midi == n.midi && abs($0.start - time) <= 0.3 * beat }) { placedOK += 1 }
                    }
                } else {
                    tot.mono.hit += hits; tot.mono.heard += heard.count; tot.mono.truth += tune.count; tot.mono.frames += frames; tot.mono.framesOK += ok
                }
            }
            report.append(line)
        }
        func summary(_ x: (hit: Int, heard: Int, truth: Int, frames: Int, framesOK: Int)) -> String {
            let p = Double(x.hit) / Double(max(1, x.heard)), r = Double(x.hit) / Double(max(1, x.truth))
            return String(format: "notes F %.0f%% (precision %.0f%%, recall %.0f%%), pitch right while singing %.0f%%",
                          100 * 2 * p * r / max(1e-9, p + r), 100 * p, 100 * r, 100 * Double(x.framesOK) / Double(max(1, x.frames)))
        }
        print("\nMelody from a full mix (\(cases.count) synthetic songs, sung-style lead over guitars, bass and drums):")
        print("   stereo: " + summary(tot.stereo))
        print("   mono:   " + summary(tot.mono))
        print(String(format: "   placed on the song's beats (right pitch, within ⅓ beat): %.0f%%", 100 * Double(placedOK) / Double(max(1, placedTotal))))
        for r in report { print("   " + r) }
    }
}
#endif
