// Training data for ChordNet (scripts/chordnet): synthetic band mixes with known chords, rendered
// with the app's own guitar engine plus simple bass, keys, pad, drums and a sung-style lead.
// Every song is in a random key (all 12, major and minor), tempo, meter, tone and arrangement.
//   build/selftest --chordnet-synth <dir> <count> [first seed]
// writes <dir>/syn_<seed>.wav (44.1 kHz mono 16-bit), .lab ("start end class", class 0–11 major on
// that root, 12–23 minor, 24 no chord, -1 a chord outside major/minor), .beats (one time per line)
// and .key ("<root 0–11> major|minor").
#if SELFTEST
import Foundation
import AVFoundation

extension SelfTest {
    static func chordNetSynth(_ args: [String]) -> Bool {
        guard let i = args.firstIndex(of: "--chordnet-synth"), args.count > i + 2, let count = Int(args[i + 2]) else { return false }
        let dir = args[i + 1]
        let first = args.count > i + 3 ? (UInt64(args[i + 3]) ?? 1) : 1
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let t0 = Date()
        let done = NSLock()
        var n = 0
        DispatchQueue.concurrentPerform(iterations: count) { k in
            let seed = first + UInt64(k)
            var song = SynthSong.make(seed: seed)
            let audio = song.render()
            writeMono16("\(dir)/syn_\(seed).wav", audio, sampleRate: SynthSong.sr)
            try? song.labText.write(toFile: "\(dir)/syn_\(seed).lab", atomically: true, encoding: .utf8)
            try? "\(song.keyRoot) \(song.minor ? "minor" : "major")\n".write(toFile: "\(dir)/syn_\(seed).key", atomically: true, encoding: .utf8)
            try? song.beats.map { String(format: "%.4f", $0) }.joined(separator: "\n").write(toFile: "\(dir)/syn_\(seed).beats", atomically: true, encoding: .utf8)
            done.lock(); n += 1
            if n % 50 == 0 { print(String(format: "   %d/%d songs (%.0f s)", n, count, Date().timeIntervalSince(t0))) }
            done.unlock()
        }
        print(String(format: "ChordNet synth: %d songs → %@ in %.0f s", count, dir, Date().timeIntervalSince(t0)))
        return true
    }

    static func writeMono16(_ path: String, _ x: [Float], sampleRate sr: Double) {
        let url = URL(fileURLWithPath: path)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sr, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        guard let file = try? AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count)) else { print("can't write \(path)"); return }
        buf.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
        try? file.write(from: buf)
    }
}

/// One synthetic song: a chord progression and an arrangement, rendered to mono audio.
struct SynthSong {
    static let sr = 44100.0
    struct Chord { var start: Double; var end: Double; var name: String; var root: Int; var tones: [Int]; var label: Int; var bass: Int }

    var seed: UInt64
    var chords: [Chord] = []
    var beats: [Double] = []
    var bpm = 100.0
    var meter = 4
    var keyRoot = 0
    var minor = false
    var length = 30.0
    var intro = 0.0        // seconds of drums only (no chord) at the start
    var rng: SelfTest.Lcg

    var labText: String {
        var rows: [String] = []
        if intro > 0 { rows.append(String(format: "0.0000 %.4f 24", intro)) }
        for c in chords { rows.append(String(format: "%.4f %.4f %d", c.start, c.end, c.label)) }
        if let last = chords.last { rows.append(String(format: "%.4f %.4f 24", last.end, length)) }
        return rows.joined(separator: "\n") + "\n"
    }

    mutating func r() -> Double { rng.next() }
    mutating func pick<T>(_ xs: [T]) -> T { xs[min(xs.count - 1, Int(r() * Double(xs.count)))] }
    mutating func chance(_ p: Double) -> Bool { r() < p }

    // MARK: the song

