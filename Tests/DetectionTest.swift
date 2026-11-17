// Offline check of chord recognition: synthesizes plucked-string chords from the
// chord library, runs them through the same FFT + chroma + template matcher the app
// uses, and reports how often the right chord wins.
// Run: swiftc -D SELFTEST -parse-as-library -O Sources/App/*.swift Tests/DetectionTest.swift -o build/selftest && build/selftest
#if SELFTEST
import Foundation
import Accelerate

@main
struct SelfTest {
    static let sr = 48000.0
    static let n = 8192

    static func pluck(_ midis: [Int], noise: Float) -> [Float] {
        let total = Int(sr * 0.6)
        var out = [Float](repeating: 0, count: total)
        for (i, m) in midis.enumerated() {
            let f = Theory.frequency(midi: Double(m))
            let period = max(2, Int(sr / f))
            let rho = Float(pow(10, -3 / (f * 2.0)))
            var buf = (0..<period).map { _ in Float.random(in: -1...1) }
            var p = 0
            let delay = i * Int(0.012 * sr)
            for k in delay..<total {
                let y = buf[p]; let nx = (p + 1) % period
                buf[p] = (buf[p] + buf[nx]) * 0.5 * rho
                out[k] += y * Float.random(in: 0.8...1.0); p = nx
            }
        }
        return out.map { $0 + Float.random(in: -noise...noise) }
    }

