// Synthesises band-style mixes (strummed guitar + bass + drums + melody) of known
// progressions and checks the automatic transcriber gets tempo, key and chords back.
#if SELFTEST
import Foundation

extension SelfTest {
    struct Case { var chords: [String]; var bpm: Double; var meter: Int = 4; var key: String; var strum: String = "DUDUDUDU" }

    /// `plan` lays out a whole song: parts (chords, strum, bars) played in order, instead of one loop.
    static func renderMix(_ c: Case, seconds: Double = 30, plan: [(chords: [String], strum: String, bars: Int)] = []) -> [Float] {
        let total = Int(sr * seconds)
        var out = [Float](repeating: 0, count: total)
        let beat = 60 / c.bpm
        var rng = SystemRandomNumberGenerator()
        func add(_ s: [Float], at t: Double, gain: Float) {
            let start = Int(t * sr)
            for (i, v) in s.enumerated() where start + i < total { out[start + i] += v * gain }
        }
        func ks(_ midi: Int, dur: Double) -> [Float] {
            let f = Theory.frequency(midi: Double(midi))
            let period = max(2, Int((sr / f).rounded()))
            let n = Int(dur * sr)
            var buf = (0..<period).map { _ in Float.random(in: -1...1, using: &rng) }
            var o = [Float](repeating: 0, count: n)
            var p = 0
            for k in 0..<n { let nx = (p + 1) % period; o[k] = buf[p]; buf[p] = (buf[p] + buf[nx]) * 0.4985; p = nx }
            return o
        }
        func noise(_ dur: Double, decay: Double, hp: Bool) -> [Float] {
            let n = Int(dur * sr)
            var prev: Float = 0
            return (0..<n).map { i in
                let w = Float.random(in: -1...1, using: &rng)
                let v = hp ? w - prev : w
                prev = w
                return v * Float(exp(-Double(i) / sr / decay))
            }
        }
        func sine(_ midi: Int, dur: Double, decay: Double) -> [Float] {
            let f = Theory.frequency(midi: Double(midi))
            return (0..<Int(dur * sr)).map { i in
                let t = Double(i) / sr
                return Float(sin(2 * .pi * f * t) * exp(-t / decay) * min(1, t * 200))
            }
        }
        // expand "X:2" tokens to beats
        var beats: [String] = []
        for tok in c.chords {
            let parts = tok.split(separator: ":")
            let n = parts.count > 1 ? Int(parts[1])! : c.meter
            beats += Array(repeating: String(parts[0]), count: n)
        }
        var planChords: [String] = [], planStrums: [String] = []
        for part in plan {
            for k in 0..<(part.bars * c.meter) {
                planChords.append(part.chords[(k / c.meter) % part.chords.count])
                planStrums.append(part.strum)
            }
        }
        var t = 0.0, i = 0
        while t < seconds - beat {
            let name = plan.isEmpty ? beats[i % beats.count] : planChords[i % planChords.count]
            let sym = ChordSymbol.parse(name)!
            let shape = ChordLibrary.shape(for: name)!
            let pos = i % c.meter
            // guitar: follow the strum pattern (two slots per beat)
            let pat = Array(plan.isEmpty ? c.strum : planStrums[i % planStrums.count])
            for half in 0..<2 {
                let ch = pat[(pos * 2 + half) % pat.count]
                let at = t + Double(half) * beat / 2
                if ch == "D" { for (k, m) in shape.midiNotes.enumerated() { add(ks(m, dur: beat * 1.2), at: at + Double(k) * 0.008, gain: half == 0 ? 0.16 : 0.12) } }
                if ch == "U" { for (k, m) in shape.midiNotes.reversed().prefix(4).enumerated() { add(ks(m, dur: beat * 0.6), at: at + Double(k) * 0.006, gain: 0.1) } }
            }
            // bass: root on 1 and 3, fifth sometimes
            let root = 36 + sym.root
            if pos % 2 == 0 { add(sine(pos == 2 && i % 8 == 6 ? root + 7 : root, dur: beat * 1.8, decay: 0.5), at: t, gain: 0.35) }
            // drums
            if pos == 0 || pos == 2 { add(sine(36, dur: 0.15, decay: 0.05), at: t, gain: 0.5) }
            if pos == 1 || pos == 3 { add(noise(0.2, decay: 0.06, hp: false), at: t, gain: 0.18) }
            add(noise(0.05, decay: 0.012, hp: true), at: t, gain: 0.08)
            add(noise(0.05, decay: 0.012, hp: true), at: t + beat / 2, gain: 0.05)
            // melody: a chord tone (sometimes a passing note) an octave up
            let tones = sym.pitchClasses
            let mel = 72 + (i % 3 == 2 ? (tones[0] + 2) % 12 : tones[(i / 2) % tones.count])
            add(sine(mel, dur: beat * 0.9, decay: 0.4), at: t, gain: 0.07)
            t += beat; i += 1
        }
        // 1.5 s fade in/out like a preview
        let fade = Int(1.5 * sr)
        for k in 0..<fade { let g = Float(k) / Float(fade); out[k] *= g; out[total - 1 - k] *= g }
        return out
    }

