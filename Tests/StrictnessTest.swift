// False-positive check for in-game chord verification, at every strictness level: the right
// chord must pass, while a different chord, room noise, two strings only, or a chord with one
// string on the wrong fret should not.
#if SELFTEST
import Foundation

extension SelfTest {
    static func strictnessChecks() {
        print("\nChord verification by strictness (right chord should pass, the rest should not):")
        func pct(_ a: Int, _ b: Int) -> String { String(format: "%5.1f%%", 100 * Double(a) / Double(max(1, b))) }
        let common = ["C", "G", "D", "Am", "Em", "E", "A", "F", "Dm", "B7", "Cmaj7", "G7", "D7", "A7", "E7", "Bm", "F#m", "C7", "Asus2", "Dsus4"]
        let shapes = ChordLibrary.shapes.filter { $0.symbol != nil }
        var frames: [(ChordSymbol, String, AnalysisFrame)] = []
        for shape in shapes { for t in 0..<3 { frames.append((shape.symbol!, shape.name, frame(shape.midiNotes, noise: t == 2 ? 0.02 : 0.004))) } }
        var noise: [AnalysisFrame] = []
        for k in 0..<60 {
            // broadband noise, a hum, and random note clusters (talking / room / fret noise)
            let samples: [Float]
            if k < 20 { samples = (0..<Int(sr * 0.6)).map { _ in Float.random(in: -0.05...0.05) } }
            else { let ms = (0..<(k % 2 == 0 ? 5 : 7)).map { _ in Int.random(in: 40...80) }; samples = pluck(ms, noise: 0.01) }
            let (c, b, e) = AudioEngine.analyzeSpectrum(spectrum(samples), sampleRate: sr, n: n)
            noise.append(AnalysisFrame(chroma: c, bass: b, rms: 0.1, time: 0, hasSound: true, noteEnergy: e))
        }
        // two strings only, and one string on the wrong fret
        var partial: [(ChordSymbol, AnalysisFrame)] = [], oneOff: [(ChordSymbol, AnalysisFrame)] = []
        for shape in shapes {
            let notes = shape.midiNotes
            if notes.count >= 4 { partial.append((shape.symbol!, frame(Array(notes.suffix(2))))) }
            for i in [1, notes.count - 2] where i >= 0 && i < notes.count {
                var w = notes; w[i] += 1
                if Set(w.map { $0 % 12 }) != Set(notes.map { $0 % 12 }) { oneOff.append((shape.symbol!, frame(w))) }
            }
        }
        for st in Strictness.allCases {
            var pass = 0, wrong = 0, wrongTotal = 0, nz = 0, nzTotal = 0, part = 0, off = 0
            var pairs: [String: Int] = [:]
            for (sym, name, f) in frames {
                if ChordTemplates.evaluate(sym, frame: f, strictness: st).ok { pass += 1 }
                for c in common {
                    guard let w = ChordSymbol.parse(c), Set(w.pitchClasses) != Set(sym.pitchClasses) else { continue }
                    wrongTotal += 1
                    if ChordTemplates.evaluate(w, frame: f, strictness: st).ok { wrong += 1; pairs["\(name)→\(c)", default: 0] += 1 }
                }
            }
            for f in noise { for c in common { nzTotal += 1; if ChordTemplates.evaluate(ChordSymbol.parse(c)!, frame: f, strictness: st).ok { nz += 1 } } }
            for (s, f) in partial where ChordTemplates.evaluate(s, frame: f, strictness: st).ok { part += 1 }
            for (s, f) in oneOff where ChordTemplates.evaluate(s, frame: f, strictness: st).ok { off += 1 }
            print("   \(st.title.padding(toLength: 8, withPad: " ", startingAt: 0)) right chord passes \(pct(pass, frames.count))   wrong chord passes \(pct(wrong, wrongTotal))   noise passes \(pct(nz, nzTotal))   2 strings pass \(pct(part, partial.count))   1 wrong note passes \(pct(off, oneOff.count))")
            if CommandLine.arguments.contains("--verbose") {
                let top = pairs.sorted { $0.value > $1.value }.prefix(25).map { "\($0.key)×\($0.value)" }
                print("    " + top.joined(separator: ", "))
            }
        }
        // the right chords that fail, at normal
        var fails: [String] = []
        for (sym, name, f) in frames where !ChordTemplates.evaluate(sym, frame: f, strictness: .normal).ok { fails.append(name) }
        print("   right chords rejected at Normal: \(Set(fails).sorted().joined(separator: ", "))")
    }
}
#endif