    static func make(seed: UInt64) -> SynthSong {
        var s = SynthSong(seed: seed, rng: SelfTest.Lcg(s: seed &* 0x9E3779B97F4A7C15 &+ 12345))
        for _ in 0..<3 { _ = s.r() }
        s.keyRoot = Int(s.r() * 12)
        s.minor = s.chance(0.35)
        s.bpm = 60 + s.r() * 110
        s.meter = s.chance(0.1) ? 3 : 4
        s.length = 26 + s.r() * 10
        let beat = 60 / s.bpm
        s.intro = s.chance(0.2) ? Double(s.meter) * beat * Double(1 + Int(s.r() * 2)) : 0
        let start = 0.05 + s.r() * 0.4
        // the progression: diatonic degrees (scale step, minor?) with some borrowed chords
        let major: [(Int, Bool)] = [(0, false), (5, false), (7, false), (9, true), (2, true), (4, true)]
        let natMinor: [(Int, Bool)] = [(0, true), (3, false), (8, false), (10, false), (5, true), (7, true), (7, false)]
        let borrowed: [(Int, Bool)] = s.minor ? [(5, false), (1, false), (2, false)] : [(10, false), (8, false), (2, false), (4, false), (5, true), (3, false)]
        let pool = s.minor ? natMinor : major
        let nChords = s.pick([3, 4, 4, 4, 4, 5, 6, 8])
        var prog: [(Int, Bool)] = [s.minor ? (0, true) : (0, false)]
        while prog.count < nChords {
            let c = s.chance(0.12) ? s.pick(borrowed) : s.pick(pool)
            if c != prog.last! { prog.append(c) }
        }
        // rotate so the song doesn't always start on the tonic
        let rot = s.chance(0.4) ? Int(s.r() * Double(prog.count)) : 0
        prog = Array(prog[rot...] + prog[..<rot])
        // how long each chord lasts (beats); one rhythm for the whole progression
        let lens: [Double] = prog.map { _ in
            let m = Double(s.meter)
            return s.pick([m, m, m, m, 2 * m, m / 2 > 1 ? 2 : m, 1 * m, s.meter == 4 ? 2 : 3, 2 * m])
        }
        // flavours: label stays the triad (−1 when it isn't major or minor)
        var t = start + s.intro
        var k = 0
        while t < s.length - 1.5 {
            let (deg, isMin) = prog[k % prog.count]
            let root = (s.keyRoot + deg) % 12
            let dur = lens[k % prog.count] * beat
            var suffix = isMin ? "m" : ""
            var tones = isMin ? [0, 3, 7] : [0, 4, 7]
            var label = isMin ? 12 + root : root
            let f = s.r()
            if f < 0.10 { suffix += isMin ? "7" : (deg == 7 || deg == 2 ? "7" : "maj7"); tones.append(isMin || deg == 7 || deg == 2 ? 10 : 11) }
            else if f < 0.14, !isMin { suffix = "7"; tones.append(10) }
            else if f < 0.17 { suffix = "sus4"; tones = [0, 5, 7]; label = -1 }
            else if f < 0.20 { suffix = "sus2"; tones = [0, 2, 7]; label = -1 }
            else if f < 0.23, !isMin { suffix = "add9"; tones.append(2) }
            else if f < 0.25, !isMin { suffix = "6"; tones.append(9) }
            else if f < 0.26, deg == 11 || (!s.minor && deg == 2) { suffix = "dim"; tones = [0, 3, 6]; label = -1 }
            // the bass: usually the root, sometimes an inversion (the chord stays the same)
            let bass = s.chance(0.08) ? tones[1] : (s.chance(0.04) ? 7 : 0)
            let name = Theory.name(root, flat: [1, 3, 8, 10].contains(root) && s.chance(0.5)) + suffix
            let end = min(t + dur, s.length - 0.8)
            s.chords.append(Chord(start: t, end: end, name: name, root: root, tones: tones.map { ($0 + root) % 12 }, label: label, bass: (root + bass) % 12))
            t += dur; k += 1
        }
        var b = start
        while b < s.length { s.beats.append(b); b += beat }
        return s
    }

    // MARK: rendering