    static func transcribeChecks() {
        let cases = [
            Case(chords: ["G", "D", "Em", "C"], bpm: 120, key: "G major", strum: "D-DU-UDU"),
            Case(chords: ["C", "G", "Am", "F"], bpm: 96, key: "C major", strum: "D-D-D-D-"),
            Case(chords: ["Am", "F", "C", "G"], bpm: 104, key: "A minor", strum: "D-DUDUDU"),
            Case(chords: ["D", "A", "Bm", "G"], bpm: 132, key: "D major"),
            Case(chords: ["E", "A", "B", "A"], bpm: 88, key: "E major", strum: "D-DUDUDU"),
            Case(chords: ["Em", "C", "G", "D"], bpm: 76, key: "E minor", strum: "D---D-DU"),
            Case(chords: ["F", "Bb", "C", "C"], bpm: 110, key: "F major"),
            Case(chords: ["C:2", "G:2", "Am", "F"], bpm: 100, key: "C major"),
            Case(chords: ["G", "C", "G", "D"], bpm: 92, meter: 3, key: "G major", strum: "D-DUDU"),
            Case(chords: ["Dm", "Bb", "F", "C"], bpm: 118, key: "D minor")
        ]
        var tempoOK = 0, keyOK = 0, chordHits = 0, chordTotal = 0, loopOK = 0, meterOK = 0, strumOK = 0, strumSlots = 0, strumSlotTotal = 0
        var report: [String] = []
        for c in cases {
            let mix = renderMix(c)
            guard let r = try? Transcriber.analyze(samples: mix, sampleRate: sr) else { report.append("\(c.chords) → FAILED"); continue }
            if abs(r.bpm - c.bpm) / c.bpm < 0.04 { tempoOK += 1 }
            if r.keyName == c.key || (c.key.hasSuffix("minor") && r.keyName == relativeMajor(c.key)) { keyOK += 1 }
            if r.beatsPerBar == c.meter { meterOK += 1 }
            if r.strum == c.strum { strumOK += 1 }
            if r.strum.count == c.strum.count { strumSlots += zip(r.strum, c.strum).filter { $0 == $1 }.count }
            strumSlotTotal += c.strum.count
            // bar-level accuracy against the truth, allowing for any rotation of the loop
            let truthBars = c.chords.map { $0.contains(":") ? $0 : $0 }
            let got = r.bars.map(\.tokens)
            var best = 0
            for rot in 0..<truthBars.count {
                let hits = got.enumerated().filter { j, g in g == truthBars[(j + rot) % truthBars.count] }.count
                best = max(best, hits)
            }
            chordHits += best; chordTotal += got.count
            let loop = r.sections.first?.tokens(beatsPerBar: r.beatsPerBar).map(\.chord) ?? []
            let truthLoop = c.chords.flatMap { tok -> [String] in let p = tok.split(separator: ":"); return [String(p[0])] }
            let loopMatch = (0..<truthLoop.count).contains { rot in
                let rotated = Array(truthLoop[rot...] + truthLoop[..<rot])
                return loop == rotated || loop == rotated + rotated
            }
            if loopMatch { loopOK += 1 }
            report.append("\(c.chords.joined(separator: " ")) @\(Int(c.bpm)) → \(Int(r.bpm.rounded())) BPM, \(r.keyName), \(r.beatsPerBar)/4, capo \(r.capo), strum \(r.strum) (want \(c.strum)\(r.feel == "strum" ? "" : ", " + r.feel)), \(r.confidenceLabel): \(r.sections.map { "\($0.name)×\($0.repeats) [\($0.chords)]" }.joined(separator: " | "))")
        }
        func pct(_ a: Int, _ b: Int) -> String { String(format: "%.0f%%", 100 * Double(a) / Double(max(1, b))) }
        print("\nAuto chords from a full mix (\(cases.count) synthetic songs):")
        print("   tempo within 4%: \(pct(tempoOK, cases.count))   key: \(pct(keyOK, cases.count))   meter: \(pct(meterOK, cases.count))")
        print("   bars correct: \(pct(chordHits, chordTotal))   whole progression exactly right: \(pct(loopOK, cases.count))")
        print("   strum pattern exactly right: \(pct(strumOK, cases.count))   strum slots right: \(pct(strumSlots, strumSlotTotal))")
        for r in report { print("   " + r) }
    }

