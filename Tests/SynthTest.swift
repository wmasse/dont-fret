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
            if abs(cents) > 6 { print("   off: midi \(m) measured \(String(format: "%.1f", f)) Hz, \(String(format: "%.1f", cents)) cents") }
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
        soundQualityChecks()
    }

    /// Regression checks for the guitar engine's building blocks and output.
    static func soundQualityChecks() {
        var problems: [String] = []
        // 1. partitioned convolution matches direct convolution
        var g = SeededRandom(seed: 3)
        let ir = (0..<9000).map { _ in Float(g.gaussian()) * 0.05 }, x = (0..<6000).map { _ in Float(g.gaussian()) }
        let conv = Convolver(left: ir, right: ir.map { -$0 }, block: 256)
        var out = [Float](repeating: 0, count: 6144), outR = out
        var input = x + [Float](repeating: 0, count: 144)
        for b in 0..<24 {
            input.withUnsafeBufferPointer { ip in out.withUnsafeMutableBufferPointer { op in outR.withUnsafeMutableBufferPointer { rp in
                conv.process(ip.baseAddress! + b * 256, op.baseAddress! + b * 256, rp.baseAddress! + b * 256)
            } } }
        }
        var worst: Float = 0
        for n in stride(from: 0, to: 6144, by: 7) {
            var d: Float = 0
            for k in 0...min(n, ir.count - 1) where n - k < x.count { d += ir[k] * x[n - k] }
            worst = max(worst, abs(out[n] - d), abs(outR[n] + d))
        }
        if worst > 1e-3 { problems.append("convolver error \(worst)") }
        // 2. a strum: finite, no DC, stereo but mono-compatible
        let core = GuitarCore(sampleRate: sr)
        core.enqueue(GuitarSynth.events(for: ChordLibrary.shape(for: "C")!, stroke: .down, velocity: 0.9, sampleRate: sr))
        let (l, r) = renderCore(core, seconds: 3)
        let finite = !l.contains { !$0.isFinite } && !r.contains { !$0.isFinite }
        let dc = abs(l.reduce(0, +) / Float(l.count))
        let corr = zip(l, r).reduce(0) { $0 + Double($1.0 * $1.1) } / sqrt(l.reduce(0) { $0 + Double($1 * $1) } * r.reduce(0) { $0 + Double($1 * $1) })
        if !finite { problems.append("non-finite samples") }
        if dc > 1e-3 { problems.append("DC offset \(dc)") }
        if corr < 0.3 || corr > 0.97 { problems.append(String(format: "stereo correlation %.2f", corr)) }
        // 3. touch: a thumb is darker than a finger, a finger darker than a pick (share of energy above 2 kHz)
        func brightness(_ touch: Touch) -> Double {
            let c = GuitarCore(sampleRate: sr)
            c.enqueue([.init(kind: .pluck, string: 3, midi: 57, velocity: 0.8, bright: 0.6, delay: 0, pick: 0.2, touch: touch)])
            let (a, _) = renderCore(c, seconds: 0.4)
            var hp1 = Biquad.highpass(2000, q: 0.7, sr: sr), hp2 = Biquad.highpass(2000, q: 0.7, sr: sr)
            var all = 0.0, high = 0.0
            for v in a { let h = hp2.process(hp1.process(v)); all += Double(v * v); high += Double(h * h) }
            return 100 * high / max(1e-12, all)
        }
        let (ct, cf, cp) = (brightness(.thumb), brightness(.finger), brightness(.pick))
        if !(ct < cf && cf < cp) { problems.append(String(format: "touch brightness thumb %.1f%% finger %.1f%% pick %.1f%%", ct, cf, cp)) }
        // 4. sympathetic resonance stays stable: free strings, repeated notes, 20 s
        let free = GuitarCore(sampleRate: sr)
        var notes: [GuitarCore.Event] = []
        for k in 0..<30 {
            let even = k % 2 == 0
            notes.append(GuitarCore.Event(kind: .pluck, string: even ? 3 : 1, midi: even ? 57 : 45, velocity: 0.9, bright: 0.6,
                                          delay: Int(Double(k) * 0.2 * sr), pick: 0.15))
        }
        free.enqueue(notes)
        let (fl, _) = renderCore(free, seconds: 20)
        let early = sqrt(fl[0..<Int(2 * sr)].reduce(0) { $0 + $1 * $1 } / Float(2 * sr))
        let late = sqrt(fl[Int(17 * sr)...].reduce(0) { $0 + $1 * $1 } / Float(3 * sr))
        if !(late.isFinite && late < early * 0.1) { problems.append("sympathetic ringing grows (\(early) → \(late))") }
        // 5. real-time: the slowest audio block vs its duration
        let busy = GuitarCore(sampleRate: 44100)
        var strums: [GuitarCore.Event] = []
        for k in 0..<12 {
            let shape = ChordLibrary.shape(for: k % 2 == 0 ? "G" : "Em")!
            let stroke: StrumStroke = k % 2 == 0 ? .down : .up
            for var e in GuitarSynth.events(for: shape, stroke: stroke, velocity: 0.95, sampleRate: 44100) {
                e.delay += Int(Double(k) * 0.25 * 44100)
                strums.append(e)
            }
        }
        busy.enqueue(strums)
        var lb = [Float](repeating: 0, count: 256), rb = lb
        var slowest = 0.0
        for _ in 0..<(44100 * 4 / 256) {
            let t = Date()
            lb.withUnsafeMutableBufferPointer { lp in rb.withUnsafeMutableBufferPointer { rp in _ = busy.render(lp.baseAddress!, rp.baseAddress!, 256) } }
            slowest = max(slowest, Date().timeIntervalSince(t))
        }
        let budget = 256 / 44100.0
        if slowest > budget * 0.5 { problems.append(String(format: "slowest block %.2f ms of %.2f ms", slowest * 1000, budget * 1000)) }
        print(String(format: "Guitar sound: convolver error %.1e, stereo correlation %.2f, energy above 2 kHz thumb/finger/pick %.1f/%.1f/%.1f%%, slowest block %.2f ms of %.2f ms",
                     worst, corr, ct, cf, cp, slowest * 1000, budget * 1000))
        print("Guitar sound: quality checks " + (problems.isEmpty ? "all pass" : "FAILED: " + problems.joined(separator: "; ")))
    }
}
#endif
