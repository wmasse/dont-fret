import Foundation
import AVFoundation

// MARK: - Guitar synth (public API)
//
// The sound itself is in GuitarEngine.swift (strings, pickups, amp), GuitarBody.swift (body,
// microphones, room) and GuitarDSP.swift (convolution, filters). This file turns musical requests
// (strum this chord, pick this string, bend this note) into string events, the way a player's
// hands would: strings a few milliseconds apart, the fretting hand muting what isn't played.

final class GuitarSynth {
    static let shared = GuitarSynth()
    /// A second guitar for a song's melody, so the tune doesn't cut off the strings of the chords.
    static let melody = GuitarSynth()
    private let engine = AVAudioEngine()
    private let clickPlayer = AVAudioPlayerNode()
    private let sr: Double = 44100
    private let core: GuitarCore
    private var source: AVAudioSourceNode!
    private let clickFormat: AVAudioFormat
    private var clickHi: AVAudioPCMBuffer?
    private var clickLo: AVAudioPCMBuffer?
    var volume: Float = 0.9 { didSet { source.volume = volume } }

    enum Tone: Int, CaseIterable, Identifiable {
        case acoustic, clean, drive
        var id: Int { rawValue }
        var name: String { ["Acoustic", "Electric Clean", "Electric Drive"][rawValue] }
        var icon: String { ["guitars", "bolt", "flame.fill"][rawValue] }
    }
    var tone: Tone = .acoustic { didSet { core.tone = tone.rawValue } }

