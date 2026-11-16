// Checks every riff parses into whole bars, converts to a playable song, and that
// bends, slides and hammer-ons land on the right pitch in the guitar model.
#if SELFTEST
import Foundation
import AVFoundation

extension SelfTest {
    static func riffChecks() {
        var problems: [String] = []
        for r in RiffLibrary.all {
            let bars = r.totalBeats / Double(r.meter)
            if abs(bars - bars.rounded()) > 0.01 { problems.append("\(r.title): \(String(format: "%.2f", bars)) bars (not whole)") }
            if r.notes.contains(where: { $0.frets.contains { $0.fret > 22 } }) { problems.append("\(r.title): fret out of range") }
            let song = r.asSong
            let bad = song.events.filter { $0.noteMidi == nil }
            if !bad.isEmpty { problems.append("\(r.title): \(bad.count) song notes don't parse, e.g. \(bad[0].chord)") }
            if song.events.isEmpty { problems.append("\(r.title): empty") }
        }
        // the tab parser shouldn't silently drop tokens
        let toks = "E0 r:1 A2+D2:2 G5h*3 e12b:1 B8~ D7/ E0m".split(separator: " ").count
        let parsed = Riff.parse("E0 r:1 A2+D2:2 G5h*3 e12b:1 B8~ D7/ E0m", unit: 0.5)
        if parsed.count != toks + 2 { problems.append("parser: \(parsed.count) notes from \(toks) tokens (want \(toks + 2))") }

        // technique pitches: pluck, then measure later in the note
        func pitch(_ ev: [GuitarCore.Event], at t: Double) -> Double? {
            let core = GuitarCore(sampleRate: sr)
            core.enqueue(ev)
            let (l, rr) = renderCore(core, seconds: t + 0.25)
            let mono = zip(l, rr).map { $0 + $1 }
            return AudioEngine.yin(Array(mono[Int(t * sr)..<(Int(t * sr) + 4096)]), sampleRate: sr, n: 4096)
        }
        func cents(_ f: Double?, _ midi: Int) -> Double { f.map { 1200 * log2($0 / Theory.frequency(midi: Double(midi))) } ?? 9999 }
        // B string fret 8 (G4) bent a whole step should sound A4
        let bend = cents(pitch(GuitarSynth.leadEvents(4, fret: 8, tech: "b", length: 1, sampleRate: sr), at: 0.5), 67 + 2)
        // slide into G string fret 9 (E4) arrives on E4
        let slide = cents(pitch(GuitarSynth.leadEvents(3, fret: 9, tech: "/", length: 1, sampleRate: sr), at: 0.4), 64)
        // hammer from G5 (C4) to G7 (D4)
        var ham = GuitarSynth.leadEvents(3, fret: 5, tech: "", length: 0.3, sampleRate: sr)
        ham += GuitarSynth.leadEvents(3, fret: 7, tech: "h", length: 0.5, sampleRate: sr).map { var e = $0; e.delay += Int(0.3 * sr); return e }
        let hammer = cents(pitch(ham, at: 0.55), 62)
        // demo recording: three riffs, one per sound
        var demoL: [Float] = [], demoR: [Float] = []
        for id in ["gravel", "travis", "bluessolo"] {
            guard let r = RiffLibrary.all.first(where: { $0.id == id }) else { continue }
            let core = GuitarCore(sampleRate: sr)
            core.tone = r.tone.rawValue
            let beat = 60 / Double(r.bpm)
            var ev: [GuitarCore.Event] = []
            var last: Set<Int> = []
            for n in r.notes {
                let at = Int((r.swung(n.start) * beat + 0.2) * sr)
                let strings = Set(n.frets.map(\.string))
                if !r.ring || n.isRest { for s in last where !strings.contains(s) { ev.append(.init(kind: .damp, string: s, midi: 0, velocity: 0, bright: 0.998, delay: at, pick: 0)) } ; last = last.intersection(strings) }
                for f in n.frets {
                    ev += GuitarSynth.leadEvents(f.string, fret: f.fret, tech: n.tech, length: (r.swung(n.end) - r.swung(n.start)) * beat,
                                                 velocity: n.frets.count > 1 ? 0.7 : 0.82, sampleRate: sr).map { var e = $0; e.delay += at; return e }
                }
                last.formUnion(strings)
            }
            core.enqueue(ev)
            let (l, rr) = renderCore(core, seconds: min(14, r.duration) + 1.5)
            demoL += l; demoR += rr
        }
        let url = URL(fileURLWithPath: "build/riffs-demo.wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        if let file = try? AVAudioFile(forWriting: url, settings: fmt.settings),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(demoL.count)) {
            buf.frameLength = AVAudioFrameCount(demoL.count)
            demoL.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: demoL.count) }
            demoR.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: demoR.count) }
            try? file.write(from: buf)
        }
        let peak = max(demoL.map(abs).max() ?? 0, demoR.map(abs).max() ?? 0)
        print("\nRiffs & Solos: demo (rock riff on drive, Travis picking on acoustic, blues solo on clean) peak \(String(format: "%.2f", peak)) → build/riffs-demo.wav")
        print("Riffs & Solos: \(RiffLibrary.all.count) riffs, \(problems.isEmpty ? "all parse into whole bars and play as songs" : problems.joined(separator: "; "))")
        print(String(format: "   technique pitch error: bend %.0f cents, slide %.0f cents, hammer-on %.0f cents", bend, slide, hammer))
    }
}
#endif