    static func relativeMajor(_ key: String) -> String {
        guard let pc = Theory.pitchClass(of: String(key.split(separator: " ")[0])) else { return "" }
        let r = (pc + 3) % 12
        return Theory.name(r, flat: Theory.flatKeys.contains(r)) + " major"
    }
}

extension SelfTest {
    /// Whole songs whose verse and chorus are strummed differently: each part should get its own pattern.
    static func partStrumChecks() {
        func pct(_ a: Int, _ b: Int) -> String { String(format: "%.0f%%", 100 * Double(a) / Double(max(1, b))) }
        let verse = ["G", "D", "Em", "C", "G", "D", "C", "D"], chorus = ["C", "G", "Am", "F", "C", "G", "F", "G"]
        let songs: [(String, String, Double)] = [("D-D-D-D-", "DUDUDUDU", 112), ("D---D-DU", "DUDUDUDU", 96), ("D-DU-UDU", "D-DUDUDU", 120),
                                                 ("D-D-D-D-", "D-DU-UDU", 104), ("D-DU-UDU", "D-DU-UDU", 116), ("DUDUDUDU", "DUDUDUDU", 100)]
        var right = 0, total = 0, splitWhenSame = 0, same = 0
        Transcriber.debugRhythm = CommandLine.arguments.contains("--verbose")
        defer { Transcriber.debugRhythm = false }
        var lines: [String] = []
        for (vs, cs, bpm) in songs {
            let order = [0, 0, 1, 0, 1, 1, 0, 1]
            let plan = order.map { $0 == 0 ? (chords: verse, strum: vs, bars: 8) : (chords: chorus, strum: cs, bars: 8) }
            let barSeconds = 4 * 60 / bpm
            let seconds = Double(order.count * 8) * barSeconds
            let c = Case(chords: verse, bpm: bpm, key: "G major", strum: vs)
            guard let t = try? Transcriber.analyze(samples: renderMix(c, seconds: seconds, plan: plan), sampleRate: sr) else { lines.append("\(vs) / \(cs): failed"); continue }
            // walk the bars part by part, as the song will be played
            var k = 0, ok = 0, n = 0
            var used = Set<String>()
            for sec in t.sections {
                let perPass = Int((sec.tokens(beatsPerBar: t.beatsPerBar).reduce(0) { $0 + $1.beats } / Double(t.beatsPerBar)).rounded())
                for _ in 0..<(perPass * max(1, sec.repeats)) where k < t.bars.count {
                    let mid = (t.bars[k].start + t.bars[k].end) / 2
                    let part = order[min(order.count - 1, Int(mid / (8 * barSeconds)))]
                    let p = sec.strum ?? t.strum
                    used.insert(p)
                    if p == (part == 0 ? vs : cs) { ok += 1 }
                    n += 1; k += 1
                }
            }
            right += ok; total += n
            if vs == cs { same += 1; if used.count > 1 { splitWhenSame += 1 } }
            lines.append("verse \(vs) chorus \(cs) @\(Int(bpm)) → main \(t.strum), parts \(t.sections.map { "\($0.name):\($0.strum ?? "main")" }.joined(separator: " ")) (\(pct(ok, n)) of bars right)")
        }
        print("\nStrumming by part (6 whole songs, verse and chorus strummed differently in 4):")
        print("   bars given the right pattern: \(pct(right, total))   same-strum songs wrongly split: \(splitWhenSame)/\(same)")
        for l in lines { print("   " + l) }
    }
}
#endif