    mutating func render() -> [Float] {
        let n = Int(length * Self.sr)
        let beat = 60 / bpm
        let detune = chance(0.35) ? Float(r() * 0.5 - 0.25) : 0   // semitones off A440
        let freqMul = pow(2, Double(detune) / 12)
        var stems: [(audio: [Float], gainDB: Double)] = []
        let chordStart = chords.first?.start ?? 0

        // 1–2 guitars
        let guitars = chance(0.35) ? 2 : (chance(0.9) ? 1 : 0)
        let wantGuitar = guitars == 0 && chance(0.5) ? 1 : guitars
        for g in 0..<wantGuitar {
            stems.append((guitarPart(detune: detune, beat: beat, second: g == 1), g == 0 ? 0 : -3 - r() * 6))
        }
        // keys (piano-ish), pad
        if chance(wantGuitar == 0 ? 1 : 0.45) { stems.append((keysPart(freqMul: freqMul, beat: beat), -2 - r() * 8)) }
        if chance(0.2) { stems.append((padPart(freqMul: freqMul), -6 - r() * 8)) }
        // bass, drums, voice
        if chance(0.8) { stems.append((bassPart(freqMul: freqMul, beat: beat), -1 - r() * 7)) }
        let drumsOn = chance(0.75) || intro > 0
        if drumsOn { stems.append((drumPart(beat: beat, from: intro > 0 ? 0.05 : chordStart), -1 - r() * 8)) }
        if chance(0.6) { stems.append((voicePart(freqMul: freqMul, beat: beat), -6 + r() * 9)) }

        var mix = [Float](repeating: 0, count: n)
        for (a, db) in stems {
            var ms: Float = 0
            let m = min(a.count, n)
            guard m > 0 else { continue }
            for i in stride(from: 0, to: m, by: 4) { ms += a[i] * a[i] }
            let rms = (ms / Float(m / 4 + 1)).squareRoot()
            guard rms > 1e-6 else { continue }
            let g = Float(pow(10, db / 20)) * 0.1 / rms
            for i in 0..<m { mix[i] += a[i] * g }
        }
        // a little noise floor sometimes, and a random overall level
        if chance(0.3) { let lvl = Float(pow(10, (-55 + r() * 15) / 20)); for i in 0..<n { mix[i] += lvl * Float(r() * 2 - 1) } }
        let peak = mix.map(abs).max() ?? 1
        let target = Float(0.3 + r() * 0.6)
        if peak > 0 { for i in 0..<n { mix[i] *= target / peak } }
        return mix
    }

    private func add(_ src: [Float], into dst: inout [Float], at t: Double, gain: Float = 1) {
        let s0 = Int(t * Self.sr)
        for (i, v) in src.enumerated() { let j = s0 + i; if j >= 0 && j < dst.count { dst[j] += v * gain } }
    }

