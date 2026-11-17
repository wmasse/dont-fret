// Sound lab: offline rendering of the guitar for listening tests and measurements.
//   build/selftest --render-events events.txt out.wav     render an event list (see scripts/soundlab)
//   build/selftest --demos build/demos                    write a set of demo recordings
#if SELFTEST
import Foundation
import AVFoundation

extension SelfTest {
    /// Handles the sound-lab command-line options. Returns true if one was given.
    static func soundLab(_ args: [String]) -> Bool {
        if let i = args.firstIndex(of: "--render-events"), args.count > i + 2 {
            let (tone, events, length) = readEvents(args[i + 1], sampleRate: 44100)
            let core = GuitarCore(sampleRate: 44100)
            core.tone = tone
            core.enqueue(events)
            let t0 = Date()
            let (l, r) = renderCore(core, seconds: length + 2.5)
            writeWAV(args[i + 2], l, r, sampleRate: 44100)
            print(String(format: "rendered %.1f s in %.2f s (%.0f× real time) → %@", length + 2.5, Date().timeIntervalSince(t0),
                         (length + 2.5) / max(0.001, Date().timeIntervalSince(t0)), args[i + 2]))
            return true
        }
        if let i = args.firstIndex(of: "--demos"), args.count > i + 1 {
            demos(into: args[i + 1])
            return true
        }
        return false
    }

