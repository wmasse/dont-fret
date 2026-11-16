// Renders the guitar model offline: checks every note is in tune and writes a demo recording.
#if SELFTEST
import Foundation
import AVFoundation

extension SelfTest {
    static func renderCore(_ core: GuitarCore, seconds: Double) -> ([Float], [Float]) {
        let total = Int(seconds * core.sr)
        var l = [Float](repeating: 0, count: total), r = l
        var i = 0
        while i < total {
            let n = min(512, total - i)
            l.withUnsafeMutableBufferPointer { lp in r.withUnsafeMutableBufferPointer { rp in
                _ = core.render(lp.baseAddress! + i, rp.baseAddress! + i, n)
            } }
            i += n
        }
        return (l, r)
    }

    static func synthChecks() {
        // tuning: pluck each note alone and measure its pitch
        var worst = 0.0, sum = 0.0, count = 0
        for m in 40...76 {
            let core = GuitarCore(sampleRate: sr)
            let s = Theory.position(midi: m)?.string ?? 0
            core.enqueue([.init(kind: .pluck, string: s, midi: m, velocity: 0.8, bright: 0.6, delay: 0, pick: 0.13)])
            let (l, rr) = renderCore(core, seconds: 0.8)
            let mono = zip(l, rr).map { $0 + $1 }
            guard let f = AudioEngine.yin(Array(mono[Int(0.3 * sr)..<(Int(0.3 * sr) + 8192)]), sampleRate: sr, n: 8192) else { continue }
            let cents = 1200 * log2(f / Theory.frequency(midi: Double(m)))
            if abs(cents) > 20 { print("   off: midi \(m) measured \(String(format: "%.1f", f)) Hz, \(String(format: "%.0f", cents)) cents") }
            worst = max(worst, abs(cents)); sum += abs(cents); count += 1
        }
        print("\nGuitar sound: tuning error avg \(String(format: "%.1f", sum / Double(max(1, count)))) cents, worst \(String(format: "%.1f", worst)) cents (\(count)/37 notes measured)")

        // a demo: G D Em C with a campfire strum at 92 BPM, plus a picked riff
        let core = GuitarCore(sampleRate: sr)
        let beat = 60.0 / 92
        var events: [GuitarCore.Event] = []
        let pattern = Array("D-DU-UDU")
        var bar = 0
        for name in ["G", "D", "Em", "C", "G", "D", "C", "C"] {
            let shape = ChordLibrary.shape(for: name)!
            for (k, ch) in pattern.enumerated() {
                guard let st = StrumStroke(rawValue: ch), st.isStrum else { continue }
                let t = (Double(bar * 4) + Double(k) / 2) * beat + 0.2
                let accent: Float = k == 0 ? 0.95 : (k % 2 == 0 ? 0.8 : 0.6)
                for var e in GuitarSynth.events(for: shape, stroke: st, velocity: accent, sampleRate: sr) {
                    e.delay += Int(t * sr); events.append(e)
                }
            }
            bar += 1
        }
        let riffStart = Double(bar * 4) * beat + 0.6
        for (k, m) in [55, 59, 62, 67, 62, 59, 55, 50].enumerated() {
            let s = Theory.position(midi: m)?.string ?? 3
            events.append(.init(kind: .pluck, string: s, midi: m, velocity: 0.8, bright: 0.6, delay: Int((riffStart + Double(k) * beat / 2) * sr), pick: 0.14))
        }
        core.enqueue(events)
        let (l, r) = renderCore(core, seconds: riffStart + 5 * beat + 3)
        let peak = max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
        print("Guitar sound: demo peak level \(String(format: "%.2f", peak)) (must stay below 1.0 — no clipping)")
        let url = URL(fileURLWithPath: "build/guitar-demo.wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        if let file = try? AVAudioFile(forWriting: url, settings: fmt.settings),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(l.count)) {
            buf.frameLength = AVAudioFrameCount(l.count)
            l.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: l.count) }
            r.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: r.count) }
            try? file.write(from: buf)
            print("Guitar sound: demo written to build/guitar-demo.wav")
        }
        // how a single G strum rings out
        let g = GuitarCore(sampleRate: sr)
        g.enqueue(GuitarSynth.events(for: ChordLibrary.shape(for: "G")!, stroke: .down, velocity: 0.9, sampleRate: sr))
        let (gl, _) = renderCore(g, seconds: 4)
        let marks = [0.05, 0.5, 1.0, 2.0, 3.0, 3.9].map { t -> String in
            let a = Int(t * sr), seg = gl[a..<min(gl.count, a + 2205)]
            let rms = sqrt(seg.map { $0 * $0 }.reduce(0, +) / Float(seg.count))
            return String(format: "%.1fs %.0f dB", t, 20 * log10(max(1e-6, rms)))
        }
        print("Guitar sound: one strum decays " + marks.joined(separator: " · "))
        // speed: how much of real time it takes to render
        let t0 = Date()
        let busy = GuitarCore(sampleRate: sr)
        busy.enqueue((0..<20).flatMap { k in GuitarSynth.events(for: ChordLibrary.shape(for: "C")!, stroke: .down, velocity: 0.8, sampleRate: sr).map { e in var e = e; e.delay += Int(Double(k) * 0.5 * sr); return e } })
        _ = renderCore(busy, seconds: 10)
        print("Guitar sound: renders 10 s of audio in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
    }
}
#endif