    /// Builds the guitar's body and amp responses in the background at launch, so the first note is instant.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            for t in 0..<3 { _ = GuitarBody.impulseResponse(tone: t, sr: 44100) }
        }
    }

    /// Real guitars are never exactly in tune; chords get these tiny per-string offsets (cents).
    /// Single notes (the tuner's reference) stay exact.
    static let stringTuning: [Float] = [1.2, -0.9, 0.6, -1.1, 1.4, -0.5]

    private init() {
        core = GuitarCore(sampleRate: sr)
        clickFormat = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        let c = core
        source = AVAudioSourceNode(format: stereo) { isSilence, _, frames, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard list.count >= 2, let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let sounding = c.render(l, r, Int(frames))
            if !sounding { isSilence.pointee = true }
            return noErr
        }
        engine.attach(source)
        engine.attach(clickPlayer)
        engine.connect(source, to: engine.mainMixerNode, format: stereo)
        engine.connect(clickPlayer, to: engine.mainMixerNode, format: clickFormat)
        source.volume = volume
        clickHi = makeClick(freq: 1760, gain: 0.55)
        clickLo = makeClick(freq: 1175, gain: 0.35)
    }

    private func ensureRunning() {
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
        }
    }

    /// Plays events built elsewhere (custom patterns). Delays are in samples at 44.1 kHz.
    func play(_ events: [GuitarCore.Event]) {
        ensureRunning()
        core.enqueue(events)
    }

    /// Strum a chord shape like a person would: strings a few milliseconds apart, a little
    /// variation in timing and force, lighter up-strums that only catch the top strings.
    /// - Parameters:
    ///   - ring: how long the microphone ignores the guitar's own sound; strings ring until stopped.
    ///   - silent: when true the microphone keeps listening (used by demos that aren't scored).
    ///   - velocity: 0…1 how hard the strum is.
    ///   - strings: only strum these strings (e.g. the top four for a light "chick").
    ///   - chop: stop the strings this many seconds later (reggae chops, staccato).
    ///   - touch: a plectrum, or a soft thumb strum.
    func strum(_ shape: ChordShape, stroke: StrumStroke = .down, ring: Double = 2.2, silent: Bool = false, velocity: Float = 0.9,
               strings: [Int]? = nil, chop: Double? = nil, touch: Touch = .pick) {
        if !silent && stroke != .rest { AudioEngine.shared.suppressSelfSound(for: min(ring, 1.6)) }
        ensureRunning()
        var ev = Self.events(for: shape, stroke: stroke, velocity: velocity, strings: strings, touch: touch)
        if let chop {
            let at = Int(chop * sr)
            ev += ev.filter { $0.kind == .pluck }.map { GuitarCore.Event.damp($0.string, at: $0.delay + at, seconds: 0.05) }
        }
        core.enqueue(ev)
    }

    /// Pick one string at a fret. `palmMute` rests the hand on the strings for a short, chunky note.
    /// `touch` picks with a plectrum, or plucks with the thumb or a finger (fingerstyle).
    func pickString(_ string: Int, fret: Int, velocity: Float = 0.75, palmMute: Bool = false, bright: Float = 0.6, touch: Touch = .pick) {
        ensureRunning()
        let s = max(0, min(5, string))
        let beta: Float = touch == .pick ? (palmMute ? .random(in: 0.06...0.09) : .random(in: 0.12...0.2)) : .random(in: 0.17...0.24)
        core.enqueue([.init(kind: .pluck, string: s, midi: Theory.openStrings[s] + max(0, fret),
                            velocity: velocity * Float.random(in: 0.92...1.05), bright: palmMute ? bright * 0.75 : bright,
                            delay: Int(Double.random(in: 0...0.004) * sr), pick: beta, touch: touch, mute: palmMute ? 0.85 : 0)])
    }

    /// Lead-guitar techniques on one string. `tech`: "" pick, "h" hammer-on, "p" pull-off,
    /// "/" slide in, "b" bend up a whole step, "~" vibrato, "m" palm mute. `length` is in seconds.
    func lead(_ string: Int, fret: Int, tech: String, length: Double, velocity: Float = 0.8, touch: Touch = .pick) {
        ensureRunning()
        core.enqueue(Self.leadEvents(string, fret: fret, tech: tech, length: length, velocity: velocity, touch: touch))
    }

    static func leadEvents(_ string: Int, fret: Int, tech: String, length: Double, velocity: Float = 0.8, touch: Touch = .pick,
                           sampleRate sr: Double = 44100) -> [GuitarCore.Event] {
        let s = max(0, min(5, string))
        let midi = Theory.openStrings[s] + max(0, fret)
        let start = Int(Double.random(in: 0...0.003) * sr)
        var ev: [GuitarCore.Event] = []
        let vel = velocity * Float.random(in: 0.92...1.05)
        let beta: Float = touch == .pick ? .random(in: 0.12...0.19) : .random(in: 0.17...0.24)
        switch tech {
        case "h", "p":
            // the fretting hand changes the note: the string keeps ringing; the finger adds a soft attack
            ev.append(.init(kind: .pluck, string: s, midi: midi, velocity: vel * 0.3, bright: 0.35, delay: start, pick: 0.35, keep: 0.85, touch: .finger))
        case "/":
            ev.append(.init(kind: .pluck, string: s, midi: midi - 2, velocity: vel, bright: 0.6, delay: start, pick: beta, touch: touch))
            for k in 1...6 {
                ev.append(.init(kind: .retune, string: s, midi: midi - 2, velocity: 0, bright: 0, delay: start + Int(Double(k) * 0.012 * sr), pick: 0, detune: Float(k) / 3))
            }
        default:
            ev.append(.init(kind: .pluck, string: s, midi: midi, velocity: vel, bright: tech == "m" ? 0.45 : 0.62, delay: start,
                            pick: tech == "m" ? 0.08 : beta, touch: touch, mute: tech == "m" ? 0.85 : 0))
        }
        if tech == "b" {
            // push the string up a whole step, a moment after picking
            let steps = 10
            for k in 1...steps {
                let t = 0.05 + Double(k) * min(0.16, length * 0.4) / Double(steps)
                ev.append(.init(kind: .retune, string: s, midi: midi, velocity: 0, bright: 0, delay: start + Int(t * sr), pick: 0,
                                detune: 2 * Float(sin(Double(k) / Double(steps) * .pi / 2))))
            }
        }
        if tech == "~" {
            // vibrato: a gentle pitch wobble that grows a little
            var t = 0.12
            while t < length - 0.03 {
                let depth = Float(min(1, (t - 0.12) / 0.3)) * 0.28
                ev.append(.init(kind: .retune, string: s, midi: midi, velocity: 0, bright: 0, delay: start + Int(t * sr), pick: 0,
                                detune: depth * Float(sin(2 * .pi * 5.5 * t))))
                t += 0.025
            }
        }
        return ev
    }

    /// Stop one string gently (between notes of a riff).
    func damp(_ string: Int, after seconds: Double = 0) {
        core.enqueue([.damp(max(0, min(5, string)), at: Int(seconds * sr), seconds: 0.12)])
    }

    /// Stop every string (e.g. when playback stops).
    func silence() {
        core.enqueue((0..<6).map { .damp($0, at: 0, seconds: 0.3) })
    }

    /// Single note on its most natural string, exactly in tune (the tuner uses it as a reference).
    func pluck(midi: Int, seconds: Double = 2.6, velocity: Float = 0.85) {
        AudioEngine.shared.suppressSelfSound(for: min(seconds, 2.0))
        ensureRunning()
        let s = Theory.position(midi: midi)?.string ?? max(0, min(5, (midi - 40) / 5))
        core.enqueue([.init(kind: .pluck, string: s, midi: midi, velocity: velocity, bright: 0.55, delay: 0, pick: 0.15)])
    }

    func click(accent: Bool) {
        ensureRunning()
        AudioEngine.shared.noteClick()
        guard let b = accent ? clickHi : clickLo else { return }
        clickPlayer.scheduleBuffer(b, at: nil, options: [], completionHandler: nil)
        if !clickPlayer.isPlaying { clickPlayer.play() }
    }

    /// The string events for one stroke of a chord.
    /// Timing follows measurements of professional players (GuitarSet): about 7 ms between strings
    /// (a 4–6-string strum takes 12–45 ms, quicker when it's harder), up-strums catching the top 3–5 strings.
    static func events(for shape: ChordShape, stroke: StrumStroke, velocity: Float, strings only: [Int]? = nil,
                       touch: Touch = .pick, sampleRate sr: Double = 44100) -> [GuitarCore.Event] {
        let frets = shape.frets
        let fretted = (0..<6).filter { frets.indices.contains($0) && frets[$0] >= 0 }
        let played = fretted.filter { only?.contains($0) ?? true }
        let jitter = Int(Double.random(in: 0...0.006) * sr)
        let vel = max(0.05, min(1, velocity * Float.random(in: 0.88...1.06)))
        func midi(_ s: Int) -> Int { Theory.openStrings[s] + max(0, frets[s]) }
        func tuning(_ s: Int) -> Float {
            // pressing a string to the fret stretches it a little sharp
            (stringTuning[s] + (frets[s] > 0 ? 0.8 * Float(frets[s]).squareRoot() : 0)) / 100
        }
        // the fretting hand mutes strings that aren't part of the chord
        var out: [GuitarCore.Event] = (0..<6).filter { !fretted.contains($0) }.map { .damp($0, at: jitter, seconds: 0.08) }
        switch stroke {
        case .rest:
            return []
        case .mute:
            // a "chick": the fretting hand goes slack and the pick scrapes across dead strings
            let order = fretted.isEmpty ? Array(0..<6) : fretted
            let gap = Double.random(in: 0.004...0.007)
            for (k, s) in order.enumerated() {
                out.append(.init(kind: .chuck, string: s, midi: midi(s), velocity: vel * (1 - 0.05 * Float(k)), bright: 0.4,
                                 delay: jitter + Int(Double(k) * gap * sr), pick: 0.2))
            }
            return out
        case .down, .up:
            let down = stroke == .down
            // strings held by the chord but not struck this time: stop them if the hand moved
            for s in fretted where !played.contains(s) {
                out.append(.init(kind: .hold, string: s, midi: midi(s), velocity: 0, bright: 0, delay: jitter, pick: 0))
            }
            let order: [Int]
            if down {
                order = played
            } else {
                let n = min(played.count, Int.random(in: 3...5))
                order = Array(played.suffix(n).reversed())
                for s in played where !order.contains(s) {
                    out.append(.init(kind: .hold, string: s, midi: midi(s), velocity: 0, bright: 0, delay: jitter, pick: 0))
                }
            }
            // ~7 ms between strings, log-normally spread, quicker on harder strums; a thumb is slower
            let base = (down ? 0.0065 : 0.0070) * exp(0.35 * gaussian()) / Double(0.7 + 0.45 * vel) * (touch == .thumb ? 1.6 : 1)
            var t = 0.0
            for (k, s) in order.enumerated() {
                // down-strums hit the bass harder; up-strums are lighter and brighter
                let shapeGain: Float = down ? (1 - 0.05 * Float(k)) : (0.82 - 0.04 * Float(k))
                let v = max(0.05, vel * shapeGain * Float.random(in: 0.9...1.05))
                let bright: Float = touch == .thumb ? .random(in: 0.35...0.5) : (down ? .random(in: 0.55...0.7) : .random(in: 0.7...0.85))
                out.append(.init(kind: .pluck, string: s, midi: midi(s), velocity: v, bright: bright, delay: jitter + Int(t * sr),
                                 pick: touch == .thumb ? .random(in: 0.2...0.27) : .random(in: 0.16...0.24),
                                 detune: tuning(s), touch: touch))
                // the pick slows slightly as it goes through the strings
                t += base * (1 + 0.15 * Double(k) / Double(max(1, order.count))) * Double.random(in: 0.8...1.2)
            }
            return out
        }
    }

    private static func gaussian() -> Double {
        let u = Double.random(in: 1e-9..<1), v = Double.random(in: 0..<1)
        return sqrt(-2 * log(u)) * cos(2 * .pi * v)
    }

    private func makeClick(freq: Double, gain: Float) -> AVAudioPCMBuffer? {
        let total = Int(sr * 0.035)
        let s: [Float] = (0..<total).map { i in
            let t = Double(i) / sr
            return Float(sin(2 * .pi * freq * t) * exp(-t / 0.008)) * gain
        }
        guard let b = AVAudioPCMBuffer(pcmFormat: clickFormat, frameCapacity: AVAudioFrameCount(s.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { p in b.floatChannelData![0].update(from: p.baseAddress!, count: s.count) }
        return b
    }
}