    /// Event list, one per line: `time kind string midi detune velocity bright pick touch mute decay keep`
    /// (kind p pluck, d damp, c chuck, r retune, h hold; touch 0 pick, 1 thumb, 2 finger). `# tone N` sets the tone.
    static func readEvents(_ path: String, sampleRate sr: Double) -> (Int, [GuitarCore.Event], Double) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); return (0, [], 0) }
        var tone = 0, end = 0.0
        var out: [GuitarCore.Event] = []
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ").map(String.init)
            if f.first == "#" { if f.count >= 3, f[1] == "tone" { tone = Int(f[2]) ?? 0 }; continue }
            guard f.count >= 12, let t = Double(f[0]) else { continue }
            let kind: GuitarCore.Kind = ["p": .pluck, "d": .damp, "c": .chuck, "r": .retune, "h": .hold][f[1]] ?? .pluck
            var e = GuitarCore.Event(kind: kind, string: Int(f[2]) ?? 0, midi: Int(f[3]) ?? 40, velocity: Float(f[5]) ?? 0.8,
                                     bright: Float(f[6]) ?? 0.6, delay: Int(t * sr), pick: Float(f[7]) ?? 0.15)
            e.detune = Float(f[4]) ?? 0
            e.touch = Touch(rawValue: UInt8(f[8]) ?? 0) ?? .pick
            e.mute = Float(f[9]) ?? 0
            e.decay = Float(f[10]) ?? 0
            e.keep = Float(f[11]) ?? 0.12
            out.append(e)
            end = max(end, t)
        }
        return (tone, out, end)
    }

    /// Writes events in the `--render-events` format, so the same performance can be rendered again
    /// (by another build of the engine, for A/B listening).
    static func writeEvents(_ path: String, _ events: [GuitarCore.Event], tone: Int, sampleRate sr: Double) {
        let code: [GuitarCore.Kind: String] = [.pluck: "p", .damp: "d", .chuck: "c", .retune: "r", .hold: "h"]
        var text = "# tone \(tone)\n"
        for e in events.sorted(by: { $0.delay < $1.delay }) {
            text += String(format: "%.5f %@ %d %d %.4f %.3f %.3f %.3f %d %.3f %.3f %.3f\n", Double(e.delay) / sr, code[e.kind] ?? "p", e.string, e.midi,
                           e.detune, e.velocity, e.bright, e.pick, Int(e.touch.rawValue), e.mute, e.decay, e.keep)
        }
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    static func writeWAV(_ path: String, _ l: [Float], _ r: [Float], sampleRate sr: Double) {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        guard let file = try? AVAudioFile(forWriting: url, settings: fmt.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(l.count)) else { print("can't write \(path)"); return }
        buf.frameLength = AVAudioFrameCount(l.count)
        l.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: l.count) }
        r.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: r.count) }
        try? file.write(from: buf)
    }

    /// Demo recordings covering every way the app plays the guitar.
    static func demos(into dir: String) {
        let sr = 44100.0
        func render(_ name: String, tone: Int = 0, seconds: Double, _ build: (inout [GuitarCore.Event]) -> Void) {
            let core = GuitarCore(sampleRate: sr)
            core.tone = tone
            var ev: [GuitarCore.Event] = []
            build(&ev)
            core.enqueue(ev)
            let (l, r) = renderCore(core, seconds: seconds)
            let peak = max(l.map(abs).max() ?? 0, r.map(abs).max() ?? 0)
            writeWAV("\(dir)/\(name).wav", l, r, sampleRate: sr)
            writeEvents("\(dir)/\(name).events.txt", ev, tone: tone, sampleRate: sr)
            print(String(format: "   %-22@ peak %.2f", name as NSString, peak))
        }
        func at(_ e: [GuitarCore.Event], _ t: Double) -> [GuitarCore.Event] { e.map { var x = $0; x.delay += Int(t * sr); return x } }
        func shape(_ n: String) -> ChordShape { ChordLibrary.shape(for: n) ?? ChordLibrary.shapes[0] }
        print("\nSound lab demos → \(dir)")

        // 1. campfire strum, G D Em C ×2 at 92 BPM
        render("strum-campfire", seconds: 23) { ev in
            let beat = 60.0 / 92
            for (bar, name) in ["G", "D", "Em", "C", "G", "D", "C", "C"].enumerated() {
                for (k, ch) in Array("D-DU-UDU").enumerated() {
                    guard let st = StrumStroke(rawValue: ch), st.isStrum else { continue }
                    let accent: Float = k == 0 ? 0.95 : (k % 2 == 0 ? 0.8 : 0.6)
                    ev += at(GuitarSynth.events(for: shape(name), stroke: st, velocity: accent, sampleRate: sr), (Double(bar * 4) + Double(k) / 2) * beat + 0.1)
                }
            }
        }
        // 2. fingerpicking: thumb on the bass, fingers on the treble, C Am F G at 76 BPM
        render("fingerpicking", seconds: 15) { ev in
            let beat = 60.0 / 76
            for (bar, name) in ["C", "Am", "F", "G", "C"].enumerated() {
                let sh = shape(name)
                let played = (0..<6).filter { sh.frets[$0] >= 0 }
                let bass = played[0], alt = played.count > 1 ? played[1] : played[0]
                let treble = Array(played.suffix(3))
                let slots: [(Int, Touch)] = [(bass, .thumb), (treble[2], .finger), (alt, .thumb), (treble[1], .finger),
                                             (bass, .thumb), (treble[0], .finger), (alt, .thumb), (treble[1], .finger)]
                for (k, (s, touch)) in slots.enumerated() where bar < 4 || k == 0 {
                    let t = (Double(bar * 4) + Double(k) / 2) * beat + 0.1
                    ev.append(.init(kind: .pluck, string: s, midi: Theory.openStrings[s] + sh.frets[s], velocity: k % 2 == 0 ? 0.75 : 0.55,
                                    bright: touch == .thumb ? 0.45 : 0.55, delay: Int(t * sr), pick: 0.2, touch: touch))
                    if k == 0 && bar < 4 {   // pinch: thumb and the top string together on the downbeat
                        ev.append(.init(kind: .pluck, string: treble[2], midi: Theory.openStrings[treble[2]] + sh.frets[treble[2]], velocity: 0.6,
                                        bright: 0.55, delay: Int(t * sr) + 40, pick: 0.2, touch: .finger))
                    }
                }
            }
        }
        // 3. every open string, then a fretted note on each, to hear sustain and timbre
        render("strings", seconds: 26) { ev in
            for s in 0..<6 {
                ev.append(.init(kind: .pluck, string: s, midi: Theory.openStrings[s], velocity: 0.8, bright: 0.6, delay: Int((Double(s) * 2.2 + 0.1) * sr), pick: 0.15))
                ev.append(.damp(s, at: Int((Double(s) * 2.2 + 2.0) * sr), seconds: 0.15))
                ev.append(.init(kind: .pluck, string: s, midi: Theory.openStrings[s] + 5, velocity: 0.8, bright: 0.6, delay: Int((13.3 + Double(s) * 2.2) * sr), pick: 0.15))
            }
        }
        // 4. sixteenth funk with chucks, Em7 at 96 BPM
        render("strum-funk-chucks", seconds: 11) { ev in
            let sixteenth = 60.0 / 96 / 4
            let pattern = Array("DXDUXUDUDXDUXUDU")
            for bar in 0..<4 {
                for (k, ch) in pattern.enumerated() {
                    let st: StrumStroke = ch == "X" ? .mute : (ch == "D" ? .down : .up)
                    let v: Float = k % 4 == 0 ? 0.85 : 0.6
                    ev += at(GuitarSynth.events(for: shape("Em7"), stroke: st, velocity: v, strings: [2, 3, 4, 5], sampleRate: sr),
                             Double(bar * 16 + k) * sixteenth + 0.1)
                }
            }
        }
        // 5. soft thumb strums, a ballad feel
        render("strum-thumb", seconds: 13) { ev in
            let beat = 60.0 / 70
            for (bar, name) in ["D", "A", "Bm", "G"].enumerated() {
                for b in 0..<4 {
                    ev += at(GuitarSynth.events(for: shape(name), stroke: .down, velocity: b == 0 ? 0.75 : 0.55, touch: .thumb, sampleRate: sr),
                             (Double(bar * 4 + b)) * beat + 0.1)
                }
            }
        }
        // 6. riffs on their own sounds
        for (id, file) in [("gravel", "riff-drive"), ("travis", "riff-acoustic-travis"), ("bluessolo", "riff-clean-blues"), ("gallop", "riff-drive-palm-mute")] {
            guard let r = RiffLibrary.all.first(where: { $0.id == id }) else { continue }
            render(file, tone: r.tone.rawValue, seconds: min(14, r.duration) + 1.5) { ev in
                let beat = 60 / Double(r.bpm)
                var last: Set<Int> = []
                for n in r.notes {
                    let t = r.swung(n.start) * beat + 0.2
                    let strings = Set(n.frets.map(\.string))
                    if !r.ring || n.isRest {
                        for s in last where !strings.contains(s) { ev.append(.damp(s, at: Int(t * sr), seconds: 0.12)) }
                        last = last.intersection(strings)
                    }
                    for f in n.frets {
                        let touch = RiffPlayer.touch(for: r, string: f.string)
                        ev += at(GuitarSynth.leadEvents(f.string, fret: f.fret, tech: n.tech, length: (r.swung(n.end) - r.swung(n.start)) * beat,
                                                        velocity: n.frets.count > 1 ? 0.7 : 0.82, touch: touch, sampleRate: sr), t)
                    }
                    last.formUnion(strings)
                }
            }
        }
        // 7. the same G chord on all three tones
        for tone in 0..<3 {
            render("chord-G-tone\(tone)", tone: tone, seconds: 5) { ev in
                ev += at(GuitarSynth.events(for: shape("G"), stroke: .down, velocity: 0.9, sampleRate: sr), 0.1)
            }
        }
    }
}
#endif