    private mutating func guitarPart(detune: Float, beat: Double, second: Bool) -> [Float] {
        let sr = Self.sr
        let core = GuitarCore(sampleRate: sr)
        let tone = pick([0, 0, 0, 1, 1, 2])
        core.tone = tone
        let style = pick(tone == 2 ? ["strum", "power8", "strum", "whole"] : ["strum", "strum", "strum", "pick", "whole", "reggae"])
        let pats = StrumPattern.library.filter { $0.beatsPerBar == meter && $0.id != "reggae" }
        let pattern = Array((pats.isEmpty ? "D-DU-UDU" : pick(pats).pattern))
        let voicingPick = r()
        var ev: [GuitarCore.Event] = []
        func at(_ e: [GuitarCore.Event], _ t: Double) -> [GuitarCore.Event] { e.map { var x = $0; x.delay += Int(t * sr); x.detune += detune; return x } }
        for c in chords {
            let vs = ChordLibrary.voicings(for: c.name)
            let fallback = ChordLibrary.shape(for: Theory.name(c.root) + (c.label >= 12 ? "m" : "")) ?? ChordLibrary.shapes[0]
            var shape = vs.isEmpty ? fallback : vs[min(vs.count - 1, Int(voicingPick * Double(second ? vs.count : min(2, vs.count))))].shape
            if style == "power8" {
                // a power chord: root and fifth (and octave) on the lowest strings that fit
                let low = [40, 45].min { (c.root - $0 % 12 + 12) % 12 < (c.root - $1 % 12 + 12) % 12 }!
                let s0 = low == 40 ? 0 : 1, fret = (c.root - low % 12 + 12) % 12
                var frets = [-1, -1, -1, -1, -1, -1]
                frets[s0] = fret; frets[s0 + 1] = fret + 2; frets[s0 + 2] = fret + 2
                shape = ChordShape(name: c.name, frets: frets, fingers: [0, 0, 0, 0, 0, 0])
            }
            let slot = meter == 4 ? beat / 2 : beat / 2
            var tt = c.start
            var k = 0
            switch style {
            case "pick":
                let played = (0..<6).filter { shape.frets[$0] >= 0 }
                guard let bassS = played.first else { continue }
                let treble = Array(played.suffix(3))
                while tt < c.end - 0.01 {
                    let s = k % 2 == 0 ? (k % 4 == 0 ? bassS : played[min(1, played.count - 1)]) : treble[(k / 2) % treble.count]
                    ev.append(.init(kind: .pluck, string: s, midi: Theory.openStrings[s] + shape.frets[s], velocity: Float(0.55 + r() * 0.3),
                                    bright: 0.5, delay: Int(tt * sr), pick: 0.2, detune: detune, touch: k % 2 == 0 ? .thumb : .finger))
                    tt += slot; k += 1
                }
            case "whole":
                ev += at(GuitarSynth.events(for: shape, stroke: .down, velocity: 0.85, sampleRate: sr), c.start)
                if c.end - c.start > 4 * beat { ev += at(GuitarSynth.events(for: shape, stroke: .down, velocity: 0.7, sampleRate: sr), c.start + 2 * beat) }
            case "reggae":
                while tt < c.end - 0.01 {
                    if k % 2 == 1 {
                        ev += at(GuitarSynth.events(for: shape, stroke: .up, velocity: 0.7, sampleRate: sr), tt)
                        for s in 0..<6 { ev.append(.damp(s, at: Int((tt + slot * 0.7) * sr), seconds: 0.05)) }
                    }
                    tt += slot; k += 1
                }
            case "power8":
                while tt < c.end - 0.01 {
                    var e = at(GuitarSynth.events(for: shape, stroke: .down, velocity: k % 2 == 0 ? 0.9 : 0.75, sampleRate: sr), tt)
                    for j in e.indices where e[j].kind == .pluck { e[j].mute = 0.5 }
                    ev += e
                    tt += slot; k += 1
                }
            default:
                // strum pattern: slot k of the bar, counted from the chord's start
                while tt < c.end - 0.01 {
                    let ch = pattern[k % pattern.count]
                    if let st = StrumStroke(rawValue: ch), st.isStrum {
                        let v: Float = k % pattern.count == 0 ? 0.9 : (k % 2 == 0 ? 0.78 : 0.6)
                        ev += at(GuitarSynth.events(for: shape, stroke: st, velocity: v, sampleRate: sr), tt)
                    }
                    tt += slot; k += 1
                }
            }
        }
        for s in 0..<6 { ev.append(.damp(s, at: Int((chords.last?.end ?? length) * sr), seconds: 0.3)) }
        core.enqueue(ev)
        let (l, rr) = SelfTest.renderCore(core, seconds: length)
        return zip(l, rr).map { ($0 + $1) * 0.5 }
    }

    /// Piano-like: harmonics with a decay that's faster for high partials.
    private func pianoNote(_ midi: Double, dur: Double, vel: Float) -> [Float] {
        let f0 = Theory.frequency(midi: midi)
        let n = Int(min(dur + 0.3, 6) * Self.sr)
        var out = [Float](repeating: 0, count: n)
        var h = 1.0
        while h <= 10 && h * f0 < 8000 {
            let a = 1 / pow(h, 1.3), d = 1.2 / (1 + 0.6 * h) * (f0 < 200 ? 2 : 1)
            let w = 2 * Double.pi * f0 * h * (1 + 0.0004 * h * h) / Self.sr
            for i in 0..<n {
                let t = Double(i) / Self.sr
                let rel = t > dur ? exp(-(t - dur) / 0.08) : 1
                out[i] += Float(a * sin(w * Double(i)) * exp(-t / d) * rel)
            }
            h += 1
        }
        let atk = Int(0.004 * Self.sr)
        for i in 0..<min(atk, n) { out[i] *= Float(i) / Float(atk) }
        return out.map { $0 * vel }
    }