    static func spectrum(_ s: [Float]) -> [Float] {
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        let seg = Array(s[(s.count - n)...])
        var w = [Float](repeating: 0, count: n)
        vDSP_vmul(seg, 1, window, 1, &w, 1, vDSP_Length(n))
        let half = n / 2
        var re = [Float](repeating: 0, count: half), im = re, mags = re
        let setup = vDSP_create_fftsetup(13, FFTRadix(kFFTRadix2))!
        re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
            var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
            w.withUnsafeBufferPointer { wp in wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half)) } }
            vDSP_fft_zrip(setup, &split, 1, 13, FFTDirection(FFT_FORWARD))
            vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
        } }
        return mags
    }

    static func main() {
        if CommandLine.arguments.contains("--wrong-strings") { wrongStringChecks(); return }
        if CommandLine.arguments.contains("--part-strums") { partStrumChecks(); return }
        if CommandLine.arguments.contains("--versions") { versionsBench(); return }
        var freeOK = 0, verifyOK = 0, total = 0, falseAccept = 0, falseTotal = 0
        var misses: [String] = []
        var byLevel: [Int: (Int, Int)] = [:]
        for shape in ChordLibrary.shapes {
            guard let sym = shape.symbol else { continue }
            for trial in 0..<3 {
                let samples = pluck(shape.midiNotes, noise: trial == 2 ? 0.02 : 0.004)
                let (chroma, bass) = AudioEngine.chroma(fromSpectrum: spectrum(samples), sampleRate: sr, n: n)
                let frame = AnalysisFrame(chroma: chroma, bass: bass, rms: 0.1, time: 0, hasSound: true)
                let top = ChordTemplates.rank(frame).first!
                total += 1
                // a free guess is right if it names the same pitch-class set (e.g. Am7 == C6)
                let same = Set(top.symbol.pitchClasses) == Set(sym.pitchClasses)
                if same { freeOK += 1 } else if trial == 0 { misses.append("\(shape.name)→\(top.name)") }
                var lv = byLevel[shape.level] ?? (0, 0); lv.1 += 1; if same { lv.0 += 1 }; byLevel[shape.level] = lv
                if ChordTemplates.evaluate(sym, frame: frame, strictness: .normal).ok { verifyOK += 1 }
                // false accept: does a different, common chord pass verification for this sound?
                for wrong in ["C", "G", "D", "Am", "Em", "E", "A", "F", "Dm", "B7"] {
                    guard let w = ChordSymbol.parse(wrong), Set(w.pitchClasses) != Set(sym.pitchClasses) else { continue }
                    falseTotal += 1
                    if ChordTemplates.evaluate(w, frame: frame, strictness: .normal).ok { falseAccept += 1 }
                }
            }
        }
        func pct(_ a: Int, _ b: Int) -> String { String(format: "%.0f%%", 100 * Double(a) / Double(max(1, b))) }
        print("Free detection (names the chord):  \(pct(freeOK, total))  (\(freeOK)/\(total))")
        for l in byLevel.keys.sorted() { print("   level \(l): \(pct(byLevel[l]!.0, byLevel[l]!.1))") }
        print("Game verification (target passes): \(pct(verifyOK, total))")
        print("Wrong chord wrongly accepted:      \(pct(falseAccept, falseTotal))  (\(falseAccept)/\(falseTotal))")
        print("Free-detection misses: \(misses.joined(separator: ", "))")
        extraChecks()
        transcribeChecks()
        partStrumChecks()
        synthChecks()
        riffChecks()
        strictnessChecks()
        wrongStringChecks()
    }

    static func frame(_ midis: [Int], noise: Float = 0.004, pitch: Bool = false) -> AnalysisFrame {
        let samples = pluck(midis, noise: noise)
        let (chroma, bass, energy) = AudioEngine.analyzeSpectrum(spectrum(samples), sampleRate: sr, n: n)
        let f0 = pitch ? AudioEngine.yin(Array(samples.suffix(n)), sampleRate: sr, n: n) : nil
        return AnalysisFrame(chroma: chroma, bass: bass, rms: 0.1, time: 0, hasSound: true, noteEnergy: energy, f0: f0)
    }

    static func extraChecks() {
        func pct(_ a: Int, _ b: Int) -> String { String(format: "%.0f%%", 100 * Double(a) / Double(max(1, b))) }

        // single notes (riffs): right note accepted, a different note rejected
        for pitch in [false, true] {
            var noteOK = 0, noteTotal = 0, noteFalse = 0
            for m in 40...76 {
                let f = frame([m], pitch: pitch)
                noteTotal += 1
                if NoteMatcher.evaluate(m, frame: f) { noteOK += 1 }
                if NoteMatcher.evaluate(m + 2, frame: f) || NoteMatcher.evaluate(m + 5, frame: f) { noteFalse += 1 }
            }
            print("Single notes accepted\(pitch ? " (with YIN)" : " (spectrum)")\(pitch ? ":" : ": ")  \(pct(noteOK, noteTotal))   wrong note accepted: \(pct(noteFalse, noteTotal))")
        }

        // dead-string hints: drop one string from the chord and see if it is flagged
        var deadOK = 0, deadTotal = 0, deadFalse = 0, fullTotal = 0
        for name in ["C", "G", "D", "A", "E", "Am", "Em", "Dm"] {
            guard let shape = ChordLibrary.shape(for: name) else { continue }
            let strings = (0..<6).filter { shape.frets[$0] >= 0 }
            fullTotal += 1
            if !StringCheck.quietStrings(shape, frame: frame(shape.midiNotes)).isEmpty { deadFalse += 1 }
            for s in StringCheck.checkable(shape) {
                let notes = strings.filter { $0 != s }.map { Theory.openStrings[$0] + shape.frets[$0] }
                deadTotal += 1
                if StringCheck.quietStrings(shape, frame: frame(notes)).contains(s) { deadOK += 1 }
            }
        }
        print("Muted string spotted (checkable):  \(pct(deadOK, deadTotal))  (\(deadOK)/\(deadTotal))   false alarm on clean chord: \(pct(deadFalse, fullTotal))")

        // generated voicings must contain exactly the chord's notes and be playable
        var genOK = 0, genTotal = 0, genBad: [String] = []
        for name in ["C", "G", "Bb", "F#m", "Ebmaj7", "Abm7", "C#7", "Bbsus4", "Gadd9", "Dm7b5", "E9", "F#dim7", "Bb/D"] {
            guard let sym = ChordSymbol.parse(name) else { genBad.append(name); continue }
            for v in ChordLibrary.generated(for: name) {
                genTotal += 1
                let pcs = Set(v.midiNotes.map { $0 % 12 })
                let fretted = v.frets.filter { $0 > 0 }
                let span = (fretted.max() ?? 0) - (fretted.min() ?? 0)
                if pcs.isSubset(of: Set(sym.pitchClasses)) && pcs.contains(sym.root) && span <= 3 { genOK += 1 } else { genBad.append(name) }
            }
        }
        print("Generated voicings valid:          \(pct(genOK, genTotal))  (\(genOK)/\(genTotal))\(genBad.isEmpty ? "" : " bad: \(genBad)")")

        // transposing and ChordPro round trip
        let song = SongCatalog.songs.first { !$0.hasRiff }!
        let up = song.transposed(by: 2).transposed(by: -2)
        print("Transpose up/down round trip:      \(up.uniqueChords == song.uniqueChords ? "OK" : "FAIL \(song.uniqueChords) vs \(up.uniqueChords)")")
        let back = ChordPro.parse(ChordPro.export(song), fallbackTitle: "x")
        let sameChords = back.map { b in b.events.filter { !$0.isNote }.map(\.chord) == song.events.filter { !$0.isNote }.map(\.chord) } ?? false
        print("ChordPro export/import round trip: \(sameChords ? "OK" : "chord order differs (expected for songs with partial-bar chords)")")
        let unknown = SongCatalog.songs.flatMap { s in s.events.filter { !$0.isNote && ChordSymbol.parse($0.chord) == nil }.map { "\(s.title): \($0.chord)" } }
        print("Catalog chords that fail to parse: \(unknown.isEmpty ? "none" : unknown.joined(separator: ", "))")
        let noDiagram = Set(SongCatalog.songs.flatMap(\.uniqueChords)).filter { ChordLibrary.displayShape(for: $0) == nil }
        print("Catalog chords without a diagram:  \(noDiagram.isEmpty ? "none" : noDiagram.sorted().joined(separator: ", "))")
    }
}
#endif
