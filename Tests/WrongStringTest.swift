// Wrong-string check: a chord with one string a fret or two off (or an open string touched)
// should be caught and the right string named, while clean chords, other voicings of the same
// chord and the previous chord still ringing should not raise a false alarm.
#if SELFTEST
import Foundation

extension SelfTest {
    static func wrongStringChecks() {
        func pct(_ a: Int, _ b: Int) -> String { String(format: "%.0f%%", 100 * Double(a) / Double(max(1, b))) }
        let shapes = ChordLibrary.shapes.filter { $0.symbol != nil }

        // clean chords
        var clean = 0, cleanFalse = 0
        for shape in shapes {
            for noise: Float in [0.004, 0.02] {
                clean += 1
                if !StringCheck.wrongStrings(shape, frame: frame(shape.midiNotes, noise: noise)).isEmpty { cleanFalse += 1 }
            }
        }

        // another voicing of the same chord, checked against the diagram the app shows
        var alt = 0, altFalse = 0
        for name in ["C", "G", "D", "A", "E", "F", "Am", "Em", "Dm", "Bm", "B7", "G7", "Cmaj7", "F#m", "Bb"] {
            guard let shown = ChordLibrary.displayShape(for: name) else { continue }
            for v in ChordLibrary.voicings(for: name) where v.shape.frets != shown.frets {
                alt += 1
                if !StringCheck.wrongStrings(shown, frame: frame(v.shape.midiNotes)).isEmpty { altFalse += 1 }
            }
        }

        // the last chord's strings that the new shape doesn't play keep ringing (G's low E under D)
        var carry = 0, carryFalse = 0
        let pairs = [("G", "D"), ("G", "Am"), ("G", "A"), ("E", "D"), ("C", "D"), ("G", "C"), ("E", "Am"), ("A", "D"), ("E", "Dm"), ("G", "Dm")]
        for (a, b) in pairs {
            guard let sa = ChordLibrary.displayShape(for: a), let sb = ChordLibrary.displayShape(for: b) else { continue }
            let leftover = (0..<6).filter { sb.frets[$0] < 0 && sa.frets[$0] >= 0 }.map { Theory.openStrings[$0] + sa.frets[$0] }
            guard !leftover.isEmpty else { continue }
            for k in 0..<3 {
                let old = pluck(leftover, noise: 0), new = pluck(sb.midiNotes, noise: 0.004)
                let mix = zip(old, new).map { $0 * [0.4, 0.7, 1.0][k] + $1 }
                let (c, bs, e) = AudioEngine.analyzeSpectrum(spectrum(mix), sampleRate: sr, n: n)
                carry += 1
                if !StringCheck.wrongStrings(sb, frame: AnalysisFrame(chroma: c, bass: bs, rms: 0.1, time: 0, hasSound: true, noteEnergy: e)).isEmpty { carryFalse += 1 }
            }
        }

        // one string off by a fret or two, where that makes a note outside the chord
        var wrong = 0, caught = 0, named = 0, rejected = 0, rejectedBefore = 0
        var missed: [String] = []
        for shape in shapes {
            guard let sym = shape.symbol else { continue }
            let pcs = Set(sym.pitchClasses)
            for s in 0..<6 where shape.frets[s] >= 0 {
                for d in [-1, 1, 2] {
                    let f = shape.frets[s] + d
                    guard f >= 0 else { continue }
                    var frets = shape.frets; frets[s] = f
                    let notes = (0..<6).filter { frets[$0] >= 0 }.map { Theory.openStrings[$0] + frets[$0] }
                    guard !pcs.contains((Theory.openStrings[s] + f) % 12) else { continue }
                    let fr = frame(notes)
                    wrong += 1
                    let w = StringCheck.wrongStrings(shape, frame: fr)
                    if !w.isEmpty { caught += 1 }
                    if w.first == StringCheck.WrongString(string: s, heard: f) { named += 1 }
                    else if missed.count < 12 { missed.append("\(shape.name) \(Theory.stringNames[s])\(d > 0 ? "+" : "")\(d)") }
                    let ok = ChordTemplates.evaluate(sym, frame: fr, strictness: .normal).ok
                    if !ok { rejectedBefore += 1 }
                    if !ok || !w.isEmpty { rejected += 1 }
                }
            }
        }
        print("\nWrong string (a fret or two off):")
        print("   caught: \(pct(caught, wrong))   right string named: \(pct(named, wrong))   chord rejected at Normal: \(pct(rejectedBefore, wrong)) → \(pct(rejected, wrong))  (\(wrong) cases)")
        print("   false alarms: clean chord \(pct(cleanFalse, clean))   other voicing \(pct(altFalse, alt)) (\(alt))   last chord's extra strings ringing \(pct(carryFalse, carry)) (\(carry))")
        if CommandLine.arguments.contains("--verbose") { print("   not named: \(missed.joined(separator: ", "))") }
    }
}
#endif