    private mutating func keysPart(freqMul: Double, beat: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(length * Self.sr))
        let style = pick(["whole", "quarters", "arp", "halves"])
        let center = 58 + Int(r() * 10)
        let dm = 12 * log2(freqMul)
        for c in chords {
            // close voicing around `center`, random inversion
            var notes: [Int] = c.tones.map { pc in var m = center - 6 + ((pc - (center - 6)) % 12 + 12) % 12; if chance(0.2) { m += 12 }; return m }
            notes.sort()
            if chance(0.5) { notes.append(36 + 12 + c.bass) }   // left hand
            let step = style == "quarters" ? beat : (style == "halves" ? 2 * beat : (style == "arp" ? beat / 2 : c.end - c.start))
            var t = c.start, k = 0
            while t < c.end - 0.01 {
                let d = min(step, c.end - t)
                if style == "arp" {
                    let m = notes[k % notes.count]
                    add(pianoNote(Double(m) + dm, dur: d * 1.5, vel: 0.5), into: &out, at: t)
                } else {
                    for m in notes { add(pianoNote(Double(m) + dm, dur: d * 0.95, vel: 0.35), into: &out, at: t + r() * 0.01) }
                }
                t += step; k += 1
            }
        }
        return out
    }

    private mutating func padPart(freqMul: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(length * Self.sr))
        for c in chords {
            let n = Int((c.end - c.start + 0.2) * Self.sr)
            for pc in c.tones {
                let f = Theory.frequency(midi: Double(55 + (pc - 55 % 12 + 12) % 12)) * freqMul
                var seg = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let t = Double(i) / Self.sr
                    let env = min(1, t / 0.25) * min(1, max(0, (Double(n) / Self.sr - t) / 0.2))
                    var v = 0.0
                    for h in 1...6 { v += sin(2 * .pi * f * Double(h) * t * (1 + 0.002 * Double(h % 2))) / Double(h * h) }
                    seg[i] = Float(v * env * 0.3)
                }
                add(seg, into: &out, at: c.start)
            }
        }
        return out
    }

    private mutating func bassPart(freqMul: Double, beat: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(length * Self.sr))
        let style = pick(["root2", "root8", "rootfifth", "walk", "whole"])
        let bright = 0.3 + r() * 0.6
        func note(_ midi: Int, _ dur: Double) -> [Float] {
            let f0 = Theory.frequency(midi: Double(midi)) * freqMul
            let n = Int(dur * Self.sr)
            return (0..<n).map { i in
                let t = Double(i) / Self.sr
                var v = sin(2 * .pi * f0 * t)
                v += bright * 0.5 * sin(4 * .pi * f0 * t) * exp(-t / 0.3) + bright * 0.25 * sin(6 * .pi * f0 * t) * exp(-t / 0.15)
                let env = min(1, t / 0.005) * exp(-t / 0.9) * min(1, (dur - t) / 0.02)
                return Float(v * env)
            }
        }
        for c in chords {
            let low = 28 + ((c.bass - 4) % 12 + 12) % 12    // E1…D#2
            let fifth = 28 + ((c.root + 7 - 4) % 12 + 12) % 12
            let step = style == "root8" ? beat / 2 : (style == "whole" ? c.end - c.start : beat * (style == "root2" ? 2 : 1))
            var t = c.start, k = 0
            while t < c.end - 0.01 {
                let d = min(step, c.end - t)
                var m = low
                if style == "rootfifth" && k % 2 == 1 { m = fifth }
                if style == "walk" && k > 0 { m = 28 + ((pick(c.tones) - 4) % 12 + 12) % 12 + (chance(0.3) ? 12 : 0) }
                add(note(m, d * 0.92), into: &out, at: t)
                t += step; k += 1
            }
        }
        return out
    }

    private mutating func drumPart(beat: Double, from: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(length * Self.sr))
        var noiseState = rng
        func noise(_ dur: Double, decay: Double, hp: Bool) -> [Float] {
            var prev: Float = 0
            return (0..<Int(dur * Self.sr)).map { i in
                let w = Float(noiseState.next() * 2 - 1)
                let v = hp ? w - prev : w
                prev = w
                return v * Float(exp(-Double(i) / Self.sr / decay))
            }
        }
        func kick() -> [Float] {
            (0..<Int(0.3 * Self.sr)).map { i in
                let t = Double(i) / Self.sr
                return Float(sin(2 * .pi * (50 * t + 60 * 0.03 * (1 - exp(-t / 0.03)))) * exp(-t / 0.12))
            }
        }
        let k = kick(), sn = noise(0.2, decay: 0.07, hp: false), hat = noise(0.05, decay: 0.012, hp: true)
        let sixteenths = chance(0.2)
        var t = from, i = 0
        let end = (chords.last?.end ?? length)
        while t < end {
            let pos = i % meter
            if pos == 0 || (meter == 4 && pos == 2 && chance(0.7)) { add(k, into: &out, at: t, gain: 0.9) }
            if (meter == 4 && (pos == 1 || pos == 3)) || (meter == 3 && pos != 0) { add(sn, into: &out, at: t, gain: 0.5) }
            add(hat, into: &out, at: t, gain: 0.2)
            add(hat, into: &out, at: t + beat / 2, gain: 0.15)
            if sixteenths { add(hat, into: &out, at: t + beat / 4, gain: 0.08); add(hat, into: &out, at: t + 3 * beat / 4, gain: 0.08) }
            t += beat; i += 1
        }
        return out
    }

    private mutating func voicePart(freqMul: Double, beat: Double) -> [Float] {
        var out = [Float](repeating: 0, count: Int(length * Self.sr))
        let steps = minor ? [0, 2, 3, 5, 7, 8, 10] : [0, 2, 4, 5, 7, 9, 11]
        let low = pick([50, 55, 57, 60, 62])
        let scale = (low...(low + 17)).filter { steps.contains((($0 - keyRoot) % 12 + 12) % 12) }
        let rhythms: [[Double]] = [[1, 1, 1, 1], [2, 1, 1], [1.5, 0.5, 2], [0.5, 0.5, 1, 2], [1, 1, -2], [1, 0.5, 0.5, 1, 1], [3, -1]]
        let vowels: [[(Double, Double)]] = [[(730, 90), (1090, 110), (2440, 160)], [(530, 70), (1840, 100), (2480, 160)],
                                            [(300, 60), (870, 90), (2240, 150)], [(570, 80), (840, 90), (2410, 160)]]
        var idx = scale.count / 2
        var t = (chords.first?.start ?? 0) + beat * Double(Int(r() * 4))
        let end = (chords.last?.end ?? length) - beat
        var nNote = 0
        while t < end {
            for d in pick(rhythms) {
                if d < 0 { t += -d * beat; continue }
                if t >= end { break }
                // chord tones on strong notes more often, but passing notes too
                if let c = chords.first(where: { $0.start <= t && t < $0.end }), chance(0.4) {
                    if let j = scale.indices.filter({ c.tones.contains(scale[$0] % 12) }).min(by: { abs($0 - idx) < abs($1 - idx) }) { idx = j }
                } else if chance(0.8) {
                    idx = max(0, min(scale.count - 1, idx + Int((r() * 5).rounded()) - 2))
                }
                let dur = d * beat * 0.9
                let f0 = Theory.frequency(midi: Double(scale[idx])) * freqMul
                let fm = vowels[nNote % vowels.count]
                var harm: [(Double, Double)] = []
                var h = 1.0
                while h * f0 < 6000 {
                    var a = 0.0
                    for x in fm { a += 1 / (1 + pow((h * f0 - x.0) / x.1, 2)) }
                    harm.append((h, (0.15 + a) / h.squareRoot())); h += 1
                }
                let n = Int(dur * Self.sr)
                var seg = [Float](repeating: 0, count: n)
                var phase = 0.0
                for i in 0..<n {
                    let tt = Double(i) / Self.sr
                    let scoop = tt < 0.05 ? -0.4 * (1 - tt / 0.05) : 0
                    let vib = tt > 0.18 ? 0.25 * sin(2 * .pi * 5.4 * tt) * min(1, (tt - 0.18) / 0.2) : 0
                    phase += 2 * .pi * f0 * pow(2, (scoop + vib) / 12) / Self.sr
                    var v = 0.0
                    for x in harm { v += x.1 * sin(x.0 * phase) }
                    seg[i] = Float(v * min(1, tt / 0.03) * min(1, (dur - tt) / 0.04) * 0.25)
                }
                add(seg, into: &out, at: t)
                t += d * beat; nNote += 1
            }
            if chance(0.25) { t += 2 * beat }
        }
        return out
    }
}
#endif
